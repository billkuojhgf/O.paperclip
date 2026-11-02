import json
import os
import pathlib
import plistlib
import subprocess
import tempfile
import shutil

os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def prepare(ids):
    root = pathlib.Path(tempfile.mkdtemp(prefix='paperclip-observer-'))
    app = root / 'LocationObserver.app'
    app.mkdir()
    source = root / 'Observer.swift'
    source.write_text(pathlib.Path(__file__).with_name('Observer.swift.txt').read_text())
    sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
    subprocess.run(['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-parse-as-library', '-sdk', sdk, '-target', 'arm64-apple-ios17.0-simulator', str(source), '-o', str(app / 'LocationObserver')], check=True)
    info = {'CFBundleIdentifier': 'local.paperclip.LocationObserver', 'CFBundleExecutable': 'LocationObserver', 'CFBundleName': 'LocationObserver', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0', 'LSRequiresIPhoneOS': True, 'NSLocationWhenInUseUsageDescription': '驗證 O.Paperclip 同步定位。', 'UILaunchScreen': {}}
    info['UIApplicationSceneManifest'] = {'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {}}
    (app / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--sign', '-', str(app)], check=True)
    paths = {}
    for udid in ids:
        subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)
        subprocess.run(['xcrun', 'simctl', 'install', udid, str(app)], check=True)
        subprocess.run(['xcrun', 'simctl', 'privacy', udid, 'grant', 'location', info['CFBundleIdentifier']], check=True)
        subprocess.run(['xcrun', 'simctl', 'launch', udid, info['CFBundleIdentifier']], check=True)
        container = run('xcrun', 'simctl', 'get_app_container', udid, info['CFBundleIdentifier'], 'data')
        paths[udid] = str(pathlib.Path(container) / 'Documents/locations.jsonl')
    return paths


if __name__ == '__main__':
    runtime_data = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '--json'))
    requested_runtime = os.environ.get('PAPERCLIP_SIMULATOR_RUNTIME', 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
    runtime_info = next(item for item in runtime_data['runtimes'] if item['isAvailable'] and item['identifier'] == requested_runtime)
    runtime = runtime_info['identifier']
    device_type = next(item['identifier'] for item in runtime_info['supportedDeviceTypes'] if item['productFamily'] == 'iPhone')
    ids = []
    pointer = pathlib.Path('/tmp/paperclip-simulator-evidence-path')
    evidence = pathlib.Path(tempfile.mkdtemp(prefix='paperclip-simulator-evidence-'))
    try:
        for i in range(3):
            ids.append(run('xcrun', 'simctl', 'create', f'Paperclip Verification {i}', device_type, runtime))
        paths = prepare(ids)
        assert len(paths) == 3 and set(paths) == set(ids)
        (evidence / 'simulators.json').write_text(json.dumps(dict(zip([f'phone-{i}' for i in range(3)], ids))))
        (evidence / 'observers.json').write_text(json.dumps(paths))
        pointer.write_text(str(evidence))
        print('PAPERCLIP_SIMULATOR_EVIDENCE=' + str(evidence), flush=True)
        subprocess.run(['xcodebuild', '-quiet', '-project', 'O.Paperclip.xcodeproj', '-scheme', 'O.Paperclip', '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', '/tmp/paperclip-multidevice-build', 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=', '-parallel-testing-enabled', 'NO', 'test'], check=True)
    finally:
        pointer.unlink(missing_ok=True)
        for udid in ids:
            subprocess.run(['xcrun', 'simctl', 'shutdown', udid], check=False)
            subprocess.run(['xcrun', 'simctl', 'delete', udid], check=False)
        shutil.rmtree(evidence)
