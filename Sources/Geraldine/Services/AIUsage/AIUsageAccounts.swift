import Foundation

/// A logged-in agent CLI home that gets its own usage tile.
struct AIUsageAccount: Equatable, Identifiable, Sendable {
    var identity: AIUsageIdentity
    /// Tells this login apart from its siblings. Shown only when the provider
    /// has more than one account.
    var name: String
    var id: String { identity.id }
}

/// Lists logins from folder names and Claude's profile file. It never opens a
/// credential: a Codex sibling counts when its `auth.json` exists, and the CLI
/// decides whether that login still works. The result is cached by
/// `AIUsageMonitor`, so views never touch the disk.
enum AIUsageAccountDiscovery {
    /// Every provider's default login, each followed by its sibling logins.
    static func accounts(userHome: URL) -> [AIUsageAccount] {
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: userHome.path)) ?? []).sorted()
        var accounts: [AIUsageAccount] = []
        for provider in AICodingProvider.allCases {
            let siblings = siblingKeys(for: provider, folders: folders, userHome: userHome).map { key in
                let identity = AIUsageIdentity(provider, accountKey: key)
                return AIUsageAccount(identity: identity, name: identity.folderName ?? key)
            }
            var name = defaultName(for: provider, userHome: userHome)
            if siblings.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                name = "Default"
            }
            accounts.append(AIUsageAccount(identity: AIUsageIdentity(provider), name: name))
            accounts.append(contentsOf: siblings)
        }
        return accounts
    }

    /// A Team or Enterprise login is named for its organization. Otherwise the
    /// default login is the personal one its named siblings sit beside.
    private static func defaultName(for provider: AICodingProvider, userHome: URL) -> String {
        if provider == .claude, let organization = ClaudeProfile.read(in: userHome)?.teamOrganization {
            return organization
        }
        return "Personal"
    }

    /// Folders created for a second login: `.claude-<name>` holding a signed-in
    /// profile, `.codex-<name>` holding an `auth.json`.
    private static func siblingKeys(for provider: AICodingProvider, folders: [String], userHome: URL) -> [String] {
        let prefix: String
        switch provider {
        case .claude: prefix = ".claude-"
        case .codex:  prefix = ".codex-"
        case .antigravity, .grok, .cursor: return []
        }
        return folders.compactMap { folder in
            guard folder.hasPrefix(prefix), folder.count > prefix.count else { return nil }
            let directory = userHome.appendingPathComponent(folder, isDirectory: true)
            let signedIn = provider == .claude
                ? ClaudeProfile.read(in: directory) != nil
                : FileManager.default.fileExists(atPath: directory.appendingPathComponent("auth.json").path)
            return signedIn ? String(folder.dropFirst(prefix.count)) : nil
        }
    }
}
