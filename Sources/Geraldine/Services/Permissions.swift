import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    /// Best-effort Full Disk Access check: try directly opening a TCC-protected location.
    static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Safari/History.db"),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Mail")
        ]
        let fm = FileManager.default

        var foundProbe = false
        for p in probes {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: p.path, isDirectory: &isDirectory) else { continue }
            foundProbe = true

            if isDirectory.boolValue {
                if (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) != nil {
                    return true
                }
            } else if let handle = try? FileHandle(forReadingFrom: p) {
                try? handle.close()
                return true
            }
        }

        // If none of the probes exist we can't tell; avoid nagging on unusual setups.
        return !foundProbe
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    static func hasAccessibilityAccess() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
