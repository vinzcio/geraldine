# Geraldine updates

Published Geraldine builds update themselves with [Sparkle](https://sparkle-project.org)
2.10.0, pinned exactly in `Package.swift`. The feed is
`https://geraldine.hemisthia.com/updates/appcast.xml` on skyward, the same
host layout Tendryls and Harken use for their updates.

## What a client does

- **Which builds update.** Only builds made for the production channel
  (`scripts/release/package-update.sh`) carry `SUFeedURL` and `SUPublicEDKey`.
  Every other build, including a plain `./build.sh`, has neither, never checks,
  and says so in Settings ▸ Updates.
- **When it checks.** At launch when the last check is more than an hour old,
  then every hour, and whenever someone chooses Check for Updates (Geraldine
  menu, ⌘K, or Settings ▸ Updates ▸ Check Now).
- **What it trusts.** The feed must carry a valid Sparkle signature
  (`SURequireSignedFeed`), and every archive's EdDSA signature is checked
  before extraction (`SUVerifyUpdateBeforeExtraction`), both against the
  public key inside the running app. Sparkle also requires the new app to be
  signed by the same Developer ID team, so TCC grants (Accessibility, Full Disk
  Access, Screen Recording) carry over.
- **Automatic installs (default).** An update downloads in the background.
  Geraldine restarts to install it only when its main window and menu bar panel
  are closed, Keep Awake is not paused for a locked screen, and neither surface
  was opened or closed in the last two minutes. Cleanup, uninstall, and scan
  work runs only inside the main window, and closing the window unmounts it, so
  a closed window means none of that work is in flight. While it waits, the
  sidebar, the menu bar panel, and Settings offer **Restart To Update**.
  Quitting Geraldine installs a waiting update too, without reopening it.
- **Manual installs.** With **Install Updates Automatically** off, a found
  update appears in the sidebar and menu bar panel; Sparkle's window shows the
  release notes and installs on request. A scheduled check never opens a window
  over someone's work (Sparkle's gentle reminders). With **Check For Updates
  Automatically** off, only manual checks run.
- **Keep Awake and Stay Active continue.** Right before an update restart,
  Geraldine writes a one-time record (`appUpdate.relaunchHandoff` in its
  preferences): the Keep Awake session's start and end, whether it was paused,
  and when Stay Active last pulsed. The next launch reads and deletes it, and
  uses it only on the same boot within ten minutes. The session resumes with
  its original end time; Stay Active resumes pulsing at once if nothing but its
  own pulse touched the idle clock during the restart, and otherwise waits its
  normal delay. An install that happens because someone quit Geraldine writes
  no record, so quitting still ends Keep Awake.
- **Network.** A check is one GET of `appcast.xml`; an update adds one archive
  download. Sparkle's User-Agent names Geraldine's and Sparkle's versions. No
  system profile is sent (`SUEnableSystemProfiling` is never set) and there are
  no identifiers. This is the only request Geraldine makes on its own.

## Publishing a release

The release Mac is the Mac mini. It holds the Developer ID identity
(`7C2D0C6BBB3E0FB2628245B94E258A227E9920B7`, team `4S9BMP9GU3`), the update key
file, and a `notarytool` keychain profile for the team (`harken-notary`).
Over SSH the login keychain is locked; run packaging in the GUI session (for
example as a one-shot `launchd` job in `gui/$(id -u)`, as for `build.sh`).

1. Merge to `main`. Raise `VERSION` in `build.sh` when the release deserves a
   new marketing version. The build number is the commit count of `HEAD`, so it
   grows with every merge.
2. Write the release notes in Markdown.
3. Package:

   ```bash
   NOTARY_PROFILE=harken-notary scripts/release/package-update.sh --notes notes.md
   ```

   This refuses a dirty tree, a commit that is not on `origin/main`, and a
   build that is not newer than the live feed. It builds the production
   channel, verifies every signature and the hardened runtime, notarizes and
   staples, archives with `ditto`, re-checks the app inside the archive (same
   CDHash, Gatekeeper accepts it), signs the archive, writes and signs
   `appcast.xml`, and records everything in `release.json`. The payload lands
   in `~/geraldine-releases/<version>-build<build>/` and is never overwritten.
