import XCTest
@testable import Geraldine

final class LaunchItemIdentityTests: XCTestCase {
    func testIdentitySurvivesMoveBetweenEnabledAndDisabledDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeraldineLaunchItemIdentity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let enabledDirectory = root.appendingPathComponent("LaunchAgents")
        let disabledDirectory = root.appendingPathComponent("DisabledLaunchAgents")
        try FileManager.default.createDirectory(at: enabledDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)

        let enabledURL = enabledDirectory.appendingPathComponent("com.example.agent.plist")
        try Data("<plist/>".utf8).write(to: enabledURL)
        let enabled = LaunchItem(label: "Example", program: "/tmp/example",
                                 plistURL: enabledURL, scope: .user, enabled: true)

        let disabledURL = disabledDirectory.appendingPathComponent(enabledURL.lastPathComponent)
        try FileManager.default.moveItem(at: enabledURL, to: disabledURL)
        let disabled = LaunchItem(label: "Example", program: "/tmp/example",
                                  plistURL: disabledURL, scope: .user, enabled: false)

        XCTAssertEqual(enabled.id, disabled.id)
    }

    func testDuplicateBasenamesRemainDistinct() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeraldineLaunchItemCollision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let enabledDirectory = root.appendingPathComponent("LaunchAgents")
        let disabledDirectory = root.appendingPathComponent("DisabledLaunchAgents")
        try FileManager.default.createDirectory(at: enabledDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)

        let enabledURL = enabledDirectory.appendingPathComponent("com.example.agent.plist")
        let disabledURL = disabledDirectory.appendingPathComponent("com.example.agent.plist")
        try Data("<plist><string>enabled</string></plist>".utf8).write(to: enabledURL)
        try Data("<plist><string>disabled</string></plist>".utf8).write(to: disabledURL)

        let enabled = LaunchItem(label: "Example", program: "/tmp/example",
                                 plistURL: enabledURL, scope: .user, enabled: true)
        let disabled = LaunchItem(label: "Example", program: "/tmp/example",
                                  plistURL: disabledURL, scope: .user, enabled: false)

        XCTAssertNotEqual(enabled.id, disabled.id)
    }
}
