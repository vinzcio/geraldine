import SwiftUI

/// First-run welcome sheet.
struct WelcomeView: View {
    @EnvironmentObject var state: AppState
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.brandGradient).frame(width: 84, height: 84)
                Image(systemName: "sparkles").font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
            }
            Text("Welcome to Geraldine").font(.rounded(26, .bold))
            Text("Your Mac's tidy little helper — live vitals in the menu bar, plus one-tap cleanup, space insights, and upkeep. Nothing is ever deleted without your say-so; everything goes to the Trash first.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)

            VStack(spacing: 10) {
                bullet("gauge.with.dots.needle.50percent", "Live system monitor in your menu bar")
                bullet("sparkles", "Cleanup, Space Lens, large files & uninstaller")
                bullet("lock.shield.fill", "Safe by design — review before anything moves")
            }
            .padding(.vertical, 4)

            HStack(spacing: 10) {
                if !state.hasFullDiskAccess {
                    Button {
                        Permissions.openFullDiskAccessSettings()
                    } label: { Label("Grant Full Disk Access", systemImage: "lock.open") }
                        .buttonStyle(.bordered)
                }
                PrimaryButton(title: "Start using Geraldine", icon: "arrow.right", action: onDone)
            }
            .padding(.top, 4)
        }
        .padding(34)
        .frame(width: 560)
        .onAppear { state.refreshFullDiskAccess() }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            Text(text).font(.callout)
            Spacer()
        }
        .frame(maxWidth: 380)
    }
}
