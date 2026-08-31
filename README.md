# Geraldine

Geraldine is native macOS 14+ local-only freeware for Mac care and small system utilities. It has no accounts, backend, or cross-device sync. Clipboard history remains removed. Preferences and other local state live in `UserDefaults` and Application Support on this Mac.

## Architecture

The app is a SwiftUI executable with feature surfaces under `Sources/Geraldine/Features`, AppKit integration for app and menu-bar behavior, and an `AppState` composition root that owns the monitoring and utility services. Shared visual behavior lives in the semantic `Theme`, `Components`, and `Motion` layers. The package also includes the small C `CThermal` target. `Package.swift` declares no third-party packages and links only Apple system frameworks.

## Source verification

The canonical source gate stages only `Package.swift`, `Sources`, and `Tests` outside OneDrive, runs the full suite, and performs a separate clean release compilation:

```bash
./verify.sh --owner <thread/session-id> --minimum-free-kib <explicitly-approved-positive-value>
```

The minimum-free-space value is operator-owned and mandatory; Geraldine supplies no default. For a focused test, use an owned scratch path outside OneDrive with the same pinned toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
/usr/bin/xcrun --sdk macosx swift test \
  --scratch-path <owned-path-outside-OneDrive> \
  --filter <test-name>
```

`build.sh` is packaging-oriented; it is not the source verifier.

## Evidence ladder

These proof levels are separate and must not be substituted for one another:

1. **Source proof** — `verify.sh` binds exact staged inputs, runs tests, and compiles a clean release. It does not produce or prove an app bundle.
2. **Packaged-bundle proof** — an explicitly authorized packaging run proves the resulting bundle and signature. It does not prove what is installed.
3. **Installed-path proof** — an explicitly authorized installation check proves `/Applications` provenance and correspondence. It does not prove runtime behavior.
4. **Live proof** — explicitly authorized interaction, performance, and accessibility checks prove the running app's behavior. They are not implied by source, package, or install success.

## Project records

- [`HANDOFF.md`](HANDOFF.md) lists only current invariants and genuinely open proof work.
- [`design-qa.md`](design-qa.md) is a historical visual-QA record with explicit evidence limits.
- [`plans/README.md`](plans/README.md) is the authoritative implementation and decision-spike index.
