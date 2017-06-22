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

socket.bind("tcp://*:4200")

terminate = threading.Event()

def go():
    global terminate
    writer = None
    firsttime = True
    with open('ani.csv', 'w', newline='') as csvfile:
        while not terminate.is_set():
            try:
                msg = socket.recv(flags=zmq.NOBLOCK)
            except zmq.Again as e:
                # No message received
                continue
            orig, msgpackdata = msg.split(b' ', 1)
            unpacked = msgpack.unpackb(msgpackdata, encoding='utf-8')
            if not isinstance(unpacked, dict):
                print("Message garbled: {}", unpacked)
                continue
            unpacked.update({'datetime': str(datetime.now())})
            if firsttime:
                writer = csv.DictWriter(csvfile, fieldnames=list(unpacked.keys()))
                writer.writeheader()
                firsttime = False
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