4. Publish:

   ```bash
   scripts/release/publish-update.sh --payload ~/geraldine-releases/<version>-build<build>
   ```

   This re-verifies the payload against `release.json` and the shipped public
   key, refuses rehearsal or unnotarized payloads and builds that are not newer
   than the live feed, uploads the archive under its immutable name (an existing
   name with different bytes is refused), swaps `appcast.xml` atomically while
   keeping `appcast.previous.xml`, and downloads both public URLs to compare
   them byte for byte. Re-running it on a live payload only re-verifies.

Clients pick the release up within an hour, or at once with Check for Updates.

**Stopping a bad release.** Clients never install an older build, so a fix is
always a newer build. To stop a bad one from spreading until then:

```bash
ssh skyward 'cd /var/www/geraldine.hemisthia.com/updates && cp -p appcast.previous.xml appcast.xml'
```

**First install on each Mac.** A Mac running a build without the updater
(0.1.0 and earlier, or any local build) needs one manual install of a published
release: quit Geraldine, unzip the archive from the feed, replace
`/Applications/Geraldine.app`, open it, and turn Keep Awake and Stay Active back
on once. Every later release arrives on its own.

## Keys

- The public key is `PRODUCTION_SPARKLE_PUBLIC_KEY` in `build.sh`. Every
  published build carries it, and every future release must be signed by its
  private key.
- The private key exists only on the release Mac, at
  `~/Library/Application Support/Geraldine Release/sparkle-ed25519.key`
  (folder `0700`, file `0600`; override with `GERALDINE_SPARKLE_KEY_FILE`). It is
  Geraldine's own key, separate from Harken's and Tendryls'. **Back it up**
  with the signing identities: if it is lost, installed clients can never accept
  another update and each Mac needs a manual reinstall of a build with a new key.
- `swift scripts/release/sparkle-key.swift public-key <file>` prints the public
  key for a key file; `create` makes a new one and never overwrites.

## Update host

- DNS: `geraldine.hemisthia.com`, type A, `31.97.223.208`, DNS only (not
  proxied), like `tendryls.hemisthia.com`.
- `deploy/updates/setup-update-host.sh` reports what it would change;
  `--apply` installs `deploy/updates/geraldine-updates.conf` as an nginx site,
  issues a Let's Encrypt certificate through the shared `/var/www/certbot`
  webroot (renewed by `certbot.timer`, which reloads nginx), and creates
  `/var/www/geraldine.hemisthia.com/updates`. It backs up any replaced file under
  `/var/backups/geraldine-updates/` and restores it if `nginx -t` fails.
- The site serves only `appcast.xml` (never cached) and
  `Geraldine-<version>-<build>.zip` archives (cached for a year, immutable).
  Every other path, including the publisher's `.incoming` staging folder, is 404.

## Tests

- Swift: `AppUpdateModelTests` (configuration, install policy, handoff store,
  status text, lane folder) and `AppUpdateRelaunchKeepAwakeTests` (session
  resume, battery and lock policies, Stay Active continuity).
- Packaging and tooling: `python3 -B Tests/PackagingTests/test_update_packaging.py`
  and `python3 -B scripts/release/test_appcast.py`.
- Rehearsal: `scripts/release/package-update.sh --rehearsal --notes notes.md
  --output <owned scratch>/payload` runs the whole pipeline on the working tree
  without notarizing. Its payload says `"rehearsal": true` and can never be
  published.
- End to end: `scripts/release/e2e-update-test.sh --payload <payload> --work
  <empty owned folder> --sparkle-bin <SwiftPM scratch>/artifacts/sparkle/Sparkle/bin`.
  It copies the payload's app into an isolated lane (bundle ID
  `com.vincent.geraldine.updatetest`, Application Support folder named by the
  `GeraldineSupportFolderName` Info.plist key, loopback feed, throwaway key, no
  URL scheme, Stay Active off), runs copy A, turns Keep Awake on through A's own
  socket, and waits for A to install copy B by itself. It passes only if A
  restarts as B with the same Keep Awake end time, the handoff is consumed, and
  the installed Geraldine keeps its PID, Keep Awake, and Stay Active. It removes
  everything it created outside `--work`.

  2026-10-28 run on the Mac mini, from a rehearsal payload of this change:
  passed. A launched at 04:48:04Z, found, verified, and installed B by itself,
  and was running as B at 04:48:51Z with Keep Awake still ending at 06:48:06Z.
  The installed app (PID 96486) was unchanged.
