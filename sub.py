import csv
import sys
import os
import threading
from time import strftime, sleep
from datetime import datetime
from io import IOBase

import msgpack
import zmq

if len(sys.argv) > 1:
    outfolder = sys.argv[1]
else:
    outfolder = '.'

context = zmq.Context()
socket = context.socket(zmq.SUB)
socket.setsockopt(zmq.SUBSCRIBE, b'')

socket.bind("tcp://*:4201")

terminate = threading.Event()

def go():
    global terminate
    allheaders = set()
    dt = None
    filehandle = IOBase()
    writer = None
    newfile = True
    while not terminate.is_set():
        try:
            msg = socket.recv(flags=zmq.NOBLOCK)
            dt = datetime.now()
        except zmq.Again as e:
            # No message received
            continue
        orig, msgpackdata = msg.split(b' ', 1)
        unpacked = msgpack.unpackb(msgpackdata, encoding='utf-8')
        if not isinstance(unpacked, dict):
            print("Message garbled: {}", unpacked)
            continue

        unpacked = {orig.decode('utf-8') + key : value for key, value in unpacked.items()}

        tmpheaders = set(unpacked.keys())
        hasnew = not tmpheaders <= allheaders
        newfile |= hasnew

        if newfile:
            filehandle.close()
            timestamp = strftime('%Y%m%d-%H%M%S')
            filename = 'numerics_{}.csv'.format(timestamp)
            outfile = os.path.join(outfolder, filename)
            filehandle = open(outfile, 'w', newline='')

            allheaders |= tmpheaders
            csvheaders = ['datetime'] + sorted(list(allheaders))

            writer = csv.DictWriter(filehandle, fieldnames=csvheaders)
            writer.writeheader()
            newfile = False

        unpacked.update({'datetime': str(dt)})
        writer.writerow(unpacked)
        print(unpacked)
    filehandle.close()

anithread = threading.Thread(target=go)
anithread.start()

while True:
    try:
        sleep(1)
    except KeyboardInterrupt:
        terminate.set()
        anithread.join()
        break
