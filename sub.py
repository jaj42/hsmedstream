import csv
import sys
import os
import threading
from time import sleep
from datetime import datetime

import msgpack
import zmq

if len(sys.argv) > 1:
    outfolder = sys.argv[1]
else:
    outfolder = '.'

context = zmq.Context()
socket = context.socket(zmq.SUB)
socket.setsockopt(zmq.SUBSCRIBE, b'')

socket.bind("tcp://*:4200")

terminate = threading.Event()

def go():
    global terminate
    writer = None
    firsttime = True
    dt = None
    outfile = os.path.join(outfolder, 'ani.csv')
    with open(outfile, 'w', newline='') as csvfile:
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
            if firsttime:
                headers = ['datetime'] + list(unpacked.keys())
                writer = csv.DictWriter(csvfile, fieldnames=headers)
                writer.writeheader()
                firsttime = False
            unpacked.update({'datetime': str(dt)})
            writer.writerow(unpacked)
            print(msgpackdata, unpacked)

anithread = threading.Thread(target=go)
anithread.start()

while True:
    try:
        sleep(1)
    except KeyboardInterrupt:
        terminate.set()
        anithread.join()
        break
