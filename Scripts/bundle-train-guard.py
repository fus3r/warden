#!/usr/bin/env python3
"""Build (or accept) the compatible train-guard wheel and seal it into Warden."""
import email
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

project = Path(__file__).resolve().parents[1]
version = re.search(r'public static let version = "([^"]+)"',
                    (project / "Sources/WardenCore/TrainGuardInstall.swift").read_text())[1]
filename = f"train_guard-{version}-py3-none-any.whl"
provided = os.environ.get("WARDEN_TRAIN_GUARD_WHEEL")
check_only = sys.argv[1:] == ["--check"]
if check_only and not provided:
    raise SystemExit("Checking a release requires WARDEN_TRAIN_GUARD_WHEEL; no source build was started.")
if provided:
    wheel = Path(provided).resolve()
else:
    source = Path(os.environ.get("WARDEN_TRAIN_GUARD_SOURCE", project.parent / "train-guard/train-guard")).resolve()
    if not (source / "pyproject.toml").is_file():
        raise SystemExit("Set WARDEN_TRAIN_GUARD_SOURCE to the compatible train-guard checkout, "
                         "or WARDEN_TRAIN_GUARD_WHEEL to its built wheel. See README.md.")
    output = project / "build/dependencies/train-guard"
    output.mkdir(parents=True, exist_ok=True)
    # Build dependencies are confined to python-build's temporary environment.
    subprocess.run([sys.executable, "-m", "build", "--wheel", "--outdir", str(output), str(source)], check=True)
    wheel = output / filename
if wheel.name != filename:
    raise SystemExit(f"Expected {filename}, got {wheel.name}")
with zipfile.ZipFile(wheel) as package:
    metadata = email.message_from_bytes(package.read(f"train_guard-{version}.dist-info/METADATA"))
    if metadata["Name"] != "train-guard" or metadata["Version"] != version:
        raise SystemExit("train-guard wheel metadata does not match Warden's integration version")
    if "trainguard/agents.py" not in package.namelist():
        raise SystemExit("train-guard wheel is missing session integration")
if check_only:
    print(f"Verified train-guard {version}: {hashlib.sha256(wheel.read_bytes()).hexdigest()}")
    raise SystemExit(0)
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
shutil.copy2(wheel, destination / filename)
(destination / "wheel.sha256").write_text(hashlib.sha256(wheel.read_bytes()).hexdigest() + "\n")
print(f"Bundled train-guard {version} with SHA-256 verification")
