import AppKit
import Testing
@testable import Geraldine

struct AppShapeTests {
    @Test func menuBarOnlyUsesAccessoryPolicy() {
        #expect(AppShape.menuBarOnly.activationPolicy == .accessory)
    }

    @Test func dockModesUseRegularPolicy() {
        #expect(AppShape.menuBarAndWindow.activationPolicy == .regular)
        #expect(AppShape.windowOnly.activationPolicy == .regular)
    }

    @Test func savedShapeControlsLaunchPresentation() throws {
        for shape in AppShape.allCases {
            try withDefaults(["appShape": shape.rawValue]) { defaults in
                #expect(AppShape.load(from: defaults) == shape)
            }
        }
    }

    @Test func missingOrInvalidShapePreservesDefaultDockMode() throws {
        for values in [[:], ["appShape": "unknown"]] {
            try withDefaults(values) { defaults in
                #expect(AppShape.load(from: defaults) == .menuBarAndWindow)
            }
        }
    }

    private func withDefaults(_ values: [String: Any], check: (UserDefaults) -> Void) throws {
        let name = "AppShapeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.setPersistentDomain(values, forName: name)
        check(defaults)
    }
}
