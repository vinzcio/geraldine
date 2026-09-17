import Foundation

/// One quota window from a provider (5-hour, weekly, included pool, a model).
struct AIUsageWindow: Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    /// 0...100 used.
    var usedPercent: Double
    var resetsAt: Date?
    var durationSeconds: TimeInterval? = nil

    var remainingPercent: Double {
        AIUsageMath.clampPercent(100 - usedPercent)
    }
}

enum AIUsageStatus: Equatable, Sendable {
    case disconnected
    case needsSignIn
    case loading
    case ready
    case error(String)

    var isConnected: Bool {
        switch self {
        case .disconnected: return false
        default: return true
        }
    }
}

struct AIUsageSnapshot: Equatable, Sendable {
    var provider: AICodingProvider
    var status: AIUsageStatus
    var plan: String?
    var windows: [AIUsageWindow]
    var fetchedAt: Date?
    var sourceLabel: String?

    var cachedSourceDescription: String? {
        guard sourceLabel == ClaudeUsageCache.sourceLabel, let fetchedAt else { return nil }
        return "Claude Code cache · updated " + fetchedAt.formatted(date: .abbreviated, time: .shortened)
    }

    static func disconnected(_ provider: AICodingProvider) -> AIUsageSnapshot {
        AIUsageSnapshot(provider: provider, status: .disconnected, plan: nil,
                        windows: [], fetchedAt: nil, sourceLabel: nil)
    }

    static func needsSignIn(_ provider: AICodingProvider) -> AIUsageSnapshot {
        AIUsageSnapshot(provider: provider, status: .needsSignIn, plan: nil,
                        windows: [], fetchedAt: nil, sourceLabel: nil)
    }

    static func loading(_ provider: AICodingProvider, preserving previous: AIUsageSnapshot? = nil) -> AIUsageSnapshot {
        AIUsageSnapshot(
            provider: provider,
            status: .loading,
            plan: previous?.plan,
            windows: previous?.windows ?? [],
            fetchedAt: previous?.fetchedAt,
            sourceLabel: previous?.sourceLabel
        )
    }

    static func failed(_ provider: AICodingProvider, message: String,
                       preserving previous: AIUsageSnapshot? = nil) -> AIUsageSnapshot {
        AIUsageSnapshot(
            provider: provider,
            status: .error(message),
            plan: previous?.plan,
            windows: previous?.windows ?? [],
            fetchedAt: previous?.fetchedAt,
            sourceLabel: previous?.sourceLabel
        )
    }

    /// Display actual quota windows. Claude includes weekly scopes and its
    /// five-hour window; Codex Plus splits supplied windows. Other Codex plans
    /// and Grok stay pooled. Weekly precedes five-hour, matching Antigravity.
    var displayWindows: [AIUsageWindow] {
        switch provider {
        case .codex:
            let standard = windows.filter { $0.id == "primary" || $0.id == "secondary" }
            if plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "plus",
               standard.contains(where: { $0.durationSeconds == 5 * 60 * 60 }) {
                return standard.sorted { ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0) }
            }
            if let tightest = windows.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                return [tightest]
            }
            return Array(windows.prefix(1))
        case .grok:
            if let pool = windows.first(where: { $0.id == "pool" }) { return [pool] }
            return Array(windows.prefix(1))
        case .cursor:
            // Dashboard and CLI both meter two included pools: Cursor models
            // (Auto/Composer) and Other models (API). totalPercentUsed is only
            // a rollup of those two, not a third limit.
            let cursorModels = windows.first { $0.id == "autoPercentUsed" }
            let otherModels = windows.first { $0.id == "apiPercentUsed" }
            let pair = [cursorModels, otherModels].compactMap { $0 }
            return pair.isEmpty ? Array(windows.prefix(2)) : pair
        case .claude:
            let allModels = windows.first { $0.id == "seven_day" }
            let fable = windows.first { window in
                window.id == "seven_day_overage_included"
                    || window.id.lowercased().contains("fable")
                    || window.title.lowercased().contains("fable")
            }
            var shown: [AIUsageWindow] = []
            if let allModels { shown.append(allModels) }
            if let fable { shown.append(fable) }
            if let fiveHour = windows.first(where: { $0.id == "five_hour" }) {
                shown.append(fiveHour)
            }
            return shown.isEmpty ? Array(windows.prefix(1)) : shown
        case .antigravity:
            return windows
        }
    }

    /// Tightest remaining window among the bars we draw.
    var headline: AIUsageWindow? {
        let visible = displayWindows
        let source = visible.isEmpty ? windows : visible
        return source.min { lhs, rhs in
            if lhs.remainingPercent == rhs.remainingPercent {
                return lhs.title < rhs.title
            }
            return lhs.remainingPercent < rhs.remainingPercent
        }
    }

    var remainingPercent: Double? { headline?.remainingPercent }

    /// Ready tiles, and tiles that already have bars from a previous fetch,
    /// can keep showing numbers while a shared refresh runs.
    var hasDisplayableUsage: Bool {
        status == .ready || !windows.isEmpty
    }
}

struct AIUsageParseError: Error, Equatable {
    var message: String
}

enum AIUsageMath {
    static func clampPercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(100, max(0, value))
    }

    /// Values in 0...1 are treated as fractions; larger values are already percent.
    static func percent(from raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        let converted = (raw >= 0 && raw <= 1) ? raw * 100 : raw
        return clampPercent((converted * 100).rounded() / 100)
    }
}
