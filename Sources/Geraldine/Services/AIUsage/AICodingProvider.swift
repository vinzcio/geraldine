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

    var signInHint: String {
        switch self {
        case .antigravity: return "Sign in with the Antigravity app or the agy CLI on this Mac."
        case .claude:      return "Sign in with Claude Code (`claude`) on this Mac."
        case .codex:       return "Sign in with the Codex CLI (`codex`) on this Mac."
        case .grok:        return "Sign in with the Grok CLI (`grok`) on this Mac."
        case .cursor:      return "Sign in to the Cursor app or `cursor-agent` on this Mac."
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
        "Reads local sign-in state for Antigravity, Claude, Codex, Grok, and Cursor, then asks each provider for remaining usage. Tokens stay on this Mac and are never sent to Geraldine."
    }
}
