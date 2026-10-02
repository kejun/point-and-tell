#!/usr/bin/env python3
"""Validate immutable release inputs and the appcast before making it visible."""
import argparse
import base64
import hashlib
import html
import json
import os
import pathlib
import plistlib
import re
import shutil
import xml.etree.ElementTree as ET
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
REPO = "kejun/point-and-tell"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def bundle_info(archive):
    with zipfile.ZipFile(archive) as z:
        require(z.testzip() is None, "Corrupt ZIP")
        info = plistlib.loads(z.read("Point & Tell.app/Contents/Info.plist"))
        require(info["CFBundleIdentifier"] == "io.github.kejun.point-and-tell", "Wrong application")
        return info


def release_notes(text, version):
    match = re.search(r"^## " + re.escape(version) + r"(?:\s[^\n]*)?\n(.*?)(?=^## |\Z)",
                      text, re.M | re.S)
    require(match is not None and match[1].strip(), "Missing version's changelog")
    return "<h2>Point &amp; Tell " + html.escape(version) + "</h2>\n<pre>" + html.escape(match[1].strip()) + "</pre>\n"


def validate_archive(archive, manifest, public_key):
    info = bundle_info(archive)
    require(info["CFBundleShortVersionString"] == manifest["version"], "Version mismatch")
    require(info["CFBundleVersion"] == manifest["build"], "Build mismatch")
    require(re.fullmatch(r"[1-9][0-9]*", manifest["build"]) is not None, "Invalid build number")
    require(info["LSMinimumSystemVersion"] == "11.0", "Minimum macOS changed")
    require(len(base64.b64decode(public_key, validate=True)) == 32, "Invalid public key")
    require(info.get("SUPublicEDKey") == public_key == manifest.get("update_public_key"), "Signing key mismatch")
    require(info.get("SUVerifyUpdateBeforeExtraction") is True and info.get("SURequireSignedFeed") is True,
            "Missing signature enforcement")
    require(info.get("SUAllowsAutomaticUpdates") is False, "Installation must require confirmation")
    require(info.get("SUFeedURL") == f"https://raw.githubusercontent.com/{REPO}/main/updates/appcast.xml",
            "Wrong feed URL")
    data = archive.read_bytes()
    require(hashlib.sha256(data).hexdigest() == manifest["sha256"] and len(data) == manifest["bytes"],
            "Archive differs from build manifest")
    require(manifest["architecture"] == "universal" and set(manifest["slices"]) == {"arm64", "x86_64"},
            "Universal archive required")
    require(re.fullmatch(r"[0-9a-f]{40}", manifest["source_commit"]) is not None, "Invalid source SHA")
    return info


def validate_feed(feed, manifest, archive_commit, public_key):
    require(re.fullmatch(r"[0-9a-f]{40}", archive_commit) is not None, "Invalid archive commit")
    raw = pathlib.Path(feed).read_text()
    # Cryptographic feed verification is separately performed by sign_update.
    require("<!--" in raw and "edSignature=" in raw, "Feed must be signed by Sparkle")
    root = ET.fromstring(raw)
    items = root.findall("./channel/item")
    current = [item for item in items if item.findtext(NS + "version") == manifest["build"]]
    require(len(current) == 1, "Expected exactly one current build")
    require(max(int(i.findtext(NS + "version", "0")) for i in items) == int(manifest["build"]),
            "Refusing appcast downgrade")
    item = current[0]
    require(item.findtext(NS + "shortVersionString") == manifest["version"], "Appcast display version mismatch")
    require(item.findtext(NS + "minimumSystemVersion") == "11.0", "Appcast minimum macOS mismatch")
    enclosure = item.find("enclosure")
    require(enclosure is not None, "Missing download")
    expected = f"https://raw.githubusercontent.com/{REPO}/{archive_commit}/releases/v{manifest['version']}/{manifest['archive']}"
    require(enclosure.get("url") == expected, "Download must point to immutable archive commit")
    require(enclosure.get("length") == str(manifest["bytes"]), "Appcast byte count mismatch")
    signature = enclosure.get(NS + "edSignature", "")
    require(len(base64.b64decode(signature, validate=True)) == 64, "Missing archive Ed25519 signature")
    require(manifest.get("update_public_key") == public_key, "Public key changed")
    return signature


def prepare():
    version = (ROOT / "VERSION").read_text().strip()
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) is not None, "Stable version required")
    require(not (ROOT / "releases" / ("v" + version)).exists(), "Published versions are immutable; bump VERSION")
    manifest = json.loads((ROOT / "dist/build.json").read_text())
    require(manifest["version"] == version, "Build is stale")
    require(manifest["source_commit"] == os.environ["SOURCE_COMMIT"], "Source commit mismatch")
    name = manifest["archive"]
    require(name == f"Point-and-Tell-v{version}-macOS-universal.zip", "Unexpected archive name")
    archive = ROOT / "dist" / name
    validate_archive(archive, manifest, os.environ["SPARKLE_PUBLIC_ED_KEY"].strip())
    for old in (ROOT / "releases").glob("v*/build.json"):
        old_manifest = json.loads(old.read_text())
        old_info = bundle_info(old.parent / old_manifest["archive"])
        require(int(manifest["build"]) > int(old_info["CFBundleVersion"]), "Build number must increase")
        require(tuple(map(int, version.split("."))) > tuple(map(int, old_manifest["version"].split("."))),
                "Version must increase")
        old_key = old_info.get("SUPublicEDKey")
        require(old_key is None or old_key == manifest["update_public_key"], "Signing key rotation needs a separate migration")
    notes = release_notes((ROOT / "CHANGELOG.md").read_text(), version)
    stage = ROOT / "dist/update-release"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    shutil.copy2(archive, stage / name)
    (stage / (name + ".sha256")).write_text(manifest["sha256"] + "  " + name + "\n")
    (stage / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (stage / pathlib.Path(name).with_suffix(".html")).write_text(notes)
    print("Prepared immutable release v" + version)


def update_downloads():
    version = (ROOT / "VERSION").read_text().strip()
    readme = ROOT / "README.md"
    replacement = (
        "<!-- published-release:start -->\n"
        f"[Download v{version} Universal](releases/v{version}/Point-and-Tell-v{version}-macOS-universal.zip?raw=true)"
        " for Intel and Apple Silicon. "
        f"The signed-update installation ZIP, SHA-256 checksum and exact source/build manifest are in "
        f"[releases/v{version}](releases/v{version}).\n"
        "<!-- published-release:end -->"
    )
    text, count = re.subn(r"<!-- published-release:start -->.*?<!-- published-release:end -->",
                         lambda _: replacement, readme.read_text(), flags=re.S)
    require(count == 1, "README download block missing or duplicated")
    readme.write_text(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["prepare", "verify-feed", "update-downloads"])
    parser.add_argument("--archive-commit")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare()
    elif args.command == "update-downloads":
        update_downloads()
    else:
        manifest = json.loads((ROOT / "dist/update-release/build.json").read_text())
        signature = validate_feed(ROOT / "updates/appcast.xml", manifest, args.archive_commit,
                                  os.environ["SPARKLE_PUBLIC_ED_KEY"].strip())
        print(signature)


if __name__ == "__main__":
    main()
