import Foundation

/// A metric that can appear as a resizable widget in the menu-bar popover.
/// The first item in the layout also drives the live menu-bar status item.
enum MetricKind: String, Codable, CaseIterable, Identifiable {
    case temperature, cpu, gpu, memory, storage, battery, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return "Temperature"
        case .cpu:         return "CPU"
        case .gpu:         return "GPU"
        case .memory:      return "Memory"
        case .storage:     return "Storage"
        case .battery:     return "Battery"
        case .network:     return "Network"
        }
    }

    func title(hasBattery: Bool) -> String {
        self == .battery && !hasBattery ? "Power" : title
    }

    func isAvailable(hasBattery: Bool) -> Bool {
        self != .battery || hasBattery
    }

    var icon: String {
        switch self {
        case .temperature: return "thermometer.medium"
        case .cpu:         return "cpu"
        case .gpu:         return "cpu"
        case .memory:      return "memorychip"
        case .storage:     return "internaldrive"
        case .battery:     return "battery.100"
        case .network:     return "wifi"
        }
    }

    func icon(hasBattery: Bool) -> String {
        self == .battery && !hasBattery ? "powerplug" : icon
    }

    /// Fast-changing metrics read well as a time-series sparkline; slow ones (battery,
    /// storage) are better shown as a glyph + value in the cramped menu bar.
    var isTimeSeries: Bool {
        switch self {
        case .temperature, .cpu, .gpu, .memory, .network: return true
        case .battery, .storage: return false
        }
    }
}

/// What a widget tile holds. Metrics drive sparklines/readouts; Keep Awake is a
/// control; coding-usage tiles show remaining provider allowance. They share the
/// same draggable, resizable grid — but only metrics can drive the live menu-bar
/// status item (see `WidgetLayoutStore.menuBarKind`).
enum WidgetKind: Hashable, Identifiable {
    case metric(MetricKind)
    case keepAwake
    case calendar
    case aiUsage(AIUsageIdentity)

    var id: String {
        switch self {
        case .metric(let metric):     return metric.rawValue
        case .keepAwake:              return "keepAwake"
        case .calendar:               return "calendar"
        case .aiUsage(let identity):  return identity.widgetID
        }
    }

    init?(id: String) {
        switch id {
        case "keepAwake":    self = .keepAwake
        case "calendar":     self = .calendar
        default:
            if let identity = AIUsageIdentity.from(widgetID: id) {
                self = .aiUsage(identity)
            } else if let metric = MetricKind(rawValue: id) {
                self = .metric(metric)
            } else {
                return nil
            }
        }
    }

    /// The provider's default login: `.aiUsage(.claude)`.
    static func aiUsage(_ provider: AICodingProvider) -> WidgetKind {
        .aiUsage(AIUsageIdentity(provider))
    }

    /// Whether the tile cycles through the small/medium/large sizes. The calendar (which
    /// holds the month grid and world clocks) is inherently full-width, so it can only
    /// be reordered, never resized.
    var canResize: Bool {
        switch self {
        case .metric, .keepAwake, .aiUsage: return true
        case .calendar:                     return false
        }
    }

    /// The underlying metric, or nil for non-metric controls like Keep Awake.
    var metric: MetricKind? {
        if case .metric(let metric) = self { return metric }
        return nil
    }

    var title: String {
        switch self {
        case .metric(let metric):     return metric.title
        case .keepAwake:              return "Keep Awake"
        case .calendar:               return "Calendar & Clocks"
        case .aiUsage(let identity):
            return identity.folderName.map { "\(identity.provider.title) · \($0)" } ?? identity.provider.title
        }
    }

    func title(hasBattery: Bool) -> String {
        switch self {
        case .metric(let metric):     return metric.title(hasBattery: hasBattery)
        case .keepAwake:              return "Keep Awake"
        case .calendar:               return "Calendar & Clocks"
        case .aiUsage:                return title
        }
    }
}

/// Encoded as a single string so layouts persisted before Keep Awake became a
/// widget (which stored a bare `MetricKind` raw value) still decode cleanly.
extension WidgetKind: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = WidgetKind(id: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown widget kind \"\(raw)\""))
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

