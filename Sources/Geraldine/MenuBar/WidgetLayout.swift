import Foundation

/// A metric that can appear as a resizable widget in the menu-bar popover.
/// The first item in the layout also drives the live menu-bar status item.
enum MetricKind: String, Codable, CaseIterable, Identifiable {
    case temperature, cpu, memory, storage, battery, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return "Temperature"
        case .cpu:         return "CPU"
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
        case .temperature, .cpu, .memory, .network: return true
        case .battery, .storage: return false
        }
    }
}

/// What a widget tile holds. Metrics drive sparklines/readouts; Keep Awake is a
/// control. Both share the same draggable, resizable grid — but only metrics can
/// drive the live menu-bar status item (see `WidgetLayoutStore.menuBarKind`).
enum WidgetKind: Hashable, Identifiable {
    case metric(MetricKind)
    case keepAwake
    case calendar

    var id: String {
        switch self {
        case .metric(let metric): return metric.rawValue
        case .keepAwake:          return "keepAwake"
        case .calendar:           return "calendar"
        }
    }

    init?(id: String) {
        switch id {
        case "keepAwake":    self = .keepAwake
        case "calendar":     self = .calendar
        default:
            guard let metric = MetricKind(rawValue: id) else { return nil }
            self = .metric(metric)
        }
    }

    /// Whether the tile can shrink to a half-width small size. The calendar (which holds
    /// the month grid and world clocks) is inherently full-width, so it only offers the
    /// drag-to-reorder handle.
    var canResize: Bool {
        switch self {
        case .metric, .keepAwake: return true
        case .calendar:           return false
        }
    }

    /// The underlying metric, or nil for non-metric controls like Keep Awake.
    var metric: MetricKind? {
        if case .metric(let metric) = self { return metric }
        return nil
    }

    var title: String {
        switch self {
        case .metric(let metric): return metric.title
        case .keepAwake:          return "Keep Awake"
        case .calendar:           return "Calendar"
        }
    }

    func title(hasBattery: Bool) -> String {
        switch self {
        case .metric(let metric): return metric.title(hasBattery: hasBattery)
        case .keepAwake:          return "Keep Awake"
        case .calendar:           return "Calendar"
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

enum WidgetSize: String, Codable {
    case small, large
    mutating func toggle() { self = self == .small ? .large : .small }
}

struct WidgetItem: Codable, Identifiable, Equatable {
    var kind: WidgetKind
    var size: WidgetSize
    var id: String { kind.id }

    init(_ kind: WidgetKind, _ size: WidgetSize) {
        self.kind = kind
        self.size = size
    }

    /// Convenience for the common metric case: `WidgetItem(.cpu, .small)`.
    init(_ metric: MetricKind, _ size: WidgetSize) {
        self.init(.metric(metric), size)
    }
}

/// Ordered, persisted list of menu-bar widgets. Order is meaningful: index 0 is the
/// widget shown live in the menu bar, and packing flows in order (two smalls per row,
/// a large spanning the full row) like iOS Home Screen widgets.
@MainActor
final class WidgetLayoutStore: ObservableObject {
    @Published private(set) var items: [WidgetItem]

    private let key = "geraldine.widgetLayout.v1"

    static let defaults: [WidgetItem] = [
        WidgetItem(.temperature, .large),
        WidgetItem(.keepAwake, .large),
        WidgetItem(.cpu, .small),
        WidgetItem(.memory, .small),
        WidgetItem(.storage, .small),
        WidgetItem(.battery, .small),
        WidgetItem(.network, .large),
        WidgetItem(.calendar, .large)
    ]

    init() {
        items = Self.load(key: "geraldine.widgetLayout.v1") ?? Self.defaults
    }

    /// The metric mirrored live in the menu-bar status item. Non-metric widgets
    /// (Keep Awake, Calendar) are skipped, so they never drive the bar even from the top slot.
    func menuBarKind(hasBattery: Bool) -> MetricKind {
        items.compactMap(\.kind.metric).first { $0.isAvailable(hasBattery: hasBattery) } ?? .temperature
    }

    func toggleSize(_ kind: WidgetKind) {
        guard kind.canResize, let idx = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[idx].size.toggle()
        persist()
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

    func reset() {
        items = Self.defaults
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Mirrors a persisted `WidgetItem` but keeps the kind as a raw string, so a saved
    /// entry whose kind no longer exists (e.g. the old separate world-clocks widget)
    /// can be skipped instead of failing the whole decode and wiping the layout.
    private struct StoredItem: Decodable {
        let kind: String
        let size: WidgetSize
    }

    private static func load(key: String) -> [WidgetItem]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([StoredItem].self, from: data) else { return nil }
        let decoded = stored.compactMap { item in
            WidgetKind(id: item.kind).map { WidgetItem($0, item.size) }
        }
        guard !decoded.isEmpty else { return nil }
        // Drop duplicates and append any newly-added widgets (including Keep Awake,
        // for layouts saved before it existed) so the layout stays valid across updates.
        var seen = Set<WidgetKind>()
        var result = decoded.filter { seen.insert($0.kind).inserted }
        for kind in MetricKind.allCases where !seen.contains(.metric(kind)) {
            result.append(WidgetItem(kind, .small))
        }
        if !seen.contains(.keepAwake) {
            result.append(WidgetItem(.keepAwake, .large))
        }
        if !seen.contains(.calendar) {
            result.append(WidgetItem(.calendar, .large))
        }
        return result
    }
}
