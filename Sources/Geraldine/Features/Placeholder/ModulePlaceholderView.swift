import SwiftUI

/// Polished stand-in for modules not yet implemented, so navigation feels
/// complete. Each gets replaced by its real screen as we build it.
struct ModulePlaceholderView: View {
    var module: Module

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: module)
            EmptyState(icon: module.systemImage,
                       title: "\(module.title) Is On The Way",
                       message: "This module is being built. It'll live right here.",
                       tint: module.tint)
        }
    }
}

/// Shared header used at the top of every module screen.
struct ModuleHeader<Trailing: View>: View {
    let module: Module
    let title: String?
    let subtitle: String?
    let systemImage: String?
    @ViewBuilder let trailing: Trailing

    init(module: Module, @ViewBuilder trailing: () -> Trailing) {
        self.module = module
        self.title = nil
        self.subtitle = nil
        self.systemImage = nil
        self.trailing = trailing()
    }

    var body: some View {
        PageHeader(
            module: module,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage
        ) {
            trailing
        }
        .padding(.horizontal, Theme.Layout.pagePadding)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(module: Module, title: String? = nil, subtitle: String? = nil, systemImage: String? = nil) {
        self.module = module
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailing = EmptyView()
    }
}
