#!/bin/zsh
set -euo pipefail

# Distribution only. build-app.sh remains the local development build command.
project_dir="${0:A:h:h}"
cd "$project_dir"
if (( $# > 1 )) || [[ "${1:-}" != "" && "${1:-}" != "--check" && "${1:-}" != "--help" ]]; then
    echo 'Usage: release.sh [--check|--help]' >&2
    exit 2
fi
if [[ "${1:-}" == "--help" ]]; then
    cat <<'HELP'
Build, sign, notarize and verify a universal Warden distribution. Does not publish it.
Required environment:
  WARDEN_SIGN_IDENTITY     Full Developer ID Application certificate name
  WARDEN_NOTARY_PROFILE    Existing notarytool Keychain profile name
  WARDEN_TRAIN_GUARD_WHEEL Frozen compatible wheel to bundle
--check validates local prerequisites without building or uploading.
Run the actual build under train-guard. See docs/releasing.md for device checks.
HELP
    exit 0
fi

fail() { print -u2 -r -- "$1"; exit 2; }
[[ "${WARDEN_SIGN_IDENTITY:-}" == 'Developer ID Application: '* ]] || \
    fail 'Distribution needs a Developer ID Application certificate. For a local build, use Scripts/build-app.sh.'
[[ -n "${WARDEN_NOTARY_PROFILE:-}" ]] || fail 'Set WARDEN_NOTARY_PROFILE to an existing notarytool profile. Distribution must be notarized.'
security find-identity -v -p codesigning | grep -Fq -- "\"$WARDEN_SIGN_IDENTITY\"" || \
    fail 'The requested Developer ID Application signing identity is not available on this Mac.'
[[ -f "${WARDEN_TRAIN_GUARD_WHEEL:-}" ]] || fail 'Set WARDEN_TRAIN_GUARD_WHEEL to the compatible, tested wheel. A distribution never builds an unpinned sibling checkout.'
export WARDEN_TRAIN_GUARD_WHEEL="${WARDEN_TRAIN_GUARD_WHEEL:A}"
python3 Scripts/bundle-train-guard.py --check
command -v node >/dev/null || fail 'Node.js is required to run the terminal extension checks.'
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
revision=$(git rev-parse --verify HEAD) || fail 'Build distributions from a Git checkout with a committed revision.'
changes=$(git status --porcelain --untracked-files=all -- Sources Tests Extensions Resources Scripts Packaging Relay .dockerignore Package.swift README.md CHANGELOG.md LICENSE NOTICE.md docs)
[[ -z "$changes" ]] || fail 'Release inputs have uncommitted changes. Review and commit the tested version before packaging a distribution.'
version=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
output="$project_dir/build/releases/$version"
[[ ! -e "$output" ]] || fail "A distribution for $version already exists at $output. Keep it immutable and use a new version."
if [[ "${1:-}" == "--check" ]]; then
    echo "Local prerequisites passed for Warden $version ($revision). Apple authentication and notarization are checked during release."
    exit 0
fi

swift test
node --test Extensions/warden-terminal/extension.test.js
npm ci --ignore-scripts --prefix Relay
npm test --prefix Relay
./Scripts/build-app.sh universal
app="$project_dir/build/Warden.app"
codesign --verify --deep --strict "$app"

mkdir -p "$project_dir/build/releases"
staging=$(mktemp -d "$project_dir/build/releases/.preparing.XXXXXX")
trap 'rm -rf "$staging"' EXIT
zip="$staging/Warden-$version.zip"
dmg="$staging/Warden-$version.dmg"

notarize() {
    if ! xcrun notarytool submit "$1" --keychain-profile "$WARDEN_NOTARY_PROFILE" --wait --output-format json > "$2"; then
        cat "$2" >&2
        return 1
    fi
    if [[ "$(plutil -extract status raw "$2")" != Accepted ]]; then
        cat "$2" >&2
        print -u2 'Apple did not accept this archive. No distribution was produced.'
        return 1
    fi
}

ditto -c -k --keepParent "$app" "$zip"
notarize "$zip" "$staging/app-notarization.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
rm "$zip"
ditto -c -k --keepParent "$app" "$zip"

mkdir "$staging/image"
ditto "$app" "$staging/image/Warden.app"
ln -s /Applications "$staging/image/Applications"
hdiutil create -volname Warden -srcfolder "$staging/image" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$staging/image"
codesign --force --timestamp --sign "$WARDEN_SIGN_IDENTITY" "$dmg"
notarize "$dmg" "$staging/dmg-notarization.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

sha=$(shasum -a 256 "$zip" | cut -d ' ' -f 1)
sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha/g" Packaging/warden.rb > "$staging/warden.rb"
python3 - "$staging" "$revision" "$version" "$app" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys

folder, revision, version, app = sys.argv[1:]
folder, app = Path(folder), Path(app)
artifacts = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(folder.iterdir()) if p.suffix in (".zip", ".dmg")}
wheel = app / "Contents/Resources/TrainGuard" / Path(os.environ["WARDEN_TRAIN_GUARD_WHEEL"]).name
manifest = {"version": version, "revision": revision, "sha256": artifacts,
            "train_guard": {"wheel": wheel.name, "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest()},
            "verification": "Developer ID, accepted notarization, stapled tickets and Gatekeeper passed"}
(folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
mv "$staging" "$output"
echo "Verified distribution: $output"
echo 'Nothing has been uploaded to GitHub or published. Complete the external-Mac checks in docs/releasing.md before sharing.'
