"""Guard the bundle keys that decide whether and how Geraldine updates itself."""

from pathlib import Path
import plistlib
import re
from string import Template
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "build.sh").read_text()
PRODUCTION_FEED = "https://geraldine.hemisthia.com/updates/appcast.xml"


def assignment(name):
    match = re.search(rf'^{name}="([^"\n]*)"$', SCRIPT, re.MULTILINE)
    if match is None:
        raise AssertionError(f"build.sh must assign {name}")
    return match.group(1)


def production_update_keys():
    match = re.search(r'^  production\)\n.*?UPDATE_KEYS="(.*?)"\n    ;;', SCRIPT, re.MULTILINE | re.DOTALL)
    if match is None:
        raise AssertionError("build.sh must define the production UPDATE_KEYS block")
    return match.group(1)


def bundle_plist(update_keys):
    template = re.search(
        r'^cat > "\$CONTENTS/Info.plist" <<PLIST\n(.*?)^PLIST$',
        SCRIPT,
        re.MULTILINE | re.DOTALL,
    ).group(1)
    xml = Template(template).substitute(
        APP_NAME="Geraldine",
        BUNDLE_ID="com.example.geraldine-packaging-test",
        VERSION="0.2.0",
        BUILD_NUMBER="123",
        UPDATE_KEYS=update_keys,
        GIT_COMMIT="test",
        GIT_COMMIT_SHORT="test",
        GIT_DIRTY_PLIST="<false/>",
        BUILD_DATE="test",
        CONFIG="release",
        ICON_KEY="",
    )
    return plistlib.loads(xml.encode())


class UpdatePackagingTests(unittest.TestCase):
    def test_builds_default_to_no_update_channel(self):
        self.assertIn('UPDATE_CHANNEL="${GERALDINE_UPDATE_CHANNEL:-none}"', SCRIPT)
        plist = bundle_plist("")
        for key in ("SUFeedURL", "SUPublicEDKey", "GeraldineUpdateChannel"):
            self.assertNotIn(key, plist)

    def test_build_number_is_the_compared_version(self):
        plist = bundle_plist("")
        self.assertEqual(plist["CFBundleVersion"], "123")
        self.assertEqual(plist["CFBundleShortVersionString"], "0.2.0")
        self.assertIn("rev-list --count HEAD", SCRIPT)

    def test_production_channel_requires_signed_feed_and_archive_verification(self):
        keys = Template(production_update_keys()).substitute(
            PRODUCTION_FEED_URL=assignment("PRODUCTION_FEED_URL"),
            PRODUCTION_SPARKLE_PUBLIC_KEY=assignment("PRODUCTION_SPARKLE_PUBLIC_KEY"),
        )
        plist = bundle_plist(keys)
        self.assertEqual(plist["GeraldineUpdateChannel"], "production")
        self.assertEqual(plist["SUFeedURL"], PRODUCTION_FEED)
        self.assertEqual(plist["SUPublicEDKey"], assignment("PRODUCTION_SPARKLE_PUBLIC_KEY"))
        self.assertIs(plist["SURequireSignedFeed"], True)
        self.assertIs(plist["SUVerifyUpdateBeforeExtraction"], True)
        self.assertIs(plist["SUEnableAutomaticChecks"], True)
        self.assertIs(plist["SUAutomaticallyUpdate"], True)
        self.assertEqual(plist["SUScheduledCheckInterval"], 3600)
        # Sparkle sends a system profile only when asked to; Geraldine never asks.
        self.assertNotIn("SUEnableSystemProfiling", plist)

    def test_production_key_is_a_real_ed25519_public_key(self):
        import base64

        key = assignment("PRODUCTION_SPARKLE_PUBLIC_KEY")
        self.assertEqual(len(base64.b64decode(key, validate=True)), 32)

    def test_update_channels_refuse_ad_hoc_signing(self):
        self.assertRegex(
            SCRIPT,
            r'if \[ "\$UPDATE_CHANNEL" != "none" \] && \[ "\$CODESIGN_ID" = "-" \]; then',
        )

    def test_only_ad_hoc_builds_relax_library_validation(self):
        # An ad-hoc app cannot otherwise load its own ad-hoc Sparkle.framework
        # under the hardened runtime; Developer ID builds keep full validation.
        function = re.search(r"^sign_and_verify\(\) \{\n(.*?)^\}$", SCRIPT, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(function)
        body = function.group(1)
        ad_hoc_branch, developer_id_branch = body.split("  elif [ -f \"$ENT\" ]; then", 1)
        self.assertIn('if [ "$CODESIGN_ID" = "-" ]; then', ad_hoc_branch)
        # PlistBuddy, not plutil: plutil key paths split this key at its dots.
        self.assertIn("PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true'", ad_hoc_branch)
        self.assertNotIn("disable-library-validation", developer_id_branch)
        checked_in = plistlib.loads((ROOT / "Geraldine.entitlements").read_bytes())
        self.assertNotIn("com.apple.security.cs.disable-library-validation", checked_in)

    def test_sparkle_is_embedded_and_signed_before_the_app(self):
        embed = SCRIPT.index('/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"')
        sign_framework = SCRIPT.index('sign_sparkle_framework "$APP"')
        sign_app = SCRIPT.index('sign_and_verify "$APP"\nverify_bundle_provenance')
        self.assertLess(embed, sign_framework)
        self.assertLess(sign_framework, sign_app)
        self.assertIn("codesign --verify --deep --strict", SCRIPT)


if __name__ == "__main__":
    unittest.main()
