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

    /// Fast-changing metrics read well as a time-series sparkline; slow ones (battery,
    /// storage) are better shown as a glyph + value in the cramped menu bar.
    var isTimeSeries: Bool {
        switch self {
        case .temperature, .cpu, .memory, .network: return true
        case .battery, .storage: return false
        }
    }
}

enum WidgetSize: String, Codable {
    case small, large
    mutating func toggle() { self = self == .small ? .large : .small }
}

struct WidgetItem: Codable, Identifiable, Equatable {
    var kind: MetricKind
    var size: WidgetSize
    var id: String { kind.rawValue }

    init(_ kind: MetricKind, _ size: WidgetSize) {
        self.kind = kind
        self.size = size
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
        WidgetItem(.cpu, .small),
        WidgetItem(.memory, .small),
        WidgetItem(.storage, .small),
        WidgetItem(.battery, .small),
        WidgetItem(.network, .large)
    ]

    init() {
        items = Self.load(key: "geraldine.widgetLayout.v1") ?? Self.defaults
    }

    /// The metric mirrored live in the menu-bar status item.
    var menuBarKind: MetricKind { items.first?.kind ?? .temperature }

    func toggleSize(_ kind: MetricKind) {
        guard let idx = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[idx].size.toggle()
        persist()
    }

    /// Move `dragged` so it sits immediately before `target` in the order.
    func move(_ dragged: MetricKind, before target: MetricKind) {
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

    private static func load(key: String) -> [WidgetItem]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WidgetItem].self, from: data),
              !decoded.isEmpty else { return nil }
        // Drop unknown/duplicate kinds and append any newly-added metrics so the
        // layout stays valid across app updates.
        var seen = Set<MetricKind>()
        var result = decoded.filter { seen.insert($0.kind).inserted }
        for kind in MetricKind.allCases where !seen.contains(kind) {
            result.append(WidgetItem(kind, .small))
        }
        return result
    }
}
