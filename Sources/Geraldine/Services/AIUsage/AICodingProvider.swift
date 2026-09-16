import AppKit
import SwiftUI

/// Coding assistants whose remaining usage can appear as popover widgets.
/// Geraldine never hosts accounts of its own: each provider is connected by
/// reading the local sign-in the official app or CLI already keeps on this Mac.
enum AICodingProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case antigravity
    case claude
    case codex
    case grok
    case cursor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .grok:        return "Grok"
        case .cursor:      return "Cursor"
        }
    }

    var widgetID: String { "ai.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .antigravity: return "sparkle"
        case .claude:      return "bubble.left.and.bubble.right.fill"
        case .codex:       return "chevron.left.forwardslash.chevron.right"
        case .grok:        return "bolt.fill"
        case .cursor:      return "cursorarrow"
        }
    }

    var tint: Color {
        switch self {
        case .antigravity: return Theme.Chart.blue
        case .claude:      return Theme.Chart.orange
        case .codex:       return Theme.Chart.green
        case .grok:        return Theme.Chart.silver
        case .cursor:      return Theme.Chart.purple
        }
    }

    var usageUnavailableHint: String {
        switch self {
        case .antigravity: return "Usage unavailable. Open Antigravity to read its local quota, then refresh."
        case .claude:      return "Usage unavailable. Run /usage in Claude Code, then refresh."
        case .codex:       return "Usage unavailable. Refresh usage in Codex, then retry."
        case .grok:        return "Usage unavailable. Refresh usage in the Grok CLI, then retry."
        case .cursor:      return "Usage unavailable. Refresh usage in Cursor, then retry."
        }
    }

    var applicationNames: [String] {
        switch self {
        case .antigravity: return ["Antigravity"]
        case .claude:      return ["Claude"]
        case .codex:       return ["Codex", "ChatGPT"]
        case .grok:        return ["Grok"]
        case .cursor:      return ["Cursor"]
        }
    }

    /// Dock icon for the official app when it is installed on this Mac.
    var appIcon: NSImage? {
        for name in applicationNames {
            let url = URL(fileURLWithPath: "/Applications/\(name).app")
            if let icon = AppIcons.forFile(at: url) { return icon }
        }
        return nil
    }

    var fallbackURL: URL {
        switch self {
        case .antigravity: return URL(string: "https://antigravity.google")!
        case .claude:      return URL(string: "https://claude.ai/code")!
        case .codex:       return URL(string: "https://chatgpt.com/codex")!
        case .grok:        return URL(string: "https://grok.com")!
        case .cursor:      return URL(string: "https://cursor.com")!
        }
    }

    static func from(widgetID: String) -> AICodingProvider? {
        guard widgetID.hasPrefix("ai.") else { return nil }
        return AICodingProvider(rawValue: String(widgetID.dropFirst(3)))
    }
}

struct AIUsageDisclosure: Equatable, Sendable {
    static let current = AIUsageDisclosure()

    var destinations: [String] {
        ["Antigravity", "Claude", "Codex", "Grok", "Cursor"]
    }

    var text: String {
        "For Antigravity, Claude, Codex, Grok, and Cursor, reads existing usage or reuses the local sign-in from the official app or CLI to request remaining usage directly from its provider. No separate Geraldine sign-in or Keychain access. Show or hide usage tiles below."
    }
}
