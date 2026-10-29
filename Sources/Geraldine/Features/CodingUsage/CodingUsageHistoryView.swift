import SwiftUI
import AppKit

struct CodingUsageHistoryView: View {
    @ObservedObject var history: AIUsageHistoryMonitor
    let accounts: [AIUsageAccount]
    let title: (AIUsageIdentity) -> String

    var body: some View {
        Text("All available history. Cost is reported usage value or an API-equivalent estimate, not your subscription bill. Unknown prices remain unpriced. Allowances are tracked separately.")
            .font(.callout).foregroundStyle(.secondary)
        if let notice = history.pricingNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        ForEach(accounts) { account in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title(account.identity)).font(.headline)
                    Spacer()
                    Button(history.reading.contains(account.identity) ? "Reading…" : "Read history") { history.refresh(account.identity) }
                        .disabled(history.reading.contains(account.identity))
                }
                if let error = history.errors[account.identity] { Text(error).font(.callout).foregroundStyle(.secondary) }
                if let summary = history.summaries[account.identity] {
                    if let notice = summary.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                    if !summary.models.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 24) {
                            VStack(alignment: .leading) {
                                Text(summary.tokens.total.formatted(.number.precision(.fractionLength(0)))).font(.title2.monospacedDigit())
                                Text("Tokens").font(.caption).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading) {
                                Text(cost(summary.cost, unpriced: summary.unpricedRecords)).font(.title2.monospacedDigit())
                                Text(summary.unpricedRecords > 0 ? "Priced portion · \(summary.unpricedRecords) unpriced records" : "Usage value (USD)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                            GridRow {
                                Text("Model"); Text("Input"); Text("Cache read"); Text("Cache write"); Text("Output"); Text("USD")
                            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(summary.models) { model in
                                GridRow {
                                    Text(model.model).lineLimit(2).frame(maxWidth: 160, alignment: .leading).help(model.model)
                                    number(model.tokens.input); number(model.tokens.cacheRead)
                                    number(model.tokens.cacheWrite); number(model.tokens.output)
                                    Text(cost(model.cost, unpriced: model.unpricedRecords))
                                        .help("\(model.reportedRecords) provider-reported, \(model.estimatedRecords) estimated, \(model.unpricedRecords) unpriced records")
                                }.font(.caption.monospacedDigit())
                            }
                        }
                        .textSelection(.enabled)
                        if let first = summary.firstDate, let last = summary.lastDate {
                            Text("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if summary.notice == nil {
                        Text("No recorded token usage in the available history.").foregroundStyle(.secondary)
                    }
                    TimelineView(.everyMinute) { context in
                        Text("\(summary.source) · \(UsageAge.text(summary.updatedAt, now: context.date))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No history yet. Checking in the background…").font(.callout).foregroundStyle(.secondary)
                }
                if account.identity.provider != .cursor {
                    Button("Choose history folder…") { chooseFolder(account.identity) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .disabled(history.reading.contains(account.identity))
                }
            }.card(tier: .base)
                .onAppear { history.refreshIfStale([account.identity]) }
        }
        Text("Prices: LiteLLM public model catalog. Reasoning tokens are included in output. Cursor history covers the account across machines; other providers use local history.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func number(_ value: Double) -> some View { Text(value.formatted(.number.notation(.compactName))) }
    private func cost(_ value: Double, unpriced: Int) -> String {
        if unpriced > 0 && value == 0 { return "Unpriced" }
        return (unpriced > 0 ? "≥ " : "") + value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
    private func chooseFolder(_ identity: AIUsageIdentity) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose \(identity.provider.title)’s history folder. It will be read only for this scan."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            history.refresh(identity, directory: url)
        }
    }
}