/// Uniform tile sizes on the popover's four-column grid, like iOS Home Screen widgets.
/// Small and medium tiles share one fixed row height so rows always line up; large
/// tiles span the full width and take the height their content needs.
enum WidgetSize: String, Codable, CaseIterable {
    case small   // 1×1 — one column
    case medium  // 2×1 — two columns, same height as small
    case large   // full width

    /// Columns occupied on the four-track grid.
    var span: Int {
        switch self {
        case .small:  return 1
        case .medium: return 2
        case .large:  return 4
        }
    }

    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }

    var next: WidgetSize {
        switch self {
        case .small:  return .medium
        case .medium: return .large
        case .large:  return .small
        }
    }
}

struct WidgetItem: Codable, Identifiable, Equatable {
    var kind: WidgetKind
    var size: WidgetSize
    var isShown: Bool
    var id: String { kind.id }

    init(_ kind: WidgetKind, _ size: WidgetSize, isShown: Bool = true) {
        self.kind = kind
        // Non-resizable tiles (the calendar) are pinned to full width at the model level,
        // so no mutation path can produce a squeezed month grid.
        self.size = kind.canResize ? size : .large
        self.isShown = isShown
    }

    /// Convenience for the common metric case: `WidgetItem(.cpu, .small)`.
    init(_ metric: MetricKind, _ size: WidgetSize, isShown: Bool = true) {
        self.init(.metric(metric), size, isShown: isShown)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, size, isShown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(WidgetKind.self, forKey: .kind)
        let size = try container.decode(WidgetSize.self, forKey: .size)
        let isShown = try container.decodeIfPresent(Bool.self, forKey: .isShown) ?? true
        self.init(kind, size, isShown: isShown)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(size, forKey: .size)
        try container.encode(isShown, forKey: .isShown)
    }
}

/// Ordered, persisted list of menu-bar widgets. Order is meaningful: index 0 is the
/// widget shown live in the menu bar, and packing flows in order onto a four-column
/// grid (small = 1 column, medium = 2, large = full width) like iOS Home Screen widgets.
@MainActor
final class WidgetLayoutStore: ObservableObject {
    @Published private(set) var items: [WidgetItem]
    private let defaults: UserDefaults

    /// The last persisted order. The menu-bar status item reads this instead of `items`
    /// so a live reorder drag (which stages moves without persisting) doesn't make the
    /// status item flicker between metrics until the drop commits.
    private var committedItems: [WidgetItem]

    private static let key = "geraldine.widgetLayout.v3"
    private static let previousKey = "geraldine.widgetLayout.v2"
    private static let legacyKey = "geraldine.widgetLayout.v1"

    /// Keep Awake defaults to the full-width watch panel so the eye, time markers,
    /// honeycomb, and Stay Active controls are all visible without a resize step.
    static let defaults: [WidgetItem] = [
        WidgetItem(.temperature, .medium),
        WidgetItem(.keepAwake, .large),
        WidgetItem(.cpu, .small),
        WidgetItem(.memory, .small),
        WidgetItem(.gpu, .medium, isShown: false),
        WidgetItem(.network, .medium),
        WidgetItem(.storage, .small, isShown: false),
        WidgetItem(.battery, .small, isShown: false),
        WidgetItem(.calendar, .large, isShown: false),
        WidgetItem(.aiUsage(.codex), .small, isShown: false),
        WidgetItem(.aiUsage(.claude), .small, isShown: false),
        WidgetItem(.aiUsage(.cursor), .small, isShown: false),
        WidgetItem(.aiUsage(.grok), .small, isShown: false),
        WidgetItem(.aiUsage(.antigravity), .small, isShown: false)
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let current = Self.load(key: Self.key, legacySizes: false, defaults: defaults)
        let previous = current == nil
            ? Self.load(key: Self.previousKey, legacySizes: false, defaults: defaults)
            : nil
        let legacy = current == nil && previous == nil
            ? Self.load(key: Self.legacyKey, legacySizes: true, defaults: defaults)
            : nil
        let needsWatchPanelMigration = current == nil && (previous != nil || legacy != nil)
        let loaded = needsWatchPanelMigration
            ? Self.upgradingKeepAwakeToWatchPanel(previous ?? legacy ?? Self.defaults)
            : (current ?? Self.defaults)
        items = loaded
        committedItems = loaded
        if needsWatchPanelMigration {
            Self.save(loaded, key: Self.key, defaults: defaults)
        }
    }

