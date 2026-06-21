import SwiftUI

struct UpdaterView: View {
    @StateObject private var vm = UpdaterViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .updater) {
                if vm.hasBrew {
                    Button { vm.load() } label: { Label("Check again", systemImage: "arrow.clockwise") }
                }
            }

            if vm.loading {
                ScanningState(tint: Module.updater.tint, label: "Checking for updates…")
            } else if !vm.hasBrew {
                noBrew
            } else if vm.outdated.isEmpty {
                EmptyState(icon: "checkmark.seal.fill", title: "Everything's up to date",
                           message: "None of your Homebrew-managed apps have updates right now.",
                           tint: Theme.good)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(vm.outdated) { app in
                            UpdateRow(app: app, busy: vm.upgrading.contains(app.token)) { vm.upgrade(app) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .onAppear { if !vm.checked { vm.load() } }
    }

    private var noBrew: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(Module.updater.tint.opacity(0.12)).frame(width: 92, height: 92)
                Image(systemName: "shippingbox").font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Module.updater.tint)
            }
            Text("Connect Homebrew").font(.rounded(20, .semibold))
            Text("Geraldine checks app updates through Homebrew, the popular Mac package manager. Install it once and update detection turns on automatically.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            Button { vm.copyInstallCommand() } label: {
                Label("Copy install command", systemImage: "doc.on.doc")
            }
            .padding(.top, 2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct UpdateRow: View {
    let app: OutdatedApp
    let busy: Bool
    let upgrade: () -> Void

    var body: some View {
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
        .card(padding: 14)
    }
}
