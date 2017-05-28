import csv
import sys
import threading
from time import sleep
from datetime import datetime

import msgpack
import zmq

context = zmq.Context()
socket = context.socket(zmq.SUB)
socket.setsockopt(zmq.SUBSCRIBE, b'')

socket.connect ("tcp://127.0.0.1:5555")

def go():
    writer = None
    firsttime = True
    with open('ani.csv', 'w', newline='') as csvfile:
        while True:
            msg = socket.recv()
            orig, msgpackdata = msg.split(b' ', 1)
            unpacked = msgpack.unpackb(msgpackdata, encoding='utf-8')
            unpacked.update({'datetime': str(datetime.now())})
            if firsttime:
                writer = csv.DictWriter(csvfile, fieldnames=list(unpacked.keys()))
                writer.writeheader()
                firsttime = False
            writer.writerow(unpacked)
            print(msgpackdata, unpacked)

anithread = threading.Thread(target=go, daemon=True)
anithread.start()

while True:
    sleep(1)
