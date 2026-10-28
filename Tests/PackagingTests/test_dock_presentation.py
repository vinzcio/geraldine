"""Guard the LaunchServices declaration that keeps menu-bar-only out of the Dock."""

from pathlib import Path
import plistlib
import re
from string import Template
import unittest


class DockPresentationTests(unittest.TestCase):
    def test_bundle_starts_as_an_agent_before_preferences_are_loaded(self):
        script = (Path(__file__).resolve().parents[2] / "build.sh").read_text()
        template = re.search(
            r'^cat > "\$CONTENTS/Info.plist" <<PLIST\n(.*?)^PLIST$',
            script,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(template, "build.sh must provide a testable bundle plist")
        xml = Template(template.group(1)).substitute(
            APP_NAME="Geraldine",
            BUNDLE_ID="com.example.geraldine-packaging-test",
            VERSION="0.0.0",
            BUILD_NUMBER="0",
            UPDATE_KEYS="",
            GIT_COMMIT="test",
            GIT_COMMIT_SHORT="test",
            GIT_DIRTY_PLIST="<false/>",
            BUILD_DATE="test",
            CONFIG="release",
            ICON_KEY="",
        )
        plist = plistlib.loads(xml.encode())
        self.assertIs(
            plist.get("LSUIElement"),
            True,
            "LaunchServices must not add a Dock icon before AppShape applies the saved mode",
        )


if __name__ == "__main__":
    unittest.main()
