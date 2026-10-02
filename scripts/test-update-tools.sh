#!/bin/bash
# Real Sparkle/CryptoKit integration using a disposable key and an isolated app.
# Never contacts the production feed, installs, or touches user Keychain entries.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
TEST_PUBLIC="$(swift scripts/update-signing.swift generate "$FIXTURE/key")"
SIGN="$(python3 scripts/sparkle-path.py --tool sign_update)"
GENERATE="$(python3 scripts/sparkle-path.py --tool generate_appcast)"
mkdir -p "$FIXTURE/archives"
ditto "dist/Point & Tell.app" "$FIXTURE/Point & Tell.app"
export FIXTURE TEST_PUBLIC
python3 - <<'PY'
import os, pathlib, plistlib
p = pathlib.Path(os.environ["FIXTURE"]) / "Point & Tell.app/Contents/Info.plist"
info = plistlib.loads(p.read_bytes())
info["SUPublicEDKey"] = os.environ["TEST_PUBLIC"]
p.write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$FIXTURE/Point & Tell.app"
codesign --verify --deep --strict "$FIXTURE/Point & Tell.app"
ditto -c -k --sequesterRsrc --keepParent "$FIXTURE/Point & Tell.app" "$FIXTURE/archives/test.zip"
SIGNATURE="$("$SIGN" --ed-key-file "$FIXTURE/key" -p "$FIXTURE/archives/test.zip")"
swift scripts/update-signing.swift verify "$TEST_PUBLIC" "$FIXTURE/archives/test.zip" "$SIGNATURE"
cp "$FIXTURE/archives/test.zip" "$FIXTURE/tampered.zip"
printf 'tampered' >> "$FIXTURE/tampered.zip"
if swift scripts/update-signing.swift verify "$TEST_PUBLIC" "$FIXTURE/tampered.zip" "$SIGNATURE"; then
  echo "Tampered archive was accepted!" >&2; exit 1
fi
"$GENERATE" --ed-key-file "$FIXTURE/key" --maximum-deltas 0 \
  --download-url-prefix "https://example.invalid/releases/" "$FIXTURE/archives"
"$SIGN" --ed-key-file "$FIXTURE/key" --verify "$FIXTURE/archives/appcast.xml"
python3 - <<'PY'
import base64, json, os, pathlib, plistlib, sys, xml.etree.ElementTree as E
p = pathlib.Path(os.environ["FIXTURE"])
item, = E.parse(p / "archives/appcast.xml").findall("./channel/item")
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
assert item.findtext(ns + "minimumSystemVersion") == "11.0"
info = plistlib.loads((p / "Point & Tell.app/Contents/Info.plist").read_bytes())
assert item.findtext(ns + "version") == info["CFBundleVersion"]
assert item.find("enclosure").get("url") == "https://example.invalid/releases/test.zip"
assert int(item.find("enclosure").get("length")) == (p / "archives/test.zip").stat().st_size
sys.path.insert(0, "scripts")
from release_support import validate_feed
manifest = json.loads(pathlib.Path("dist/build.json").read_text())
manifest.update(archive="test.zip", bytes=(p / "archives/test.zip").stat().st_size,
                update_public_key=os.environ["TEST_PUBLIC"])
# Verify the real generator's element/signature layout against our publisher's
# guards. Use a copy with the immutable URL; cryptographic verification above
# already checked the untouched original feed.
immutable_url = ("https://raw.githubusercontent.com/kejun/point-and-tell/" + "b" * 40
                 + "/releases/v" + manifest["version"] + "/test.zip")
validation_copy = p / "validation.xml"
validation_copy.write_text((p / "archives/appcast.xml").read_text().replace(
    "https://example.invalid/releases/test.zip", immutable_url))
validate_feed(validation_copy, manifest, "b" * 40, os.environ["TEST_PUBLIC"])
feed = p / "archives/appcast.xml"
feed.write_text(feed.read_text().replace("example.invalid", "tampered.invalid"))
PY
if "$SIGN" --ed-key-file "$FIXTURE/key" --verify "$FIXTURE/archives/appcast.xml"; then
  echo "Tampered feed was accepted!" >&2; exit 1
fi
echo "UPDATE_TOOLS_OK: real archive/feed signatures, corruption rejection, macOS 11 metadata"
