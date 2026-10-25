#!/usr/bin/env python3
"""Capture the real Debug app on dedicated, disposable marketing simulators."""
import argparse
import json
import os
import platform
import signal
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'output/app-store/2026-10'
BUNDLE = 'com.linquist.muxmanager'


def run(*args, env=None):
    return subprocess.run(args, check=True, text=True, capture_output=True, env=env).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='Existing Debug simulator .app; otherwise build it.')
    parser.add_argument('--keep-devices', action='store_true')
    parser.add_argument('--previews', action='store_true', help='Also record and encode 24-second preview videos.')
    parser.add_argument('--ffmpeg', default='ffmpeg', help='Local FFmpeg executable for optional video export.')
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    scenes_path = OUTPUT / 'scenes.json'
    if not scenes_path.exists():
        scenes_path.write_bytes((Path(__file__).parent / 'scenes.json').read_bytes())
    # Check the service before building or creating any devices.
    runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
    available = [r for r in runtimes if r.get('isAvailable') and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
    if not available:
        raise RuntimeError('No available iOS Simulator runtime. Install one in Xcode Settings > Components.')
    runtime = max(available, key=lambda r: tuple(int(n) for n in r['version'].split('.')))['identifier']
    types = json.loads(run('xcrun', 'simctl', 'list', 'devicetypes', '-j'))['devicetypes']
    families = {
        'iphone': ['iPhone 17 Pro Max', 'iPhone 16 Pro Max'],
        'ipad': ['iPad Pro 13-inch (M5)', 'iPad Pro 13-inch (M4)'],
    }
    selected = {}
    for family, names in families.items():
        match = next((t for name in names for t in types if t['name'] == name), None)
        if not match:
            raise RuntimeError(f'Install a compatible Simulator device type: {names}')
        selected[family] = match['identifier']
    app = args.app
    if app is None:
        derived = Path('/private/tmp/mux-app-store-derived')
        print('Building Debug capture app…', flush=True)
        run('xcodebuild', '-project', str(ROOT / 'MuxManager.xcodeproj'), '-scheme', 'MuxManager',
            '-derivedDataPath', str(derived), '-resolvePackageDependencies')
        # Xcode can omit this SwiftPM host-tool dependency from its build graph.
        # Compile the pinned package's own generator, without changing its source.
        generator = derived / 'SourcePackages/checkouts/SwiftTerm/Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift'
        if generator.is_file():
            host_tool = derived / 'Build/Products/Debug/SwiftTermBuildInfoGenerator'
            host_tool.parent.mkdir(parents=True, exist_ok=True)
            run('swiftc', '-parse-as-library', str(generator), '-o', str(host_tool))
        result = subprocess.run([
            'xcodebuild', '-project', str(ROOT / 'MuxManager.xcodeproj'), '-scheme', 'MuxManager',
            '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', 'generic/platform=iOS Simulator',
            '-derivedDataPath', str(derived), '-quiet', '-disableAutomaticPackageResolution',
            f'ARCHS={platform.machine()}', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'build',
        ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (OUTPUT / 'capture-build.log').write_text(result.stdout)
        result.check_returncode()
        app = derived / 'Build/Products/Debug-iphonesimulator/Mux Manager.app'
    if not app.is_dir():
        raise RuntimeError(f'Missing Debug simulator app: {app}')
    scenes = json.loads((OUTPUT / 'scenes.json').read_text())
    raw = OUTPUT / 'raw'; raw.mkdir(exist_ok=True)
    captured = []
    created = []
    try:
        for family, device_type in selected.items():
            device = run('xcrun', 'simctl', 'create', f'MuxManager Marketing {family}', device_type, runtime).strip()
            created.append(device)
            run('xcrun', 'simctl', 'boot', device)
            run('xcrun', 'simctl', 'bootstatus', device, '-b')
            run('xcrun', 'simctl', 'status_bar', device, 'override', '--time', '9:41', '--dataNetwork', 'wifi',
                '--wifiMode', 'active', '--wifiBars', '3', '--batteryState', 'charged', '--batteryLevel', '100')
            run('xcrun', 'simctl', 'ui', device, 'appearance', 'dark')
            run('xcrun', 'simctl', 'install', device, str(app))
            for scene in scenes:
                # Terminate only our app in our disposable simulator.
                subprocess.run(['xcrun', 'simctl', 'terminate', device, BUNDLE], capture_output=True)
                run('xcrun', 'simctl', 'launch', device, BUNDLE, '--mux-screenshot-scene', scene['id'],
                    '-AppleLanguages', '(en)', '-AppleLocale', 'en_US')
                time.sleep(4)
                target = raw / f"{family}-{scene['id']}.png"
                run('xcrun', 'simctl', 'io', device, 'screenshot', '--type=png', str(target))
                captured.append({'family': family, 'scene': scene['id'], 'file': str(target.relative_to(OUTPUT)),
                                 'source': 'real Debug app UI with isolated sample data'})
                print(f'Captured {family}: {scene["id"]}', flush=True)
            if args.previews:
                recordings = OUTPUT / 'recordings'; recordings.mkdir(exist_ok=True)
                subprocess.run(['xcrun', 'simctl', 'terminate', device, BUNDLE], capture_output=True)
                run('xcrun', 'simctl', 'launch', device, BUNDLE, '--mux-screenshot-scene', 'preview')
                time.sleep(1.5)
                recording = subprocess.Popen(['xcrun', 'simctl', 'io', device, 'recordVideo', '--codec=h264', '--force', str(recordings / f'{family}-native.mov')], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    time.sleep(26)
                finally:
                    recording.send_signal(signal.SIGINT)
                    recording.communicate(timeout=20)
                if recording.returncode != 0:
                    raise RuntimeError(f'Preview recording failed for {family}')
    finally:
        if not args.keep_devices:
            for device in created:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], capture_output=True)
                subprocess.run(['xcrun', 'simctl', 'delete', device], capture_output=True)
    (OUTPUT / 'capture-manifest.json').write_text(json.dumps(captured, indent=2) + '\n')
    subprocess.run(['swift', str(ROOT / 'scripts/app-store/render.swift'), str(OUTPUT)], check=True)
    if args.previews:
        subprocess.run(['python3', str(ROOT / 'scripts/app-store/encode-previews.py'), '--ffmpeg', args.ffmpeg], check=True)
    subprocess.run(['ruby', str(ROOT / 'scripts/app-store/upload.rb'), '--validate'], check=True)


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, RuntimeError) as error:
        print(str(error))
        if isinstance(error, subprocess.CalledProcessError):
            print((error.stderr or error.stdout or '')[-3000:])
        raise SystemExit(1)