    /// The metric mirrored live in the menu-bar status item. Non-metric widgets
    /// (Keep Awake, Calendar) are skipped, so they never drive the bar even from the top slot.
    func menuBarKind(hasBattery: Bool) -> MetricKind {
        let visibleMetric = committedItems
            .filter(\.isShown)
            .compactMap(\.kind.metric)
            .first { $0.isAvailable(hasBattery: hasBattery) }
        let fallbackMetric = committedItems
            .compactMap(\.kind.metric)
            .first { $0.isAvailable(hasBattery: hasBattery) }
        return visibleMetric ?? fallbackMetric ?? .temperature
    }

    /// Whether the widget can appear in this popover at all (battery metric needs a
    /// battery; the calendar needs its popover setting). One home for the rule the grid
    /// renders with and the drag hit-testing predicts with — they must never disagree.
    nonisolated static func isEligible(_ kind: WidgetKind, hasBattery: Bool, calendarInPopover: Bool) -> Bool {
        switch kind {
        case .metric(let metric): return metric.isAvailable(hasBattery: hasBattery)
        case .keepAwake:          return true
        case .calendar:           return calendarInPopover
        case .aiUsage:            return true
        }
    }

    /// The tiles the grid actually shows, in order.
    func visibleItems(hasBattery: Bool, calendarInPopover: Bool) -> [WidgetItem] {
        items.filter {
            $0.isShown && Self.isEligible($0.kind, hasBattery: hasBattery, calendarInPopover: calendarInPopover)
        }
    }

    func cycleSize(_ kind: WidgetKind) {
        guard kind.canResize, let idx = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[idx].size = items[idx].size.next
        persist()
    }

    func setSize(_ kind: WidgetKind, _ size: WidgetSize) {
        guard kind.canResize,
              let idx = items.firstIndex(where: { $0.kind == kind }),
              items[idx].size != size else { return }
        items[idx].size = size
        persist()
    }

    /// Move the widget to the very front of the order. For metrics this also makes it
    /// drive the live menu-bar status item (see `menuBarKind`).
    func moveToFront(_ kind: WidgetKind) {
        guard let first = items.first?.kind, first != kind else { return }
        move(kind, before: first)
    }

    func setShown(_ kind: WidgetKind, _ isShown: Bool) {
        if let idx = items.firstIndex(where: { $0.kind == kind }) {
            items[idx].isShown = isShown
        } else {
            items.append(WidgetItem(kind, .small, isShown: isShown))
        }
        persist()
    }

    /// Add a tile for each newly discovered login, right after its provider's
    /// other tiles. A sibling login takes its default tile's size and starts
    /// shown when that tile is shown, so a second account appears beside the first.
    func ensureAIUsageIdentities(_ identities: [AIUsageIdentity]) {
        var next = items
        for identity in identities where !next.contains(where: { $0.kind == .aiUsage(identity) }) {
            let defaultTile = next.first { $0.kind == .aiUsage(identity.provider) }
            let item = WidgetItem(.aiUsage(identity), defaultTile?.size ?? .small,
                                  isShown: !identity.accountKey.isEmpty && defaultTile?.isShown == true)
            let lastOfProvider = next.lastIndex { existing in
                guard case .aiUsage(let other) = existing.kind else { return false }
                return other.provider == identity.provider
            }
            next.insert(item, at: lastOfProvider.map { $0 + 1 } ?? next.endIndex)
        }
        guard next != items else { return }
        items = next
        persist()
    }

