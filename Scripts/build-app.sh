#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" && "$configuration" != "universal" ]]; then
    echo 'Usage: build-app.sh [release|debug|universal]' >&2
    exit 2
fi
# A universal build runs on Apple silicon and Intel Macs, for downloads.
if [[ "$configuration" == "universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    products=".build/apple/Products/Release"
else
    swift build -c "$configuration"
    products=".build/$configuration"
fi

if [[ "$configuration" == "debug" ]]; then
    app="$project_dir/build/WardenPreview.app"
else
    app="$project_dir/build/Warden.app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
python3 Scripts/bundle-train-guard.py "$app/Contents/Resources/TrainGuard"
# The runtime is built on the developer's machine, then installed offline by the app.
wheel=("$app"/Contents/Resources/TrainGuard/train_guard-*.whl)
(( ${#wheel} == 1 )) || { echo "Expected one bundled train-guard wheel" >&2; exit 2; }
wheel="${wheel[1]}"
if [[ -n "${WARDEN_TRAIN_GUARD_RUNTIME:-}" ]]; then
    runtime="$WARDEN_TRAIN_GUARD_RUNTIME"
else
    digest=$(shasum -a 256 "$wheel" | cut -c1-16)
    runtime="$project_dir/build/train-guard-runtime/$digest-universal2"
    python3 Scripts/freeze-train-guard.py "$wheel" "$runtime" --architecture universal2
fi
python3 - "$runtime" "$wheel" <<'PY_RUNTIME'
import email, hashlib, json, pathlib, sys, zipfile
runtime, wheel = map(pathlib.Path, sys.argv[1:])
source = json.loads((runtime / "source.json").read_text())
assert source["wheel_sha256"] == hashlib.sha256(wheel.read_bytes()).hexdigest(), "Runtime and wheel do not match"
assert source["architecture"] == "universal2", "The bundled runtime must support Apple silicon and Intel"
with zipfile.ZipFile(wheel) as package:
    metadata_path = next(name for name in package.namelist() if name.endswith('.dist-info/METADATA'))
    expected_version = email.message_from_bytes(package.read(metadata_path))["Version"]
assert (runtime / "TrainGuard.app/Contents/Resources/version").read_text().strip() == expected_version, "Runtime and wheel versions do not match"
for notice in ("PYTHON-LICENSE.txt", "PYINSTALLER-LICENSE.txt"):
    assert (runtime / "TrainGuard.app/Contents/Resources" / notice).is_file(), f"Runtime is missing {notice}"
PY_RUNTIME
rm -rf "$app/Contents/Helpers/TrainGuard" "$app/Contents/Helpers/TrainGuard.app"
ditto "$runtime/TrainGuard.app" "$app/Contents/Helpers/TrainGuard.app"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${WARDEN_PHONE_RELAY_URL:-}" ]]; then
    python3 - "$WARDEN_PHONE_RELAY_URL" <<'PY_RELAY'
from urllib.parse import urlsplit
import sys
url = urlsplit(sys.argv[1])
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('', '/'):
    raise SystemExit('WARDEN_PHONE_RELAY_URL must be a public HTTPS origin without credentials or a path.')
PY_RELAY
    plutil -insert WardenPhoneRelayURL -string "$WARDEN_PHONE_RELAY_URL" "$app/Contents/Info.plist"
fi
if [[ "$configuration" == "debug" ]]; then
    plutil -replace CFBundleIdentifier -string com.fus3r.Warden.Preview "$app/Contents/Info.plist"
    plutil -replace CFBundleName -string WardenPreview "$app/Contents/Info.plist"
    plutil -replace LSUIElement -bool NO "$app/Contents/Info.plist"
    plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes.0 -string warden-preview "$app/Contents/Info.plist"
fi
cp "$products/Warden" "$app/Contents/MacOS/Warden"
cp "$products/WardenBridge" "$app/Contents/Helpers/WardenBridge"
# The optional root service is registered only when the user enables closed-lid work in the release app.
cp "$products/WardenPower" "$app/Contents/Helpers/WardenPower"
mkdir -p "$app/Contents/Library/LaunchDaemons"
cp Resources/com.fus3r.Warden.Power.plist "$app/Contents/Library/LaunchDaemons/"
rm -rf "$app/Contents/Resources/Voice" "$app/Contents/Resources/Phone"
cp -R Resources/Voice "$app/Contents/Resources/Voice"
cp -R Resources/Phone "$app/Contents/Resources/Phone"
rm -rf "$app/Contents/Resources/Remote"
mkdir -p "$app/Contents/Resources/Remote"
cp Resources/Remote/warden-remote.py "$app/Contents/Resources/Remote/"
cp LICENSE NOTICE.md "$app/Contents/Resources/"

iconset="$project_dir/build/Warden.iconset"
mkdir -p "$iconset"
swift Resources/make-icon.swift "$iconset/icon_512x512@2x.png"
for entry in '16x16 16' '16x16@2x 32' '32x32 32' '32x32@2x 64' '128x128 128' '128x128@2x 256' '256x256 256' '256x256@2x 512' '512x512 512'; do
    label="${entry%% *}"
    pixels="${entry##* }"
    sips -z "$pixels" "$pixels" "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${label}.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Warden.icns"
# The phone page's Home Screen icon.
sips -z 180 180 "$iconset/icon_512x512@2x.png" --out "$app/Contents/Resources/Phone/icon.png" >/dev/null
for size in 192 512; do
    sips -z "$size" "$size" "$iconset/icon_512x512@2x.png" --out "$app/Contents/Resources/Phone/icon-$size.png" >/dev/null
done

# The widget extension, in release builds, or in the preview with WARDEN_WIDGETS=1. The preview's widgets read the
# preview's own folder.
appex="$app/Contents/PlugIns/WardenWidgets.appex"
widget_entitlements="$project_dir/build/WardenWidgets.entitlements"
rm -rf "$app/Contents/PlugIns"
if [[ "$configuration" != "debug" || -n "${WARDEN_WIDGETS:-}" ]]; then
    mkdir -p "$appex/Contents/MacOS"
    cp "$products/WardenWidgets" "$appex/Contents/MacOS/WardenWidgets"
    cp Resources/WardenWidgets.plist "$appex/Contents/Info.plist"
    for key in CFBundleShortVersionString CFBundleVersion; do
        plutil -replace "$key" -string "$(plutil -extract "$key" raw Resources/Info.plist)" "$appex/Contents/Info.plist"
    done
    if [[ "$configuration" == "debug" ]]; then
        plutil -replace CFBundleIdentifier -string com.fus3r.Warden.Preview.Widgets "$appex/Contents/Info.plist"
        sed 's|/Application Support/Warden/|/Application Support/WardenPreview/|' Resources/WardenWidgets.entitlements > "$widget_entitlements"
    else
        cp Resources/WardenWidgets.entitlements "$widget_entitlements"
    fi
fi

# A Developer ID in WARDEN_SIGN_IDENTITY signs with the hardened runtime that notarization requires. Otherwise the
# Mac's Apple Development certificate signs, when it has one, so macOS keeps the app's permissions across rebuilds and
# runs its widget without asking again; WARDEN_SIGN_IDENTITY=- or no certificate signs ad hoc. Code is signed from the
# inside out: the helper and the widget first, since the app's signature covers theirs.
identity="${WARDEN_SIGN_IDENTITY:-}"
sign_options=(--options runtime --timestamp)
if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')
    sign_options=()
fi
[[ "$identity" == "-" ]] && identity=""
sign() {
    local target="$1" entitlements="$2"
    if [[ -n "$identity" ]]; then
        codesign --force "${sign_options[@]}" --entitlements "$entitlements" --sign "$identity" "$target"
    else
        codesign --force --entitlements "$entitlements" --sign - "$target"
    fi
}
python3 Scripts/sign-train-guard.py "$app/Contents/Helpers/TrainGuard.app" "${identity:--}" "$app/Contents/Resources/TrainGuard/runtime-files.json"
sign "$app/Contents/Helpers/WardenBridge" Resources/Warden.entitlements
if [[ -n "$identity" ]]; then
    codesign --force "${sign_options[@]}" --options runtime --identifier com.fus3r.Warden.Power --entitlements Resources/WardenPower.entitlements --sign "$identity" "$app/Contents/Helpers/WardenPower"
else
    codesign --force --identifier com.fus3r.Warden.Power --entitlements Resources/WardenPower.entitlements --sign - "$app/Contents/Helpers/WardenPower"
fi
[[ -d "$appex" ]] && sign "$appex" "$widget_entitlements"
sign "$app" Resources/Warden.entitlements
echo "$app"
