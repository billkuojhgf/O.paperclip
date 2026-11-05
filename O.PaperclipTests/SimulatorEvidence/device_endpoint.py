import asyncio
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

# Test-only process endpoint; Simulator Core Location remains the independent observer.
root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
root.mkdir(parents=True, exist_ok=True)
config_path = root / 'devices.json'
devices = json.loads(config_path.read_text()) if config_path.exists() else [f'phone-{i}' for i in range(3)]
behavior_path = root / 'worker-behavior.json'
behavior = json.loads(behavior_path.read_text()) if behavior_path.exists() else {}
with (root / 'commands.jsonl').open('a') as output:
    output.write(json.dumps(args) + '\n')


def record(event, identity, transport, **fields):
    with (root / 'lifecycle.jsonl').open('a') as output:
        output.write(json.dumps(dict(event=event, udid=identity, transport=transport, time=time.time(), pid=os.getpid(), **fields)) + '\n')


async def emit(value):
    data = (json.dumps(value, allow_nan=False) + '\n').encode()
    if behavior.get('splitOutput'):
        for offset in range(0, len(data), 3):
            sys.stdout.buffer.write(data[offset:offset + 3])
            sys.stdout.buffer.flush()
            await asyncio.sleep(0.001)
    else:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()


async def worker():
    identity = args[args.index('--udid') + 1] if '--udid' in args else (args[args.index('--rsd') + 1] if '--rsd' in args else devices[0])
    transport = 'manual-rsd' if '--rsd' in args else 'userspace-' + args[args.index('--connection-type') + 1]
    record('setup', identity, transport)
    if behavior.get('exitDuringSetup'):
        return
    delay_file = root / 'tunnel-delay-seconds'
    delay = float(delay_file.read_text()) if delay_file.exists() else behavior.get('setupDelay', 0)
    await emit({'event': 'stage', 'message': '建立裝置連線'})
    await asyncio.sleep(delay)
    code = behavior.get('setupError')
    if isinstance(code, dict):
        code = code.get(transport)
    if identity not in devices and '--rsd' not in args:
        code = 'transport_unavailable'
    if code:
        await emit({'event': 'error', 'id': None, 'code': code, 'message': '測試裝置連線失敗', 'fatal': True})
        return
    if behavior.get('unknownEvent'):
        await emit({'event': 'unknown'})
        return
    await emit({'event': 'ready', 'version': behavior.get('protocolVersion', 1), 'udid': behavior.get('readyUDID', identity), 'deviceName': identity, 'transport': transport, 'mode': 'dvt', 'euid': behavior.get('readyEUID', os.geteuid())})
    record('ready', identity, transport)
    reader = asyncio.StreamReader(limit=65536)
    pipe, _ = await asyncio.get_running_loop().connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    try:
        while True:
            deadline = behavior.get('exitAfterReady')
            try:
                line = await asyncio.wait_for(reader.readline(), deadline) if deadline else await reader.readline()
            except asyncio.TimeoutError:
                await emit({'event': 'error', 'id': None, 'code': 'transport_lost', 'message': '測試裝置已中斷', 'fatal': True})
                return
            if not line:
                return
            command = json.loads(line)
            operation = command['op']
            request_id = command['id']
            if operation == 'set':
                record('set-start', identity, transport)
                if behavior.get('exitDuringSet'):
                    return
                await asyncio.sleep(behavior.get('setDelay', 0))
                latitude, longitude = command['latitude'], command['longitude']
                mapping = root / 'simulators.json'
                if mapping.exists():
                    simulator = json.loads(mapping.read_text())[identity]
                    subprocess.run(['xcrun', 'simctl', 'location', simulator, 'set', f'{latitude},{longitude}'], check=True)
                (root / f'{identity}.json').write_text(json.dumps([latitude, longitude]))
                record('set', identity, transport, latitude=latitude, longitude=longitude)
            elif operation == 'clear' or operation == 'quit':
                if behavior.get('clearError'):
                    await emit({'event': 'error', 'id': request_id, 'code': 'operation_failed', 'message': '測試清除失敗', 'fatal': False})
                    if operation == 'quit':
                        return
                    continue
                mapping = root / 'simulators.json'
                if mapping.exists():
                    simulator = json.loads(mapping.read_text())[identity]
                    subprocess.run(['xcrun', 'simctl', 'location', simulator, 'clear'], check=True)
                record('clear', identity, transport)
            elif operation in ('start-stream', 'stop-stream'):
                record(operation, identity, transport)
            else:
                await emit({'event': 'error', 'id': request_id, 'code': 'invalid_request', 'message': '不支援的命令', 'fatal': False})
                continue
            await emit({'event': 'ack', 'id': request_id + 1 if behavior.get('wrongAck') else request_id})
            if operation == 'quit':
                return
    finally:
        pipe.close()
        record('disconnect', identity, transport)


async def run_worker():
    task = asyncio.create_task(worker())
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, task.cancel)
    try:
        await task
    except asyncio.CancelledError:
        pass


if args == ['version']:
    time.sleep(behavior.get('versionDelay', 0))
    print('11.49.2-test-endpoint')
elif args == ['usbmux', 'list']:
    print(json.dumps([{'Identifier': identity, 'DeviceName': identity, 'ConnectionType': 'USB'} for identity in devices]))
elif args[:2] == ['remote', 'browse']:
    print(json.dumps([{'udid': identity} for identity in devices]))
elif args[:1] == ['worker']:
    asyncio.run(run_worker())
else:
    raise SystemExit('Unsupported test endpoint command: ' + repr(args))
