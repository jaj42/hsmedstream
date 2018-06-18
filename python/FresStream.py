import threading
import time
from functools import partial
from queue import Empty

import msgpack
import zmq

import infupy.backends.fresenius as fresenius

zmqhost = '127.0.0.1'
zmqport = 4201
freseniusport = 'COM5'

def stateWorker(stopevent):
    context = zmq.Context()
    zmqsocket = context.socket(zmq.PUB)
    comm = fresenius.FreseniusComm(freseniusport)
    base = fresenius.FreseniusBase(comm)

    paramVolumeWorker = partial(volumeWorker, comm.eventq, zmqsocket, stopevent)
    volumeThread = threading.Thread(target=paramVolumeWorker)
    volumeThread.start()

    while not stopevent.wait(5):
        # Check Base
        try:
            dtype = base.readDeviceType()
        except fresenius.CommandError as e:
            print(f'Base error: {e}')
            try:
                base = fresenius.FreseniusBase(comm)
            except fresenius.CommandError as e:
                print(f'Failed to connect to base: {e}')
        # Check Syringes
        try:
            modids = base.listModules()
            for modid in modids:
                if not modid in base.syringes:
                    s = base.connectSyringe(modid)
                s.registerEvent(fresenius.VarId.volume)
        except fresenius.CommandError as e:
            print(f'Attach syringe error: {e}')
    print('Stopping')
    volumeThread.join()
    print('volumeThread joined')
    for s in base.syringes.values():
        print(f'Disconnecting syringe {s.index}')
        s.disconnect()
    print(f'Disconnecting Base')
    base.disconnect()

def volumeWorker(queue, zmqsocket, stopevent):
    while not stopevent.is_set():
        try:
            dt, origin, inmsg = queue.get(timeout=1)
        except Empty:
            continue
        print(f'Received: {origin} {inmsg} {dt}')
        try:
            volume = fresenius.extractVolume(inmsg)
        except ValueError:
            print("Failed to decode volume from: {inmsg}")
            continue
        print(f'Volume: {volume}')
        timestamp = int(dt.timestamp() * 1e9)
        value = {f'syringe{origin}_volume' : volume}
        sample = {'basetime' : timestamp, 'data' : value, 'tags' : {}, 'meta' : {}}
        packed = msgpack.packb(sample)
        outmsg = b'infupy ' + packed
        print(f'Sending: {outmsg}')
        zmqsocket.send(outmsg)


if __name__ == '__main__':
    stopevent = threading.Event()
    stateThread = threading.Thread(target=stateWorker, args=[stopevent])
    stateThread.start()
    while not stopevent.is_set():
        try:
            time.sleep(1)
        except KeyboardInterrupt:
            stopevent.set()
    stateThread.join()
    print('stateThread joined')
