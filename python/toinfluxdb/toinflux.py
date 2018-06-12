import asyncio
import zmq
import zmq.asyncio
import msgpack
import time
from decimal import Decimal
import pandas as pd

host = '127.0.0.1'
zmqport = 4202
influxport = 8089

#<measurement>[,<tag_key>=<tag_value>[,<tag_key>=<tag_value>]] <field_key>=<field_value>[,<field_key>=<field_value>] [<timestamp>]

async def recvFromZmq(queue, host, port):
    ctx = zmq.asyncio.Context()
    sock = ctx.socket(zmq.SUB)
    #sock.connect(f'tcp://{host}:{port}')
    sock.bind(f'tcp://{host}:{port}')
    sock.subscribe(b'')
    while True:
        msg = await sock.recv()
        await queue.put(msg)

def decodeMsg(msg, wave=False):
    # Parse incoming message
    topic, msgpackdata = msg.split(b' ', 1)
    frame = msgpack.unpackb(msgpackdata, encoding='utf-8')
    topic = topic.decode('ASCII')
    frame['topic'] = topic
    return frame

def numericToInfluxLine(frame):
    metadata = frame['meta'].copy()
    metadata['origin'] = frame['topic']
    tags = [f"{tag}={value}" for tag, value in metadata.items()]
    data = frame['data']
    fields = [f"{field}={value}" for field, value in data.items()]
    str_tags = ','.join(tags)
    str_fields = ','.join(fields)
    time = frame['basetime']
    line = f'numerics,{str_tags} {str_fields} {time}'
    return line.encode('ASCII')

def waveToInfluxLines(frame):
    metadata = frame['meta'].copy()
    metadata['origin'] = frame['topic']
    tags = [f"{tag}={value}" for tag, value in metadata.items()]
    str_tags = ','.join(tags)
    #basetime = frame['basetime']
    wavedata = pd.DataFrame(frame['data'])
    wavedata = wavedata.set_index('time')
    lines = []
    for time, waves in wavedata.iterrows():
        fields = []
        for metric, value in waves.iteritems():
            fields.append(f'{metric}={value}')
        str_fields = ','.join(fields)
        line = f'waves,{str_tags} {str_fields} {time}'
        lines.append(line)
    lineagg = '\n'.join(lines)
    return lineagg.encode('ASCII')

async def sendToInfluxdb(loop, queue, host, port):
    udpproto = lambda: asyncio.DatagramProtocol()
    transport, proto = await loop.create_datagram_endpoint(udpproto, remote_addr=(host, port))
    while True:
        msg = await queue.get()
        print(f'Received {msg}')
        decoded = decodeMsg(msg)
        line = waveToInfluxLines(decoded)
        print(f'Sending: {line}')
        transport.sendto(line)
    transport.close()


loop = asyncio.get_event_loop()
queue = asyncio.Queue(loop=loop)
zmq_coro = recvFromZmq(queue, host, zmqport)
influx_coro = sendToInfluxdb(loop, queue, host, influxport)
g = asyncio.gather(zmq_coro, influx_coro)

try:
    loop.run_until_complete(g)
except KeyboardInterrupt:
    print('Ctrl-C pressed')
finally:
    loop.close()
