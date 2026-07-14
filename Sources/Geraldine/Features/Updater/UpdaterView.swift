import AppKit
import SwiftUI

struct UpdaterView: View {
    @StateObject private var vm = UpdaterViewModel()
    @State private var copiedInstallCommand = false

    var body: some View {
        ModulePage(
            module: .updater,
            headerStyle: .utility,
            widthRole: .readable,
            trailing: { checkControl }
        ) {
            WorkflowPhaseHost(phase: vm.displayPhase) {
                phaseContent
            }
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .top)
        }
        .onAppear { if !vm.checked { vm.load() } }
    }

    private var checkControl: some View {
        StatefulActionButton(
            state: vm.loading ? .working : .idle,
            idleTitle: vm.checked ? "Check Again" : "Check",
            workingTitle: "Checking",
            idleIcon: "arrow.clockwise",
            tint: Module.updater.tint,
            action: vm.load
        )
    }

    @ViewBuilder private var phaseContent: some View {
        switch vm.displayPhase {
        case .checking:
            checkingState
        case .unchecked:
            uncheckedState
        case .unavailable:
            noBrew(checkedAt: vm.checkedAt ?? Date())
        case .failed:
            if case .failed(let message, let output, let checkedAt) = vm.checkState {
                BrewFailureState(
                    title: "Homebrew Check Failed",
                    message: message,
                    output: output,
                    checkedAt: checkedAt,
                    retry: vm.load
                )
            }
        case .noUpdates:
            noUpdatesState
        case .updatesAvailable:
            updatesState
        }
    }

    private var checkingState: some View {
        VStack(spacing: Theme.Spacing.md) {
            WorkflowMark(state: .working, tint: Module.updater.tint, idleIcon: "shippingbox", size: 82)
            Text("Checking Homebrew Apps")
                .font(.geraldineSection)
            Text("Geraldine is comparing installed versions with the current cask catalog.")
                .font(.geraldineBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .card(tier: .tinted(Module.updater.tint))
    }

    private var uncheckedState: some View {
        VStack(spacing: Theme.Spacing.md) {
            WorkflowMark(state: .idle, tint: Module.updater.tint, idleIcon: "shippingbox", size: 82)
            Text("Check For Updates").font(.geraldineSection)
            Text("Geraldine checks Homebrew-managed apps and reports the exact brew result.")
                .font(.geraldineBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Check Now", icon: "arrow.clockwise", action: vm.load)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .card()
    }

    private var noUpdatesState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                WorkflowMark(state: .success, tint: Module.updater.tint, idleIcon: "shippingbox", size: 76)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Everything's Up To Date").font(.geraldineSection)
                    Text(vm.completed.isEmpty
                         ? "None of your Homebrew-managed apps have updates right now."
                         : completedSummary)
                        .font(.geraldineBody)
                        .foregroundStyle(.secondary)
                    if let checkedAt = vm.checkedAt {
                        Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .outcomeWash(.success)
            .card(tier: .tinted(Theme.good))

            if !vm.completed.isEmpty {
                SectionHeader("Completed This Check", subtitle: "Installed versions now match Homebrew.")
                ForEach(vm.completed) { app in
                    UpdateRow(app: app,
                              busy: false,
                              feedback: vm.upgradeFeedback[app.token],
                              completed: true,
                              upgrade: {})
                }
            }
        }
    }

    private var completedSummary: String {
        let count = vm.completed.count
        return "Updated \(count) app\(count == 1 ? "" : "s") successfully."
    }

    private var updatesState: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let checkedAt = vm.checkedAt {
                HStack {
                    Label("\(vm.outdated.count) Update\(vm.outdated.count == 1 ? "" : "s") Ready",
                          systemImage: "arrow.down.app.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Module.updater.tint)
                    Spacer()
                    Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !vm.completed.isEmpty {
                SectionHeader("Completed This Check")
                ForEach(vm.completed) { app in
                    UpdateRow(app: app,
                              busy: false,
                              feedback: vm.upgradeFeedback[app.token],
                              completed: true,
                              upgrade: {})
                }
                Divider().opacity(0.45)
            }

            SectionHeader("Ready To Update", subtitle: "Each app updates independently through Homebrew.")
            ForEach(vm.outdated) { app in
                UpdateRow(
                    app: app,
                    busy: vm.upgrading.contains(app.token),
                    feedback: vm.upgradeFeedback[app.token],
                    completed: false
                ) {
                    vm.upgrade(app)
                }
            }
        }
        .geraldineAnimation(.standard,
                            value: vm.completed.map(\.id) + vm.outdated.map(\.id))
    }

    private func noBrew(checkedAt: Date) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            WorkflowMark(state: .warning, tint: Module.updater.tint, idleIcon: "shippingbox", size: 82)
            Text("Connect Homebrew").font(.geraldineSection)
            Text("Geraldine could not find the brew command. Install Homebrew once and update detection turns on automatically.")
                .font(.geraldineBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    vm.copyInstallCommand()
                    copiedInstallCommand = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        copiedInstallCommand = false
                    }
                } label: {
                    Label(copiedInstallCommand ? "Copied" : "Copy Install Command",
                          systemImage: copiedInstallCommand ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.soft(Module.updater.tint))

                Button { vm.load() } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.soft(Module.updater.tint))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .card(tier: .tinted(Theme.warn))
    }
}

private struct UpdateRow: View {
    let app: OutdatedApp
    let busy: Bool
    let feedback: BrewCommandFeedback?
    let completed: Bool
    let upgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                UpdateAppIdentity(app: app)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.rounded(15, .semibold))
                    versionLine
                }

                Spacer(minLength: Theme.Spacing.md)

                actionControl
                    .frame(width: 132, alignment: .trailing)
            }

            if let feedback, !feedback.ok {
                BrewOutputBlock(message: feedback.message,
                                output: feedback.output,
                                checkedAt: feedback.checkedAt)
            }
        }
        .interactiveCard(padding: Theme.Spacing.md,
                         tier: resolvedCardTier)
        .geraldineAnimation(.standard, value: feedback?.checkedAt)
    }

    @ViewBuilder private var versionLine: some View {
        if completed {
            HStack(spacing: 6) {
                ContextualSymbol(inactive: "arrow.right", active: "checkmark",
                                 isActive: true, tint: Theme.good, size: 11)
                Text(app.latest)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.good)
                Text("installed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· was \(app.current)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } else {
            HStack(spacing: 6) {
                Text(app.current).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(app.latest).foregroundStyle(Theme.good)
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder private var actionControl: some View {
        if completed {
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.good)
                .frame(minWidth: 96, minHeight: Theme.Layout.minimumHitArea)
        } else {
            StatefulActionButton(
                state: actionState,
                idleTitle: "Update",
                workingTitle: "Updating",
                failureTitle: "Retry",
                idleIcon: "arrow.down.app.fill",
                tint: Module.updater.tint,
                action: upgrade
            )
        }
    }

    private var actionState: StatefulActionState {
        if busy { return .working }
        if feedback?.ok == false { return .failure }
        return .idle
    }

    private var resolvedCardTier: CardTier {
        if completed { return .tinted(Theme.good) }
        if feedback?.ok == false { return .tinted(Theme.bad) }
        if busy { return .tinted(Module.updater.tint) }
        return .raised
    }
}

private struct UpdateAppIdentity: View {
    let app: OutdatedApp

    var body: some View {
        if let url = app.applicationURL {
            AppIconPlate(size: 42) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
            .accessibilityHidden(true)
        } else {
            ModuleGlyph(systemImage: "arrow.up.app.fill", tint: Module.updater.tint, size: 42)
        }
    }
}

private struct BrewFailureState: View {
    var title: String
    var message: String
    var output: String
    var checkedAt: Date
    var retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            WorkflowMark(state: .failure, tint: Module.updater.tint,
                         idleIcon: "shippingbox", size: 82)
            Text(title).font(.geraldineSection)
            Text(message)
                .font(.geraldineBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            BrewOutputBlock(message: "Checked \(checkedAt.formatted(date: .omitted, time: .shortened))",
                            output: output,
                            checkedAt: checkedAt)
                .frame(maxWidth: 560)
            StatefulActionButton(state: .failure,
                                 idleTitle: "Check Again",
                                 failureTitle: "Check Again",
                                 idleIcon: "arrow.clockwise",
                                 tint: Theme.warn,
                                 action: retry)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .outcomeWash(.failure)
        .card(tier: .tinted(Theme.bad))
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
        .padding(Theme.Spacing.sm)
        .background(Theme.bad.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
