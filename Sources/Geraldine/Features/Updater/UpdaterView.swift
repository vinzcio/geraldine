import SwiftUI

struct UpdaterView: View {
    @StateObject private var vm = UpdaterViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .updater) {
                if vm.hasBrew {
                    Button { vm.load() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                }
            }

            if vm.loading {
                ScanningState(tint: Module.updater.tint, icon: "shippingbox",
                              label: "Checking for updates…")
            } else {
                content
            }
        }
        .onAppear { if !vm.checked { vm.load() } }
    }

    @ViewBuilder private var content: some View {
        switch vm.checkState {
        case .unchecked:
            EmptyState(icon: "shippingbox",
                       title: "Check For Updates",
                       message: "Geraldine checks Homebrew-managed apps and reports the exact brew result.",
                       tint: Module.updater.tint)
        case .unavailable(let checkedAt):
            noBrew(checkedAt: checkedAt)
        case .failed(let message, let output, let checkedAt):
            BrewFailureState(title: "Homebrew Check Failed",
                             message: message,
                             output: output,
                             checkedAt: checkedAt,
                             retry: vm.load)
        case .noUpdates(let checkedAt):
            VStack(spacing: 12) {
                EmptyState(icon: "checkmark.seal.fill", title: "Everything's Up To Date",
                           message: "None of your Homebrew-managed apps have updates right now.",
                           tint: Theme.good)
                    .frame(maxHeight: 280)
                Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Button { vm.load() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(.soft(Module.updater.tint))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .updatesAvailable(let checkedAt):
            if vm.outdated.isEmpty {
                EmptyState(icon: "checkmark.seal.fill",
                           title: "Everything's Up To Date",
                           message: "All updates from the last check have been applied.",
                           tint: Theme.good)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ForEach(vm.outdated) { app in
                            UpdateRow(app: app,
                                      busy: vm.upgrading.contains(app.token),
                                      feedback: vm.upgradeFeedback[app.token]) {
                                vm.upgrade(app)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func noBrew(checkedAt: Date) -> some View {
        VStack(spacing: 16) {
            Spacer()
            IconBadge(icon: "shippingbox", tint: Module.updater.tint, size: 92)
            Text("Connect Homebrew").font(.rounded(20, .semibold))
            Text("Geraldine could not find the brew command. Install Homebrew once and update detection turns on automatically.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { vm.copyInstallCommand() } label: {
                    Label("Copy Install Command", systemImage: "doc.on.doc")
                }
                Button { vm.load() } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.soft(Module.updater.tint))
            .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UpdateRow: View {
    let app: OutdatedApp
    let busy: Bool
    let feedback: BrewCommandFeedback?
    let upgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Module.updater.tint.opacity(0.16)).frame(width: 40, height: 40)
                    Image(systemName: "arrow.up.app.fill").foregroundStyle(Module.updater.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.rounded(15, .semibold))
                    HStack(spacing: 6) {
                        Text(app.current).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(app.latest).foregroundStyle(Theme.good)
                    }
                    .font(.caption.monospacedDigit())
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Update", action: upgrade).buttonStyle(.borderedProminent).tint(Module.updater.tint)
                }
            }

            if let feedback, !feedback.ok {
                BrewOutputBlock(message: feedback.message,
                                output: feedback.output,
                                checkedAt: feedback.checkedAt)
            }
        }
        .card(padding: 14)
    }
}

private struct BrewFailureState: View {
    var title: String
    var message: String
    var output: String
    var checkedAt: Date
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            EmptyState(icon: "exclamationmark.triangle.fill",
                       title: title,
                       message: message,
                       tint: Theme.warn)
                .frame(maxHeight: 240)
            BrewOutputBlock(message: "Checked \(checkedAt.formatted(date: .omitted, time: .shortened))",
                            output: output,
                            checkedAt: checkedAt)
                .frame(maxWidth: 520)
            Button(action: retry) { Label("Check Again", systemImage: "arrow.clockwise") }
                .buttonStyle(.soft(Theme.warn))
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrewOutputBlock: View {
    var message: String
    var output: String
    var checkedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message).font(.caption.weight(.medium))
                Spacer()
                Text(checkedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(output.isEmpty ? "Command failed without output." : output)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(10)
        .background(Theme.warn.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
