import XCTest
@testable import Geraldine

@MainActor
final class WidgetLayoutMigrationTests: XCTestCase {
    func testKeepAwakeWatchPanelMigrationExpandsOnlyKeepAwake() {
        let input = [
            WidgetItem(.temperature, .medium),
            WidgetItem(.keepAwake, .medium),
            WidgetItem(.cpu, .small),
            WidgetItem(.calendar, .large, isShown: false)
        ]

        let upgraded = WidgetLayoutStore.upgradingKeepAwakeToWatchPanel(input)

        XCTAssertEqual(upgraded.first { $0.kind == .keepAwake }?.size, .large)
        XCTAssertEqual(upgraded.first { $0.kind == .metric(.temperature) }?.size, .medium)
        XCTAssertEqual(upgraded.first { $0.kind == .metric(.cpu) }?.size, .small)
        XCTAssertEqual(upgraded.first { $0.kind == .calendar }?.size, .large)
        XCTAssertEqual(upgraded.first { $0.kind == .calendar }?.isShown, false)
    }

    func testInitializerMigratesV2ToV3AndCurrentLayoutTakesPrecedence() throws {
        let suiteName = "WidgetLayoutMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let v2 = [
            WidgetItem(.temperature, .small),
            WidgetItem(.keepAwake, .medium)
        ]
        defaults.set(try JSONEncoder().encode(v2), forKey: "geraldine.widgetLayout.v2")

        let migrated = WidgetLayoutStore(defaults: defaults)
        XCTAssertEqual(migrated.items.first { $0.kind == .keepAwake }?.size, .large)

        let persistedV3Data = try XCTUnwrap(
            defaults.data(forKey: "geraldine.widgetLayout.v3")
        )
        let persistedV3 = try JSONDecoder().decode([WidgetItem].self, from: persistedV3Data)
        XCTAssertEqual(persistedV3.first { $0.kind == .keepAwake }?.size, .large)

        var current = persistedV3
        let keepAwakeIndex = try XCTUnwrap(
            current.firstIndex { $0.kind == .keepAwake }
        )
        current[keepAwakeIndex].size = .small
        defaults.set(
            try JSONEncoder().encode(current),
            forKey: "geraldine.widgetLayout.v3"
        )

        let reloaded = WidgetLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.items.first { $0.kind == .keepAwake }?.size, .small)
    }
}
