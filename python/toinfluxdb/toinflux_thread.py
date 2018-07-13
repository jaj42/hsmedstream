import zmq
import msgpack
import pandas as pd
import socket
from functools import partial
from threading import Thread, Event
from queue import Queue, Empty

zmqhost = '127.0.0.1'
numport = 4201
wavport = 4202

influxhost = '127.0.0.1'
influxport = 8089

#<measurement>[,<tag_key>=<tag_value>[,<tag_key>=<tag_value>]] <field_key>=<field_value>[,<field_key>=<field_value>] [<timestamp>]

def run():
    stopevent = Event()
    queue = Queue()
    ctx = zmq.Context()

    zmqNumWorker = partial(recvFromZmq, stopevent, ctx, queue, zmqhost, numport, numEncode)
    zmqNumThread = Thread(target=zmqNumWorker)
    zmqNumThread.start()

    zmqWaveWorker = partial(recvFromZmq, stopevent, ctx, queue, zmqhost, wavport, wavEncode)
    zmqWaveThread = Thread(target=zmqWaveWorker)
    zmqWaveThread.start()

    influxWorker = partial(sendToInfluxdb, stopevent, queue, influxhost, influxport)
    influxThread = Thread(target=influxWorker)
    influxThread.start()

    try:
        while not stopevent.wait(timeout=1):
            pass
    except KeyboardInterrupt:
        stopevent.set()
    zmqNumThread.join()
    zmqWaveThread.join()
    influxThread.join()

def recvFromZmq(stopevent, ctx, queue, host, port, encoder):
    sock = ctx.socket(zmq.SUB)
    #sock.connect(f'tcp://{host}:{port}')
    sock.bind(f'tcp://{host}:{port}')
    sock.subscribe(b'')
    while not stopevent.is_set():
        try:
            msg = sock.recv(flags=zmq.NOBLOCK)
        except zmq.ZMQError:
            continue
        print(f'Received {msg}')
        try:
            decoded = decodeMsg(msg)
            request = encoder(decoded)
        except ValueError:
            print(f'Failed to parse: {msg}')
            continue
        queue.put(request)

def sendToInfluxdb(stopevent, queue, host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    while not stopevent.is_set():
        try:
            request = queue.get(timeout=1)
        except Empty:
            continue
        print(f'Sending: {request}')
        sock.sendto(request, (host, port))
    sock.close()

def decodeMsg(msg):
    # Parse incoming message
    topic, msgpackdata = msg.split(b' ', 1)
    frame = msgpack.unpackb(msgpackdata, encoding='utf-8')
    topic = topic.decode('ASCII')
    frame['topic'] = topic
    return frame

def numEncode(frame):
    # Encode numerics for InfluxDB
    tagdata = frame['tags'].copy()
    tagdata['origin'] = frame['topic']
    tags = [f'{tag}={value}' for tag, value in tagdata.items()]
    str_tags = ','.join(tags)
    data = frame['data']
    fields = [f'{field}={value}' for field, value in data.items()]
    str_fields = ','.join(fields)
    time = frame['basetime']
    line = f'numerics,{str_tags} {str_fields} {time}'
    return line.encode('ASCII')

def wavEncode(frame):
    # Encode waves for InfluxDB
    tagdata = frame['tags'].copy()
    tagdata['origin'] = frame['topic']
    tags = [f'{tag}={value}' for tag, value in tagdata.items()]
    str_tags = ','.join(tags)
    #basetime = frame['basetime']
    wavedata = pd.DataFrame(frame['data']).set_index('time')
    lines = []
    for time, waves in wavedata.iterrows():
        fields = []
        for metric, value in waves.iteritems():
            fields.append(f'{metric}={value}')
        str_fields = ','.join(fields)
        line = f'waves,{str_tags} {str_fields} {time}'
        lines.append(line)
    request = '\n'.join(lines)
    return request.encode('ASCII')


if __name__ == "__main__":
    run()
