#!/usr/bin/env python3
"""Build the runtime on the developer's Mac, never on an end user's machine."""
import argparse
import email
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('wheel', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--architecture', choices=['arm64', 'x86_64', 'universal2'], default='universal2')
args = parser.parse_args()
wheel = args.wheel.resolve()
output = args.output.resolve()
metadata = {'wheel_sha256': hashlib.sha256(wheel.read_bytes()).hexdigest(), 'architecture': args.architecture,
            'pyinstaller': '6.22.3', 'psutil': '7.2.2', 'layout': 'app-v1'}
marker = output / 'source.json'
if (marker.exists() and json.loads(marker.read_text()) == metadata
        and (output / 'TrainGuard.app/Contents/MacOS/train-guard').is_file()
        and all((output / 'TrainGuard.app/Contents/Resources' / name).is_file()
                for name in ('PYTHON-LICENSE.txt', 'PYINSTALLER-LICENSE.txt'))):
    print(output)
    raise SystemExit(0)
if output.exists():
    raise SystemExit('Runtime output already exists with different inputs; choose another output directory.')
with tempfile.TemporaryDirectory(prefix='warden-freeze-') as temporary:
    root = Path(temporary)
    builder = root / 'builder'
    subprocess.run([sys.executable, '-m', 'venv', str(builder)], check=True)
    python = str(builder / 'bin/python')
    subprocess.run([python, '-m', 'pip', 'install', '--disable-pip-version-check', 'pyinstaller==6.22.3', 'wheel==0.45.1'], check=True)
    env = dict(os.environ)
    env['ARCHFLAGS'] = '-arch x86_64 -arch arm64' if args.architecture == 'universal2' else '-arch ' + args.architecture
    # Build psutil with both slices; its ordinary pip wheel is architecture-specific.
    subprocess.run([python, '-m', 'pip', 'install', '--disable-pip-version-check', '--no-binary=psutil', '--no-cache-dir', 'psutil==7.2.2'], env=env, check=True)
    subprocess.run([python, '-m', 'pip', 'install', '--no-deps', str(wheel)], check=True)
    subprocess.run([python, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onedir', '--windowed', '--osx-bundle-identifier', 'com.fus3r.Warden.TrainGuard', '--target-arch', args.architecture,
                    '--name', 'train-guard', '--copy-metadata', 'train-guard', '--copy-metadata', 'psutil',
                    '--distpath', str(root / 'dist'), '--workpath', str(root / 'work'), '--specpath', str(root),
                    str(Path(__file__).with_name('train-guard-entry.py'))], check=True)
    staged = root / 'runtime'
    staged.mkdir()
    shutil.copytree(root / 'dist/train-guard.app', staged / 'TrainGuard.app', symlinks=True)
    info = staged / 'TrainGuard.app/Contents/Info.plist'
    value = plistlib.loads(info.read_bytes()); value['LSUIElement'] = True
    info.write_bytes(plistlib.dumps(value))
    version = subprocess.check_output([str(staged / 'TrainGuard.app/Contents/MacOS/train-guard'), '--version'], text=True).strip().removeprefix('train-guard ')
    with zipfile.ZipFile(wheel) as package:
        metadata_path = next(name for name in package.namelist() if name.endswith('.dist-info/METADATA'))
        expected_version = email.message_from_bytes(package.read(metadata_path))['Version']
    if version != expected_version:
        raise SystemExit(f'Runtime reports {version}, but the wheel declares {expected_version}.')
    (staged / 'TrainGuard.app/Contents/Resources/version').write_text(version + '\n')
    (staged / 'source.json').write_text(json.dumps(metadata, indent=2) + '\n')
    # CPython's installed license, including licenses for its bundled components.
    license_file = Path(sys.base_prefix) / 'lib' / ('python' + '.'.join(map(str, sys.version_info[:2]))) / 'LICENSE.txt'
    if not license_file.is_file():
        raise SystemExit("Build with a Python installation that includes its complete LICENSE.txt.")
    (staged / 'TrainGuard.app/Contents/Resources/PYTHON-LICENSE.txt').write_text(license_file.read_text())
    pyinstaller_license = subprocess.check_output([python, '-c',
        "from importlib.metadata import distribution; d = distribution('pyinstaller'); "
        "print(next(str(d.locate_file(p)) for p in d.files if p.name == 'COPYING.txt'))"], text=True).strip()
    shutil.copy2(pyinstaller_license, staged / 'TrainGuard.app/Contents/Resources/PYINSTALLER-LICENSE.txt')
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(staged, output, symlinks=True)
print(output)
