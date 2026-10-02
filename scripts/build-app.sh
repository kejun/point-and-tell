#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$VERSION" == "$PLIST_VERSION" ]] || { echo "Version mismatch" >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=11.0
ARCH="${ARCH:-x86_64}"
swift build -c release --arch "$ARCH"
BIN_DIR="$(swift build -c release --arch "$ARCH" --show-bin-path)"
APP="dist/Point & Tell.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PointAndTell" "$APP/Contents/MacOS/PointAndTell"
cp Resources/Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/PointAndTell"
# Ad-hoc signature, no Developer ID or notarization credentials.
codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
file "$APP/Contents/MacOS/PointAndTell"
otool -l "$APP/Contents/MacOS/PointAndTell" | grep -A5 LC_BUILD_VERSION
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Point-and-Tell-v${VERSION}-macOS-${ARCH}.zip"
shasum -a 256 "dist/Point-and-Tell-v${VERSION}-macOS-${ARCH}.zip" > "dist/Point-and-Tell-v${VERSION}-macOS-${ARCH}.zip.sha256"

[[ "$(lipo -archs "$APP/Contents/MacOS/PointAndTell")" == "$ARCH" ]] || { echo "Wrong architecture" >&2; exit 1; }
MIN_OS="$(otool -l "$APP/Contents/MacOS/PointAndTell" | awk '$1 == "minos" { print $2; exit }')"
[[ "$MIN_OS" == "11.0" ]] || { echo "Wrong minimum macOS: $MIN_OS" >&2; exit 1; }
export VERSION ARCH MIN_OS
python3 - <<'PYBUILD'
import hashlib,json,os,pathlib,subprocess,zipfile
p=pathlib.Path(f"dist/Point-and-Tell-v{os.environ['VERSION']}-macOS-{os.environ['ARCH']}.zip")
with zipfile.ZipFile(p) as z:
    executable=z.getinfo('Point & Tell.app/Contents/MacOS/PointAndTell')
    assert (executable.external_attr >> 16) & 0o111, 'ZIP lost executable permissions'
    assert z.testzip() is None
manifest={
 'version':os.environ['VERSION'],
 'source_commit':os.environ.get('SOURCE_COMMIT') or subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'architecture':os.environ['ARCH'], 'minimum_macos':os.environ['MIN_OS'],
 'archive':p.name, 'sha256':hashlib.sha256(p.read_bytes()).hexdigest(), 'bytes':p.stat().st_size,
 'signature':'ad-hoc; codesign --verify --strict passed', 'notarized':False,
 'ci_run_url':f"https://github.com/{os.environ.get('GITHUB_REPOSITORY','kejun/point-and-tell')}/actions/runs/{os.environ.get('GITHUB_RUN_ID','local')}",
 'unverified':['macOS 11 device runtime','screen and microphone permissions','real billed ASR request','10-minute Intel/8GB performance']
}
pathlib.Path('dist/build.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
PYBUILD
