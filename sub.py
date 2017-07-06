import csv
import sys
import os
from threading import Thread, Event
from enum import Enum
from time import strftime, sleep
from datetime import datetime
from io import IOBase

import msgpack
import zmq

if len(sys.argv) > 1:
    outfolder = sys.argv[1]
else:
    outfolder = '.'

class LogType(Enum):
    NUMERICS = 4201
    WAVE     = 4202

class Logger(Thread):
    def __init__(self, context, logtype, termevent):
        super().__init__()
        self.terminate = termevent
        self.allheaders = set()
        self.filehandle = IOBase()
        self.writer = None
        self.filepattern = str(logtype.name) + '_{}.csv'

        self.socket = context.socket(zmq.SUB)
        self.socket.setsockopt(zmq.SUBSCRIBE, b'')
        self.socket.RCVTIMEO = 1000 # in milliseconds
        self.socket.bind("tcp://*:{}".format(logtype.value))

    def __del__(self):
        self.filehandle.close()

    def newfile(self):
        self.filehandle.close()
        timestamp = strftime('%Y%m%d%H%M%S')
        filename = self.filepattern.format(timestamp)
        filehandle = open(filename, 'w', newline='')

        csvheaders = ['datetime'] + sorted(list(self.allheaders))

        self.writer = csv.DictWriter(filehandle, fieldnames=csvheaders)
        self.writer.writeheader()

    def run(self):
        dt = None
        while not self.terminate.is_set():
            try:
                msg = self.socket.recv()
                dt = datetime.now()
            except zmq.Again:
                # Timed out
                continue

            try:
                # Parse incoming message
                orig, msgpackdata = msg.split(b' ', 1)
                unpacked = msgpack.unpackb(msgpackdata, encoding='utf-8')
                if not isinstance(unpacked, dict):
                    raise ValueError("Message garbled: {}", unpacked)
                origin = orig.decode('utf-8')
            except:
                continue

            data = {origin + key : value for key, value in unpacked.items()}

            locheaders = set(data.keys())
            hasnew = not locheaders <= self.allheaders

            if hasnew:
                self.allheaders |= locheaders
                self.newfile()

            data.update({'datetime': str(dt)})
            self.writer.writerow(data)
            #print(data)

terminate = Event()

context = zmq.Context()
numthread = Logger(context, LogType.NUMERICS, terminate)
wavethread = Logger(context, LogType.WAVE, terminate)
numthread.start()
wavethread.start()

while True:
    try:
        sleep(1)
    except KeyboardInterrupt:
        terminate.set()
        numthread.join()
        wavethread.join()
        break
