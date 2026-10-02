#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
INSTALL_FIXTURE="$(mktemp -d)"
SERVER_PID=""
APP_PID=""
cleanup() {
  [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
  [[ -z "$APP_PID" ]] || kill "$APP_PID" 2>/dev/null || true
  rm -rf "$INSTALL_FIXTURE"
}
trap cleanup EXIT
export INSTALL_FIXTURE
mkdir -p "$INSTALL_FIXTURE/feed" "$INSTALL_FIXTURE/current"
python3 -u - <<'PY' > "$INSTALL_FIXTURE/server.log" 2>&1 &
import functools, http.server, os, pathlib
root = pathlib.Path(os.environ["INSTALL_FIXTURE"])
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root / "feed"))
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for attempt in {1..50}; do
  [[ ! -f "$INSTALL_FIXTURE/port" ]] || break
  sleep 0.1
done
PORT="$(cat "$INSTALL_FIXTURE/port")"
export PORT
TEST_PUBLIC="$(swift scripts/update-signing.swift generate "$INSTALL_FIXTURE/key")"
export TEST_PUBLIC
FRAMEWORK="$(python3 scripts/sparkle-path.py --framework)"
SIGN="$(python3 scripts/sparkle-path.py --tool sign_update)"
GENERATE="$(python3 scripts/sparkle-path.py --tool generate_appcast)"
APP="$INSTALL_FIXTURE/Update Fixture.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
ditto "dist/Point & Tell.app/Contents/Frameworks/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
clang -fobjc-arc -mmacosx-version-min=11.0 -F "$(dirname "$FRAMEWORK")" \
  -framework AppKit -framework Sparkle -Wl,-rpath,@executable_path/../Frameworks \
  scripts/tests/UpdateFixture.m -o "$APP/Contents/MacOS/UpdateFixture"
python3 - <<'PY'
import os, pathlib, plistlib, uuid
root = pathlib.Path(os.environ["INSTALL_FIXTURE"])
info = {
    "CFBundleIdentifier": "io.github.kejun.point-and-tell.update-test." + uuid.uuid4().hex,
    "CFBundleName": "Update Fixture", "CFBundleExecutable": "UpdateFixture",
    "CFBundlePackageType": "APPL", "CFBundleVersion": "2", "CFBundleShortVersionString": "1.0.1",
    "LSMinimumSystemVersion": "11.0", "SUPublicEDKey": os.environ["TEST_PUBLIC"],
    "SUFeedURL": f"http://127.0.0.1:{os.environ['PORT']}/appcast.xml",
    "SUEnableAutomaticChecks": False, "SUAllowsAutomaticUpdates": False,
    "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
    "PTTestResult": str(root / "result"),
    # Deliberately confined to this throwaway test bundle; production uses HTTPS.
    "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True},
}
(root / "Update Fixture.app/Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$APP"
ditto -c -k --keepParent "$APP" "$INSTALL_FIXTURE/feed/fixture.zip"
"$GENERATE" --ed-key-file "$INSTALL_FIXTURE/key" --maximum-deltas 0 \
  --download-url-prefix "http://127.0.0.1:$PORT/" "$INSTALL_FIXTURE/feed"
"$SIGN" --ed-key-file "$INSTALL_FIXTURE/key" --verify "$INSTALL_FIXTURE/feed/appcast.xml"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 1" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.0" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
mv "$APP" "$INSTALL_FIXTURE/current/Update Fixture.app"
APP="$INSTALL_FIXTURE/current/Update Fixture.app"
"$APP/Contents/MacOS/UpdateFixture" > "$INSTALL_FIXTURE/app.log" 2>&1 &
APP_PID=$!
for attempt in {1..180}; do
  [[ ! -f "$INSTALL_FIXTURE/result" ]] || break
  sleep 0.5
done
if [[ ! -f "$INSTALL_FIXTURE/result" ]] || [[ "$(cat "$INSTALL_FIXTURE/result")" != UPDATED_AND_RELAUNCHED ]]; then
  cat "$INSTALL_FIXTURE/app.log" "$INSTALL_FIXTURE/server.log"
  [[ ! -f "$INSTALL_FIXTURE/result" ]] || cat "$INSTALL_FIXTURE/result"
  echo "Isolated update/relaunch failed." >&2
  exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == 2 ]]
codesign --verify --deep --strict "$APP"
echo "UPDATE_INSTALL_OK: isolated build 1 replaced by signed build 2 and relaunched"
