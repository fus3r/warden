#!/bin/zsh
set -euo pipefail

# Build downloadable, unnotarized beta artifacts. Never publishes.
project_dir="${0:A:h:h}"
cd "$project_dir"
fail() { print -u2 -r -- "$1"; exit 2; }
(( $# == 0 )) || fail 'Usage: package-beta.sh (see docs/releasing.md)'
[[ -z "${WARDEN_PHONE_RELAY_URL:-}" ]] || fail 'This beta uses local phone access. Unset WARDEN_PHONE_RELAY_URL.'
[[ -f "${WARDEN_TRAIN_GUARD_WHEEL:-}" ]] || fail 'Set WARDEN_TRAIN_GUARD_WHEEL to the frozen, tested wheel.'
export WARDEN_TRAIN_GUARD_WHEEL="${WARDEN_TRAIN_GUARD_WHEEL:A}"
revision=$(git rev-parse --verify HEAD) || fail 'A committed source revision is required.'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Commit source changes before packaging.'
python3 Scripts/bundle-train-guard.py --check
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
build=$(plutil -extract CFBundleVersion raw Resources/Info.plist)
name="Warden-$version-beta.$build"
output="$project_dir/build/downloads/$version-$build"
[[ ! -e "$output" ]] || fail "Already packaged: $output. Increment CFBundleVersion for another candidate."

swift test
python3 -m unittest discover -s Tests/RemoteCollectorTests -v
node --test Extensions/warden-terminal/extension.test.js
./Scripts/build-app.sh universal
app="$project_dir/build/Warden.app"
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/Warden" -verify_arch arm64 x86_64
lipo "$app/Contents/Helpers/TrainGuard.app/Contents/MacOS/train-guard" -verify_arch arm64 x86_64

mkdir -p "$project_dir/build/downloads"
staging=$(mktemp -d "$project_dir/build/downloads/.preparing.XXXXXX")
trap 'rm -rf "$staging"' EXIT
bundle="$staging/extracted/$name"
mkdir -p "$bundle"
ditto "$app" "$bundle/Warden.app"
sed -e "s/@VERSION@/$version/g" -e "s/@BUILD@/$build/g" Packaging/download-start.txt > "$staging/GETTING-STARTED.txt"
cp "$staging/GETTING-STARTED.txt" "$bundle/GETTING-STARTED.txt"
(
    cd Extensions/warden-terminal
    npx --yes @vscode/vsce@4.0.0 package --no-dependencies --out "$staging/warden-terminal.vsix"
)
cp "$staging/warden-terminal.vsix" "$bundle/warden-terminal.vsix"
cp "$WARDEN_TRAIN_GUARD_WHEEL" "$staging/"

python3 - "$app" "$staging" "$revision" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

app, output = map(Path, sys.argv[1:3])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert not info.get("WardenPhoneRelayURL"), "Expected local phone access"
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
wheel = Path(os.environ["WARDEN_TRAIN_GUARD_WHEEL"])
signature = subprocess.run(["codesign", "-dv", str(app)], capture_output=True, text=True, check=True).stderr
manifest = {
    "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
    "source_repository": "https://github.com/fus3r/warden", "source_revision": sys.argv[3],
    "license": "MIT", "architectures": ["arm64", "x86_64"],
    "notarized": False, "phone": "local network",
    "agent_relay": info.get("WardenAgentRelayURL"),
    "signature": "ad-hoc" if "Signature=adhoc" in signature else "certificate; not notarized",
    "train_guard": {"wheel": wheel.name, "sha256": digest(wheel)},
    "executables_sha256": {name: digest(app / name) for name in (
        "Contents/MacOS/Warden", "Contents/Helpers/WardenBridge", "Contents/Helpers/WardenPower",
        "Contents/Helpers/TrainGuard.app/Contents/MacOS/train-guard")},
    "companion_sha256": digest(output / "warden-terminal.vsix"),
}
(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
cp "$staging/manifest.json" "$bundle/manifest.json"
ditto -c -k --keepParent "$bundle" "$staging/$name-universal.zip"

mkdir "$staging/image"
ditto "$app" "$staging/image/Warden.app"
ln -s /Applications "$staging/image/Applications"
cp "$staging/GETTING-STARTED.txt" "$staging/image/GETTING-STARTED.txt"
hdiutil create -volname 'Warden' -srcfolder "$staging/image" -format UDZO "$staging/$name-universal.dmg" >/dev/null
hdiutil verify "$staging/$name-universal.dmg" >/dev/null
ditto -x -k "$staging/$name-universal.zip" "$staging/roundtrip"
codesign --verify --deep --strict "$staging/roundtrip/$name/Warden.app"
rm -rf "$staging/image" "$staging/extracted" "$staging/roundtrip"
(cd "$staging"; shasum -a 256 *.dmg *.zip *.vsix *.whl GETTING-STARTED.txt manifest.json > SHA256SUMS.txt)
mv "$staging" "$output"
echo "Public beta assets prepared: $output"
echo 'Not notarized. No upload or publication was performed.'
