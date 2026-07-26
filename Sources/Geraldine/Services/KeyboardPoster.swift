import CoreGraphics

/// Synthesizes a key press at the HID event tap.
///
/// Requires Accessibility permission; callers are responsible for checking it,
/// because the useful failure message differs per feature.
enum KeyboardPoster {
    static func post(keyCode: Int64, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
