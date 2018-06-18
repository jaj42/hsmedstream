import asyncio
import zmq
import zmq.asyncio
import msgpack
import pandas as pd

zmqhost = '127.0.0.1'
numport = 4201
wavport = 4202

influxhost = '127.0.0.1'
influxport = 8089

#<measurement>[,<tag_key>=<tag_value>[,<tag_key>=<tag_value>]] <field_key>=<field_value>[,<field_key>=<field_value>] [<timestamp>]

def run():
    loop = asyncio.get_event_loop()
    queue = asyncio.Queue(loop=loop)

    ctx = zmq.asyncio.Context()
    asyncio.ensure_future(recvFromZmq(loop, ctx, queue, zmqhost, numport, numEncode))
    asyncio.ensure_future(recvFromZmq(loop, ctx, queue, zmqhost, wavport, wavEncode))

    asyncio.ensure_future(sendToInfluxdb(loop, queue, influxhost, influxport))
    loop.run_forever()

async def recvFromZmq(loop, ctx, queue, host, port, encoder):
    sock = ctx.socket(zmq.SUB, io_loop=loop)
    #sock.connect(f'tcp://{host}:{port}')
    sock.bind(f'tcp://{host}:{port}')
    sock.subscribe(b'')
    while loop.is_running():
        msg = await sock.recv()
        print(f'Received {msg}')
        try:
            decoded = decodeMsg(msg)
            request = encoder(decoded)
        except ValueError:
            print(f'Failed to parse: {msg}')
            continue
        await queue.put(request)

async def sendToInfluxdb(loop, queue, host, port):
    udpproto = lambda: asyncio.DatagramProtocol()
    transport, proto = await loop.create_datagram_endpoint(udpproto, remote_addr=(host, port))
    while loop.is_running():
        request = await queue.get()
        print(f'Sending: {request}')
        transport.sendto(request)
    transport.close()

def decodeMsg(msg, wave=False):
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
    tags = [f"{tag}={value}" for tag, value in tagdata.items()]
    str_tags = ','.join(tags)
    data = frame['data']
    fields = [f"{field}={value}" for field, value in data.items()]
    str_fields = ','.join(fields)
    time = frame['basetime']
    line = f'numerics,{str_tags} {str_fields} {time}'
    return line.encode('ASCII')

def wavEncode(frame):
    # Encode waves for InfluxDB
    tagdata = frame['tags'].copy()
    tagdata['origin'] = frame['topic']
    tags = [f"{tag}={value}" for tag, value in tagdata.items()]
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
