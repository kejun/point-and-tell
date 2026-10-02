#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$VERSION" == "$PLIST_VERSION" ]] || { echo "Version mismatch" >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=11.0
ARCH="${ARCH:-universal}"
case "$ARCH" in
  universal) SLICES="x86_64 arm64" ;;
  x86_64|arm64) SLICES="$ARCH" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
BINARIES=()
for SLICE in $SLICES; do
  swift build -c release --arch "$SLICE"
  BIN_DIR="$(swift build -c release --arch "$SLICE" --show-bin-path)"
  BINARIES+=("$BIN_DIR/PointAndTell")
done
APP="dist/Point & Tell.app"
# Never reuse nested code from an earlier build.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if [[ "$ARCH" == "universal" ]]; then
  xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/PointAndTell"
else
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/PointAndTell"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Sparkle-LICENSE "$APP/Contents/Resources/Sparkle-LICENSE"
FRAMEWORK="$(python3 scripts/sparkle-path.py --framework)"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
python3 - <<'PYKEY'
import base64, os, pathlib, plistlib
p = pathlib.Path('dist/Point & Tell.app/Contents/Info.plist')
info = plistlib.loads(p.read_bytes())
key = os.environ.get('SPARKLE_PUBLIC_ED_KEY', '').strip()
if key:
    assert len(base64.b64decode(key, validate=True)) == 32, 'Invalid update public key'
    info['SUPublicEDKey'] = key
else:
    assert os.environ.get('REQUIRE_UPDATE_KEY') != '1', 'Configure update signing before release'
    info.pop('SUPublicEDKey', None)
    print('Development build: update signing key absent; updater will stay disabled.')
p.write_bytes(plistlib.dumps(info))
PYKEY
chmod +x "$APP/Contents/MacOS/PointAndTell"
# Sign nested components from the inside out. --deep signing can discard
# helper-specific entitlements; it is used only for verification.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for HELPER in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/XPCServices/Downloader.xpc" \
              "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
  if [[ -e "$HELPER" ]]; then
    codesign --force --sign - --options runtime --preserve-metadata=entitlements "$HELPER"
  fi
done
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
file "$APP/Contents/MacOS/PointAndTell"
otool -l "$APP/Contents/MacOS/PointAndTell" | grep -A5 LC_BUILD_VERSION
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Point-and-Tell-v${VERSION}-macOS-${ARCH}.zip"
shasum -a 256 "dist/Point-and-Tell-v${VERSION}-macOS-${ARCH}.zip" > "dist/Point-and-Tell-v${VERSION}-macOS-${ARCH}.zip.sha256"

ACTUAL_SLICES="$(lipo -archs "$APP/Contents/MacOS/PointAndTell")"
[[ "$ACTUAL_SLICES" == "$SLICES" ]] || { echo "Wrong architectures: $ACTUAL_SLICES" >&2; exit 1; }
for SLICE in $SLICES; do
  MIN_OS="$(otool -arch "$SLICE" -l "$APP/Contents/MacOS/PointAndTell" | awk '$1 == "minos" { print $2; exit }')"
  [[ "$MIN_OS" == "11.0" ]] || { echo "Wrong minimum macOS for $SLICE: $MIN_OS" >&2; exit 1; }
done
export VERSION ARCH MIN_OS SLICES
python3 - <<'PYBUILD'
import hashlib,json,os,pathlib,platform,subprocess,zipfile
p=pathlib.Path(f"dist/Point-and-Tell-v{os.environ['VERSION']}-macOS-{os.environ['ARCH']}.zip")
with zipfile.ZipFile(p) as z:
    executable=z.getinfo('Point & Tell.app/Contents/MacOS/PointAndTell')
    assert (executable.external_attr >> 16) & 0o111, 'ZIP lost executable permissions'
    assert z.testzip() is None
    import plistlib
    info = plistlib.loads(z.read('Point & Tell.app/Contents/Info.plist'))
    icon = z.read('Point & Tell.app/Contents/Resources/' + info['CFBundleIconFile'])
    assert icon[:4] == b'icns', 'App icon is missing or invalid'
manifest={
 'version':os.environ['VERSION'], 'build':info['CFBundleVersion'],
 'source_commit':os.environ.get('SOURCE_COMMIT') or subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'architecture':os.environ['ARCH'], 'slices':os.environ['SLICES'].split(), 'build_host_architecture':platform.machine(), 'minimum_macos':os.environ['MIN_OS'],
 'archive':p.name, 'sha256':hashlib.sha256(p.read_bytes()).hexdigest(), 'bytes':p.stat().st_size,
 'signature':'ad-hoc; codesign --verify --deep --strict passed', 'notarized':False,
 'sparkle_version':'2.9.6', 'update_public_key':info.get('SUPublicEDKey'),
 'ci_run_url':f"https://github.com/{os.environ.get('GITHUB_REPOSITORY','kejun/point-and-tell')}/actions/runs/{os.environ.get('GITHUB_RUN_ID','local')}",
 'unverified':['macOS 11 device runtime','screen and microphone permissions','real billed ASR request','10-minute Intel/8GB performance']
}
pathlib.Path('dist/build.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
PYBUILD
