import json
import pathlib
import subprocess
import sys
import time

# Test-only pymobiledevice3-compatible process endpoint; not a physical transport.
root = pathlib.Path(sys.argv[1])
args = sys.argv[2:]
config_path = root / 'devices.json'
devices = json.loads(config_path.read_text()) if config_path.exists() else [f'phone-{i}' for i in range(3)]
root.mkdir(parents=True, exist_ok=True)
with (root / 'commands.jsonl').open('a') as output:
    output.write(json.dumps(args) + '\n')
if args == ['version']:
    print('test-endpoint')
elif args == ['usbmux', 'list']:
    print(json.dumps([{'Identifier': identifier, 'DeviceName': identifier, 'ConnectionType': 'USB'} for identifier in devices]))
elif args[:2] == ['remote', 'browse']:
    print(json.dumps([{'identifier': identifier} for identifier in devices]))
elif args[:2] == ['remote', 'start-tunnel']:
    identity = args[args.index('--udid') + 1]
    if identity not in devices:
        raise SystemExit('Device is not connected')
    delay_file = root / 'tunnel-delay-seconds'
    if delay_file.exists():
        time.sleep(float(delay_file.read_text()))
    print(json.dumps({'host': identity, 'port': 12345}), flush=True)
    while True:
        time.sleep(1)
elif args[:2] == ['mounter', 'query-developer-mode-status']:
    print('true')
elif args[:3] == ['developer', 'dvt', 'simulate-location']:
    sys.exit(1)  # Exercise the existing legacy-command transport, not DVT mocks.
elif args[:3] == ['developer', 'simulate-location', 'set']:
    host = args[args.index('--rsd') + 1]
    latitude, longitude = args[-2:]
    mapping = root / 'simulators.json'
    if mapping.exists():
        udid = json.loads(mapping.read_text())[host]
        subprocess.run(['xcrun', 'simctl', 'location', udid, 'set', f'{latitude},{longitude}'], check=True)
    (root / f'{host}.json').write_text(json.dumps([float(latitude), float(longitude)]))
elif args[:2] in [['mounter', 'auto-mount'], ['remote', 'rsd-info']] or args[:3] == ['developer', 'simulate-location', 'clear']:
    print('{}')
else:
    raise SystemExit('Unsupported test endpoint command: ' + repr(args))
