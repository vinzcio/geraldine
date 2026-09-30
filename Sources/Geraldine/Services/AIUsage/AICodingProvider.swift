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
        case .antigravity: return "Usage unavailable. Run /usage in the Antigravity CLI (agy), then refresh."
        case .claude:      return "Usage unavailable. Run /usage in Claude Code, then refresh."
        case .codex:       return "Usage unavailable. Run /usage in the Codex CLI, then refresh."
        case .grok:        return "Usage unavailable. Run /usage in the Grok CLI, then refresh."
        case .cursor:      return "Usage unavailable. Run /usage in the Cursor Agent CLI, then refresh."
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
}

/// One remaining-usage watcher. Every provider has its default login. Claude and
/// Codex add one per sibling config folder: `~/.claude-<name>` runs with
/// `CLAUDE_CONFIG_DIR`, `~/.codex-<name>` with `CODEX_HOME`.
struct AIUsageIdentity: Hashable, Codable, Identifiable, Sendable {
    var provider: AICodingProvider
    /// Empty for the default login. A sibling uses its folder suffix (`work`, `fasaj`).
    var accountKey: String

    init(_ provider: AICodingProvider, accountKey: String = "") {
        self.provider = provider
        self.accountKey = accountKey
    }

    var id: String {
        accountKey.isEmpty ? provider.rawValue : "\(provider.rawValue).\(accountKey)"
    }

    var widgetID: String { "ai.\(id)" }

    /// The sibling folder suffix as a name: `.codex-work` → "Work". Nil for the default login.
    var folderName: String? {
        guard !accountKey.isEmpty else { return nil }
        return accountKey.replacingOccurrences(of: "-", with: " ").localizedCapitalized
    }

    static func from(widgetID: String) -> AIUsageIdentity? {
        guard widgetID.hasPrefix("ai.") else { return nil }
        let rest = String(widgetID.dropFirst(3))
        if let provider = AICodingProvider(rawValue: rest) {
            return AIUsageIdentity(provider)
        }
        guard let separator = rest.firstIndex(of: ".") else { return nil }
        let key = String(rest[rest.index(after: separator)...])
        guard let provider = AICodingProvider(rawValue: String(rest[..<separator])), !key.isEmpty else { return nil }
        return AIUsageIdentity(provider, accountKey: key)
    }
}

struct AIUsageDisclosure: Equatable, Sendable {
    static let current = AIUsageDisclosure()

    var destinations: [String] {
        ["Antigravity", "Claude", "Codex", "Grok", "Cursor"]
    }

    var text: String {
        "For Antigravity, Claude, Codex, Grok, and Cursor, runs each official CLI with the local sign-in already on this Mac; the CLI asks its provider for remaining usage. No separate Geraldine sign-in or Keychain access. Show or hide usage tiles below."
    }
}
