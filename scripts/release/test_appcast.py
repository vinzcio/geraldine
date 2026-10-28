"""Checks for the appcast writer: python3 -B scripts/release/test_appcast.py"""

import base64
import importlib.util
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("appcast", HERE / "appcast.py")
appcast = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcast)

SIGNATURE = base64.b64encode(bytes(range(64))).decode()
URL = "https://geraldine.hemisthia.com/updates/Geraldine-0.2.0-101.zip"
PUB_DATE = "Wed, 28 Oct 2026 04:00:00 GMT"


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        self.notes = self.root / "notes.md"
        self.notes.write_text("## What's new\n\n- Geraldine updates itself & <stays> awake.\n")

    def tearDown(self):
        self.folder.cleanup()

    def write(self, **overrides):
        arguments = {
            "--version": "0.2.0", "--build": "101", "--url": URL, "--length": "8123456",
            "--ed-signature": SIGNATURE, "--notes": str(self.notes), "--hardware": "arm64",
            "--pub-date": PUB_DATE,
        }
        arguments.update(overrides)
        output = self.root / "appcast.xml"
        argv = ["write", "--output", str(output)]
        for key, value in arguments.items():
            if value is True:
                argv.append(key)
            elif value is not None:
                argv += [key, value]
        return appcast.main(argv), output

    def test_writes_one_complete_item(self):
        status, output = self.write()
        self.assertEqual(status, 0)
        root = ET.parse(output).getroot()
        item = root.find("channel/item")
        ns = appcast.SPARKLE
        self.assertEqual(item.findtext(f"{ns}version"), "101")
        self.assertEqual(item.findtext(f"{ns}shortVersionString"), "0.2.0")
        self.assertEqual(item.findtext(f"{ns}minimumSystemVersion"), "14.0")
        self.assertEqual(item.findtext(f"{ns}hardwareRequirements"), "arm64")
        self.assertEqual(item.find("description").get(f"{ns}format"), "markdown")
        self.assertIn("& <stays> awake", item.findtext("description"))
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), URL)
        self.assertEqual(enclosure.get("length"), "8123456")
        self.assertEqual(enclosure.get(f"{ns}edSignature"), SIGNATURE)
        self.assertEqual(len(root.findall("channel/item")), 1)

        described = appcast.items(output)
        self.assertEqual(described[0]["build"], "101")
        self.assertFalse(described[0]["signedFeed"])
        self.assertEqual(appcast.latest_build(output), 101)

    def test_reads_a_signed_feed(self):
        status, output = self.write()
        self.assertEqual(status, 0)
        output.write_text(output.read_text() + "<!-- sparkle-signatures:\nedSignature: abc\nlength: 1\n-->\n")
        self.assertTrue(appcast.items(output)[0]["signedFeed"])
        self.assertEqual(appcast.latest_build(output), 101)

    def test_refuses_unsafe_or_inconsistent_releases(self):
        refused = [
            {"--url": URL.replace("https://", "http://")},
            {"--url": "https://geraldine.hemisthia.com/updates/Geraldine-0.2.0-102.zip"},
            {"--url": "https://geraldine.hemisthia.com/updates/Other-0.2.0-101.zip"},
            {"--ed-signature": base64.b64encode(b"short").decode()},
            {"--ed-signature": "not base64!"},
            {"--build": "0"},
            {"--build": "10a"},
            {"--version": "two"},
            {"--length": "0"},
            {"--hardware": "ppc"},
            {"--pub-date": "yesterday"},
        ]
        for overrides in refused:
            status, _ = self.write(**overrides)
            self.assertEqual(status, 1, overrides)

    def test_release_notes_must_exist_and_stay_inside_cdata(self):
        self.notes.write_text("  \n")
        self.assertEqual(self.write()[0], 1)
        self.notes.write_text("broken ]]> notes")
        self.assertEqual(self.write()[0], 1)

    def test_loopback_http_needs_the_test_flag(self):
        url = "http://127.0.0.1:8765/Geraldine-0.2.0-101.zip"
        self.assertEqual(self.write(**{"--url": url})[0], 1)
        self.assertEqual(self.write(**{"--url": url, "--allow-loopback-http": True})[0], 0)
        self.assertEqual(
            self.write(**{"--url": "http://example.com:8765/Geraldine-0.2.0-101.zip", "--allow-loopback-http": True})[0],
            1,
        )

    def test_latest_build_of_an_unreadable_feed_is_an_error(self):
        broken = self.root / "broken.xml"
        broken.write_text("<html>404</html>")
        with self.assertRaises(appcast.AppcastError):
            appcast.latest_build(broken)
        self.assertEqual(appcast.main(["latest-build", str(broken)]), 1)

    def test_inspect_prints_json(self):
        _, output = self.write()
        import contextlib
        import io

        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            self.assertEqual(appcast.main(["inspect", str(output)]), 0)
        self.assertEqual(json.loads(captured.getvalue())[0]["url"], URL)


if __name__ == "__main__":
    unittest.main()
