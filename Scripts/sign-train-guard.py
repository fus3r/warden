#!/usr/bin/env python3
"""Sign the embedded interpreter and extensions, then seal the installable payload."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

folder, identity, manifest_path = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
options = ['--options', 'runtime', '--timestamp'] if identity != '-' else []
magics = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
for file in sorted(folder.rglob('*')):
    if not file.is_file() or file.is_symlink(): continue
    with file.open('rb') as stream: magic = stream.read(4)
    if magic in magics:
        subprocess.run(['codesign', '--force', *options, '--sign', identity, str(file)], check=True)
for framework in sorted(folder.rglob('*.framework'), key=lambda p: len(p.parts), reverse=True):
    subprocess.run(['codesign', '--force', *options, '--sign', identity, str(framework)], check=True)
subprocess.run(['codesign', '--force', *options, '--sign', identity, str(folder)], check=True)
manifest = {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(folder.rglob('*')) if p.is_file() and not p.is_symlink() }
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
