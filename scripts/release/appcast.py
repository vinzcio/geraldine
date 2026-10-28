#!/usr/bin/env python3
"""Write and read Geraldine's Sparkle appcast.

The feed lists only the newest release: every client goes straight to it, and
Sparkle never installs an older build. Signing happens afterwards with
Sparkle's sign_update, which embeds the feed signature in the file.

  appcast.py write --output appcast.xml --version 0.2.0 --build 101 \
      --url https://geraldine.hemisthia.com/updates/Geraldine-0.2.0-101.zip \
      --length 8123456 --ed-signature <base64> --notes notes.md \
      [--minimum-system-version 14.0] [--hardware arm64] [--pub-date <RFC 2822>]
  appcast.py inspect appcast.xml     # JSON description of every item
  appcast.py latest-build appcast.xml  # highest sparkle:version, or nothing
"""

import argparse
import base64
import email.utils
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SPARKLE = "{%s}" % SPARKLE_NS
VERSION_PATTERN = re.compile(r"^[0-9]+(\.[0-9]+){1,3}$")
BUILD_PATTERN = re.compile(r"^[1-9][0-9]*$")
ARCHIVE_PATTERN = re.compile(r"^https://[^\s\"'<>]+/Geraldine-[0-9][0-9A-Za-z.]*-[0-9]+\.zip$")
# Only the local update-test lane serves plain HTTP, and only from loopback.
LOOPBACK_ARCHIVE_PATTERN = re.compile(r"^http://127\.0\.0\.1:[0-9]{2,5}/Geraldine-[0-9][0-9A-Za-z.]*-[0-9]+\.zip$")


class AppcastError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise AppcastError(message)


def validated_signature(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except ValueError:
        raise AppcastError("--ed-signature must be base64")
    require(len(raw) == 64, "--ed-signature must decode to a 64-byte Ed25519 signature")
    return value


def release_notes(path):
    text = Path(path).read_text(encoding="utf-8").strip()
    require(text, "the release notes are empty")
    require("]]>" not in text, "the release notes cannot contain ']]>'")
    return text


def render(version, build, url, length, ed_signature, notes, minimum_system_version, hardware, pub_date,
           allow_loopback_http=False):
    require(VERSION_PATTERN.match(version), f"version {version!r} must look like 0.2.0")
    require(BUILD_PATTERN.match(build), f"build {build!r} must be a positive whole number")
    require(ARCHIVE_PATTERN.match(url) or (allow_loopback_http and LOOPBACK_ARCHIVE_PATTERN.match(url)),
            f"archive URL {url!r} must be https and named Geraldine-<version>-<build>.zip")
    require(url.endswith(f"/Geraldine-{version}-{build}.zip"), "the archive name must match the version and build")
    require(length > 0, "the archive length must be positive")
    validated_signature(ed_signature)
    require(VERSION_PATTERN.match(minimum_system_version), "the minimum system version must look like 14.0")
    require(hardware in (None, "arm64", "x86_64"), "hardware must be arm64 or x86_64")
    require(email.utils.parsedate_tz(pub_date) is not None, "the publication date must be RFC 2822")

    hardware_line = (
        f"            <sparkle:hardwareRequirements>{hardware}</sparkle:hardwareRequirements>\n" if hardware else ""
    )
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">\n'
        "    <channel>\n"
        "        <title>Geraldine</title>\n"
        "        <item>\n"
        f"            <title>{escape(version)}</title>\n"
        f"            <pubDate>{escape(pub_date)}</pubDate>\n"
        f"            <sparkle:version>{build}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>\n"
        f"            <sparkle:minimumSystemVersion>{minimum_system_version}</sparkle:minimumSystemVersion>\n"
        f"{hardware_line}"
        f'            <description sparkle:format="markdown"><![CDATA[{notes}]]></description>\n'
        f"            <enclosure url={quoteattr(url)} length=\"{length}\" type=\"application/octet-stream\""
        f" sparkle:edSignature={quoteattr(ed_signature)}/>\n"
        "        </item>\n"
        "    </channel>\n"
        "</rss>\n"
    )


def strip_signature(text):
    """Sparkle appends its feed signature as a trailing comment."""
    return re.sub(r"<!-- sparkle-signatures:.*?-->\s*$", "", text, flags=re.DOTALL)


def items(path):
    text = Path(path).read_text(encoding="utf-8")
    try:
        root = ET.fromstring(strip_signature(text).encode("utf-8"))
    except ET.ParseError as error:
        raise AppcastError(f"{path} is not a readable appcast: {error}")
    channel = root.find("channel")
    require(root.tag == "rss" and channel is not None, f"{path} is not an RSS appcast")
    found = []
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        require(enclosure is not None, "every appcast item needs an enclosure")
        build = (item.findtext(f"{SPARKLE}version") or enclosure.get(f"{SPARKLE}version") or "").strip()
        found.append({
            "build": build,
            "version": (item.findtext(f"{SPARKLE}shortVersionString")
                        or enclosure.get(f"{SPARKLE}shortVersionString") or "").strip(),
            "url": enclosure.get("url"),
            "length": int(enclosure.get("length") or 0),
            "edSignature": enclosure.get(f"{SPARKLE}edSignature"),
            "minimumSystemVersion": (item.findtext(f"{SPARKLE}minimumSystemVersion") or "").strip(),
            "hardwareRequirements": (item.findtext(f"{SPARKLE}hardwareRequirements") or "").strip(),
            "signedFeed": "<!-- sparkle-signatures:" in text,
        })
    return found


def latest_build(path):
    builds = [int(item["build"]) for item in items(path) if BUILD_PATTERN.match(item["build"])]
    return max(builds) if builds else None


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    write = commands.add_parser("write")
    write.add_argument("--output", required=True)
    write.add_argument("--version", required=True)
    write.add_argument("--build", required=True)
    write.add_argument("--url", required=True)
    write.add_argument("--length", required=True, type=int)
    write.add_argument("--ed-signature", required=True)
    write.add_argument("--notes", required=True)
    write.add_argument("--minimum-system-version", default="14.0")
    write.add_argument("--hardware")
    write.add_argument("--pub-date", default=email.utils.formatdate(localtime=False, usegmt=True))
    write.add_argument("--allow-loopback-http", action="store_true", help=argparse.SUPPRESS)

    inspect = commands.add_parser("inspect")
    inspect.add_argument("appcast")

    latest = commands.add_parser("latest-build")
    latest.add_argument("appcast")

    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "write":
            xml = render(
                arguments.version, arguments.build, arguments.url, arguments.length,
                arguments.ed_signature, release_notes(arguments.notes),
                arguments.minimum_system_version, arguments.hardware, arguments.pub_date,
                arguments.allow_loopback_http,
            )
            ET.fromstring(xml.encode("utf-8"))  # The output must parse before anyone signs it.
            Path(arguments.output).write_text(xml, encoding="utf-8")
        elif arguments.command == "inspect":
            print(json.dumps(items(arguments.appcast), indent=2))
        else:
            build = latest_build(arguments.appcast)
            if build is not None:
                print(build)
    except (AppcastError, OSError) as error:
        print(f"appcast.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
