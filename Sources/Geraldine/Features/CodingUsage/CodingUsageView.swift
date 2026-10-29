import SwiftUI

struct CodingUsageView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var usage: AIUsageMonitor
    @State private var query = ""
    @State private var showHistory = false
    private var history: AIUsageHistoryMonitor { state.usageHistory }

    private var accounts: [AIUsageAccount] {
        usage.accounts.filter { account in
            let text = [usage.displayName(for: account.identity), account.name,
                        usage.snapshot(for: account.identity).accountEmail ?? ""].joined(separator: " ")
            return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || text.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var body: some View {
        ModulePage(module: .codingUsage, headerStyle: .data, widthRole: .readable) {
            Button {
                if showHistory {
                    history.refreshPrices()
                    for account in accounts { history.refresh(account.identity) }
                } else { usage.refreshConnected() }
            } label: {
                Label("Refresh Usage", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.quiet(Module.codingUsage.tint))
            .disabled(!showHistory && !usage.accounts.contains { usage.isConnected($0.identity) })
        } content: {
            Picker("Usage measurement", selection: $showHistory) {
                Text("Allowances").tag(false)
                Text("Tokens & Cost").tag(true)
            }.pickerStyle(.segmented)
            if !showHistory {
                Text("Allowances are reported separately by each provider. Percentages from different plans and windows are not a combined balance.")
                .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Find an account or provider", text: $query)
                .textFieldStyle(.roundedBorder)
            if showHistory {
                CodingUsageHistoryView(history: history, accounts: accounts, title: { usage.displayName(for: $0) })
            } else {
                ForEach(accounts) { account in
                    CodingUsageAccountCard(
                        title: usage.displayName(for: account.identity),
                        snapshot: usage.snapshot(for: account.identity),
                        isRefreshing: usage.isRefreshing(account.identity),
                        refresh: { usage.connect(account.identity) },
                        show: { state.connectAIUsage(account.identity) }
                    )
                }
            }
            if accounts.isEmpty {
                Text("No accounts match your search.").foregroundStyle(.secondary)
            }
            if !showHistory {
                Text("Allowances use existing official CLI sign-ins. Showing allowances also enables a menu-bar tile. OpenCode, Pi, and Muse currently provide token history only; use Tokens & Cost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Coding Usage Settings") { state.selection = .settings }
                .buttonStyle(.quiet(Module.codingUsage.tint))
        }
        .onAppear { usage.refreshIfStale() }
    }
}

/// A pure presentation surface so ready, cached, unavailable, and hidden states
/// can be rendered without accessing real accounts or starting a CLI.
struct CodingUsageAccountCard: View {
    let title: String
    let snapshot: AIUsageSnapshot
    let isRefreshing: Bool
    let refresh: () -> Void
    let show: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "terminal").foregroundStyle(snapshot.provider.tint)
                    .font(.title2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if let plan = snapshot.plan { Text(plan).font(.caption).foregroundStyle(.secondary) }
                    if let email = snapshot.accountEmail {
                        Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                if snapshot.status == .disconnected {
                    Button("Show Usage", action: show).buttonStyle(.quiet(snapshot.provider.tint))
                } else {
                    Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(.quiet(snapshot.provider.tint))
                        .disabled(isRefreshing || snapshot.status == .loading)
                }
            }
            if let status = statusText {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(snapshot.windows) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).font(.callout.weight(.medium))
                        Spacer()
                        Text(String(format: "%.0f%% remaining", window.remainingPercent))
                            .font(.callout.monospacedDigit())
                    }
                    ProgressView(value: window.remainingPercent, total: 100)
                        .tint(snapshot.provider.tint)
                        .accessibilityLabel("\(window.title), remaining allowance")
                    Text(resetDescription(window)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if snapshot.status == .ready && snapshot.windows.isEmpty {
                Text("The provider returned no allowance windows.").font(.callout).foregroundStyle(.secondary)
            }
            if let fetchedAt = snapshot.fetchedAt {
                TimelineView(.everyMinute) { context in
                    Text(UsageAge.text(fetchedAt, now: context.date))
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Last successful update: \(fetchedAt.formatted(date: .abbreviated, time: .standard))")
                }
            }
            if let source = snapshot.sourceLabel {
                Text(source).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .card(tier: .base)
    }

    private var statusText: String? {
        switch snapshot.status {
        case .disconnected: "Usage is hidden. No usage is requested for this account."
        case .loading: snapshot.windows.isEmpty ? "No usage yet. Checking in the background…" : "Updating usage; showing the last successful values."
        case .needsSignIn: snapshot.provider.usageUnavailableHint
        case .error(let message): snapshot.windows.isEmpty ? message : "Couldn't refresh. Showing the last known usage."
        case .ready: nil
        }
    }

    private func resetDescription(_ window: AIUsageWindow) -> String {
        guard let reset = window.resetsAt else { return "Reset time unavailable" }
        let absolute = AIUsageResetText.absolute(reset, dateOnly: window.resetIsDateOnly)
        guard !absolute.isEmpty else { return "Reset time unavailable" }
        return window.resetIsDateOnly ? "Reset date: \(absolute)" : "Reset: \(absolute)"
    }
}
