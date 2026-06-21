import SwiftUI

/// Polished stand-in for modules not yet implemented, so navigation feels
/// complete. Each gets replaced by its real screen as we build it.
struct ModulePlaceholderView: View {
    var module: Module

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: module)
            EmptyState(icon: module.systemImage,
                       title: "\(module.title) is on the way",
                       message: "This module is being built. It'll live right here.",
                       tint: module.tint)
        }
    }
}

/// Shared header used at the top of every module screen.
struct ModuleHeader: View {
    var module: Module
    var trailing: AnyView? = nil

    init(module: Module) { self.module = module; self.trailing = nil }
    init(module: Module, @ViewBuilder trailing: () -> some View) {
        self.module = module
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(module.tint.opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: module.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(module.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.rounded(22, .bold))
                Text(module.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 14)
    }
}
