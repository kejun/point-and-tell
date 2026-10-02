import base64
import copy
import hashlib
import pathlib
import plistlib
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from release_support import bundle_info, release_notes, validate_archive, validate_feed


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.folder = pathlib.Path(self.temp.name)
        self.public = base64.b64encode(bytes(range(32))).decode()
        self.archive = self.folder / "Point-and-Tell-v0.4.0-macOS-universal.zip"
        self.info = {
            "CFBundleIdentifier": "io.github.kejun.point-and-tell",
            "CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "10",
            "LSMinimumSystemVersion": "11.0", "SUPublicEDKey": self.public,
            "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
            "SUAllowsAutomaticUpdates": False,
            "SUFeedURL": "https://raw.githubusercontent.com/kejun/point-and-tell/main/updates/appcast.xml",
        }
        self.write_zip()
        self.manifest = {
            "version": "0.4.0", "build": "10", "archive": self.archive.name,
            "source_commit": "a" * 40, "architecture": "universal",
            "slices": ["arm64", "x86_64"], "update_public_key": self.public,
            "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "bytes": self.archive.stat().st_size,
        }

    def write_zip(self):
        with zipfile.ZipFile(self.archive, "w") as z:
            z.writestr("Point & Tell.app/Contents/Info.plist", plistlib.dumps(self.info))

    def test_archive_identity_key_and_final_bytes(self):
        validate_archive(self.archive, self.manifest, self.public)
        for key, value in [("update_public_key", "bad"), ("build", "11"), ("sha256", "0" * 64)]:
            with self.subTest(key=key):
                changed = copy.deepcopy(self.manifest)
                changed[key] = value
                with self.assertRaises(ValueError):
                    validate_archive(self.archive, changed, self.public)
        self.archive.write_bytes(self.archive.read_bytes() + b"changed after signing")
        with self.assertRaisesRegex(ValueError, "differs"):
            validate_archive(self.archive, self.manifest, self.public)

    def test_reject_wrong_application_or_weakened_policy(self):
        self.info["CFBundleIdentifier"] = "another.app"
        self.write_zip()
        with self.assertRaisesRegex(ValueError, "Wrong application"):
            bundle_info(self.archive)
        self.info["CFBundleIdentifier"] = "io.github.kejun.point-and-tell"
        self.info["SURequireSignedFeed"] = False
        self.write_zip()
        with self.assertRaisesRegex(ValueError, "enforcement"):
            validate_archive(self.archive, self.manifest, self.public)

    def test_notes_are_version_scoped_and_escape_markup(self):
        notes = release_notes("# Changelog\n\n## 0.4.0 — Today\n\n- <script>hello</script>\n\n## 0.3.3\nOld", "0.4.0")
        self.assertIn("&lt;script&gt;", notes)
        self.assertNotIn("Old", notes)
        with self.assertRaises(ValueError):
            release_notes("## 0.3.3\nOld", "0.4.0")

    def test_feed_rejects_mutable_downloads_downgrades_and_missing_signature(self):
        signature = base64.b64encode(bytes(range(64))).decode()
        url = f"https://raw.githubusercontent.com/kejun/point-and-tell/{'b' * 40}/releases/v0.4.0/{self.archive.name}"
        feed = f'''<?xml version="1.0"?>
<!-- edSignature="fixture; cryptography verified separately by native integration" -->
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>10</sparkle:version><sparkle:shortVersionString>0.4.0</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
<enclosure url="{url}" length="{self.manifest['bytes']}" sparkle:edSignature="{signature}"/>
</item></channel></rss>'''
        path = self.folder / "appcast.xml"
        path.write_text(feed)
        self.assertEqual(validate_feed(path, self.manifest, "b" * 40, self.public), signature)
        invalid = [
            feed.replace("b" * 40, "main"),
            feed.replace(signature, ""),
            feed.replace("<sparkle:version>10", "<sparkle:version>9"),
            feed.replace("11.0</sparkle:minimum", "12.0</sparkle:minimum"),
            feed.replace("</channel>", "<item><sparkle:version>11</sparkle:version></item></channel>"),
        ]
        for changed in invalid:
            path.write_text(changed)
            with self.assertRaises(ValueError):
                validate_feed(path, self.manifest, "b" * 40, self.public)


if __name__ == "__main__":
    unittest.main()