    /// Live reorder while a drag is in flight: `dragged` takes `target`'s position and the
    /// rest reflow. "Stage" = deliberately does NOT persist — this runs on every retarget
    /// during a drag; the drop calls `persistNow()` once.
    func stageMove(_ dragged: WidgetKind, toIndexOf target: WidgetKind) {
        guard dragged != target,
              let from = items.firstIndex(where: { $0.kind == dragged }),
              let to = items.firstIndex(where: { $0.kind == target }),
              from != to else { return }
        items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func persistNow() {
        persist()
    }

    /// Abandon every staged (unpersisted) move, restoring the last committed order.
    /// This is the Escape-cancels-the-drag path: staging never touched
    /// `committedItems`, so the committed array *is* the pre-drag state.
    func revertStagedChanges() {
        guard items != committedItems else { return }
        items = committedItems
    }

    /// Move `dragged` so it sits immediately before `target` in the order.
    func move(_ dragged: WidgetKind, before target: WidgetKind) {
        guard dragged != target,
              let from = items.firstIndex(where: { $0.kind == dragged }) else { return }
        var arr = items
        let moved = arr.remove(at: from)
        let insertAt = arr.firstIndex(where: { $0.kind == target }) ?? arr.count
        arr.insert(moved, at: insertAt)
        items = arr
        persist()
    }

    /// Live-drag companion to `stageMove(_:toIndexOf:)` — also leaves persisting to the drop.
    func stageMoveToEnd(_ kind: WidgetKind) {
        guard let index = items.firstIndex(where: { $0.kind == kind }),
              index != items.count - 1 else { return }
        var updated = items
        let moved = updated.remove(at: index)
        updated.append(moved)
        items = updated
    }

    func reset() {
        items = Self.defaults
        persist()
    }

    private func persist() {
        committedItems = items
        Self.save(items, key: Self.key, defaults: defaults)
    }

    private static func save(_ items: [WidgetItem], key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }

    /// One-time v2/v1 upgrade: the approved design requires the full-width watch face.
    /// Once saved under v3, later user-initiated resizes remain untouched.
    nonisolated static func upgradingKeepAwakeToWatchPanel(
        _ items: [WidgetItem]
    ) -> [WidgetItem] {
        var upgraded = items
        if let index = upgraded.firstIndex(where: { $0.kind == .keepAwake }) {
            upgraded[index].size = .large
        }
        return upgraded
    }

    /// Mirrors a persisted `WidgetItem` but keeps kind and size as raw strings, so a saved
    /// entry whose kind no longer exists (e.g. the old separate world-clocks widget)
    /// can be skipped instead of failing the whole decode and wiping the layout.
    private struct StoredItem: Decodable {
        let kind: String
        let size: String
        let isShown: Bool?
    }

    /// `legacySizes` decodes the v1 two-size scheme, where "large" meant a half-row
    /// two-track tile — today's `.medium`. The calendar is pinned to full width either way.
    private static func load(
        key: String,
        legacySizes: Bool,
        defaults: UserDefaults
    ) -> [WidgetItem]? {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode([StoredItem].self, from: data) else { return nil }
        let decoded = stored.compactMap { item -> WidgetItem? in
            guard let kind = WidgetKind(id: item.kind) else { return nil }
            var size = WidgetSize(rawValue: item.size) ?? defaultItem(for: kind).size
            if legacySizes, size == .large {
                // v1 "large" was a two-track tile — today's medium. The network tile is
                // the exception: its defining traffic chart only lives in the new full-width
                // large, so migrating it to medium would silently drop the chart.
                size = kind == .metric(.network) ? .large : .medium
            }
            return WidgetItem(kind, size, isShown: item.isShown ?? true)
        }
        guard !decoded.isEmpty else { return nil }
        // Drop duplicates and append any newly-added widgets (including Keep Awake,
        // for layouts saved before it existed) so the layout stays valid across updates.
        var seen = Set<WidgetKind>()
        var result = decoded.filter { seen.insert($0.kind).inserted }
        for kind in MetricKind.allCases where !seen.contains(.metric(kind)) {
            result.append(defaultItem(for: .metric(kind)))
        }
        if !seen.contains(.keepAwake) {
            result.append(defaultItem(for: .keepAwake))
        }
        if !seen.contains(.calendar) {
            result.append(defaultItem(for: .calendar))
        }
        for provider in AICodingProvider.allCases where !seen.contains(.aiUsage(provider)) {
            result.append(defaultItem(for: .aiUsage(provider)))
        }
        return result
    }

    private static func defaultItem(for kind: WidgetKind) -> WidgetItem {
        defaults.first { $0.kind == kind } ?? WidgetItem(kind, kind.canResize ? .small : .large)
    }
}
