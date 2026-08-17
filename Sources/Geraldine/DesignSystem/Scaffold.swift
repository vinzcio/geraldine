import SwiftUI

enum ScreenWidthRole {
    case fluid
    case readable
    case focused

    var maximum: CGFloat {
        switch self {
        case .fluid: Theme.Layout.contentMaxWidth
        case .readable: 920
        case .focused: Theme.Layout.readingMaxWidth
        }
    }
}

enum PageHeaderStyle {
    case standard
    case data
    case utility

    var iconSize: CGFloat {
        switch self {
        case .standard, .utility: 46
        case .data: 52
        }
    }
}

/// The shared page hero family. It keeps title, supporting copy, glyph, and
/// trailing actions aligned across dashboard, workflow, and utility screens.
struct PageHeader<Trailing: View>: View {
    let module: Module
    let title: String
    let subtitle: String
    let systemImage: String
    let style: PageHeaderStyle
    let tint: Color
    let showsGlyph: Bool
    @ViewBuilder let trailing: Trailing

    init(
        module: Module,
        title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        style: PageHeaderStyle = .standard,
        tint: Color? = nil,
        showsGlyph: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.module = module
        self.title = title ?? module.title
        self.subtitle = subtitle ?? module.subtitle
        self.systemImage = systemImage ?? module.systemImage
        self.style = style
        self.tint = tint ?? module.tint
        self.showsGlyph = showsGlyph
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            if showsGlyph {
                ModuleGlyph(systemImage: systemImage, tint: tint, size: style.iconSize)
                    .geraldineEntrance()
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(style == .data ? .geraldineHero : .geraldineTitle)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.geraldineBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .geraldineEntrance(delay: 0.08)

            Spacer(minLength: Theme.Spacing.md)

            trailing
                .geraldineEntrance(delay: 0.16, distance: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(
        module: Module,
        title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        style: PageHeaderStyle = .standard,
        tint: Color? = nil,
        showsGlyph: Bool = true
    ) {
        self.init(
            module: module,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            style: style,
            tint: tint,
            showsGlyph: showsGlyph
        ) { EmptyView() }
    }
}

/// Standard page insets and wide-window behavior without forcing a scroll view.
struct ScreenContent<Content: View>: View {
    let widthRole: ScreenWidthRole
    @ViewBuilder let content: Content

    init(widthRole: ScreenWidthRole = .fluid, @ViewBuilder content: () -> Content) {
        self.widthRole = widthRole
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: widthRole.maximum, alignment: .leading)
            .padding(.horizontal, Theme.Layout.pagePadding)
            .padding(.vertical, Theme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// The default scrolling page scaffold. Feature-specific state stays in the
/// feature view; this component owns only layout, hierarchy, and page rhythm.
struct ModulePage<Trailing: View, Content: View>: View {
    let module: Module
    let title: String?
    let subtitle: String?
    let systemImage: String?
    let headerTint: Color?
    let headerStyle: PageHeaderStyle
    let widthRole: ScreenWidthRole
    let showsHeaderGlyph: Bool
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    init(
        module: Module,
        title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        headerTint: Color? = nil,
        headerStyle: PageHeaderStyle = .standard,
        widthRole: ScreenWidthRole = .fluid,
        showsHeaderGlyph: Bool = true,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.module = module
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.headerTint = headerTint
        self.headerStyle = headerStyle
        self.widthRole = widthRole
        self.showsHeaderGlyph = showsHeaderGlyph
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            ScreenContent(widthRole: widthRole) {
                // Plain VStack, deliberately: pages are bounded, so laziness buys
                // nothing — and a lazy container re-runs its layout for every
                // per-second metric text change, which profiling showed as the
                // dominant visible-window cost, scaling with machine load.
                VStack(alignment: .leading, spacing: Theme.Layout.pageSpacing) {
                    PageHeader(
                        module: module,
                        title: title,
                        subtitle: subtitle,
                        systemImage: systemImage,
                        style: headerStyle,
                        tint: headerTint,
                        showsGlyph: showsHeaderGlyph
                    ) {
                        trailing
                    }
                    content
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

extension ModulePage where Trailing == EmptyView {
    init(
        module: Module,
        title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        headerTint: Color? = nil,
        headerStyle: PageHeaderStyle = .standard,
        widthRole: ScreenWidthRole = .fluid,
        showsHeaderGlyph: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            module: module,
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            headerTint: headerTint,
            headerStyle: headerStyle,
            widthRole: widthRole,
            showsHeaderGlyph: showsHeaderGlyph,
            trailing: { EmptyView() },
            content: content
        )
    }
}
