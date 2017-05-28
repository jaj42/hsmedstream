import sys
import zmq
import msgpack
from time import sleep

context = zmq.Context()
socket = context.socket(zmq.SUB)
socket.setsockopt(zmq.SUBSCRIBE, b'')

socket.connect ("tcp://127.0.0.1:5555")

while True:
    msg = socket.recv()
    orig, msgpackdata = msg.split(b' ', 1)
    unpacked = msgpack.unpackb(msgpackdata)
    print(msgpackdata, unpacked)
    sleep(.1)
