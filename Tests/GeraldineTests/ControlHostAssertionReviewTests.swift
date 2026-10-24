import Foundation
import IOKit.pwr_mgt
import XCTest
import GeraldineControl
@testable import Geraldine

/// Captures the real controller's assertion calls without changing macOS power state.
@MainActor
final class AppReviewPowerAssertions {
    struct Creation {
        let id: IOPMAssertionID
        let type: String
        let level: IOPMAssertionLevel
        let name: String
    }

    private(set) var created: [Creation] = []
    private(set) var released: [IOPMAssertionID] = []
    private(set) var held: [IOPMAssertionID: Creation] = [:]
    var failingType: String?
    private var nextID: IOPMAssertionID = 100

    func create(type: CFString, level: IOPMAssertionLevel, name: CFString, id: inout IOPMAssertionID) -> IOReturn {
        if (type as String) == failingType { return kIOReturnError }
        id = nextID
        nextID += 1
        let creation = Creation(id: id, type: type as String, level: level, name: name as String)
        created.append(creation)
        held[id] = creation
        return kIOReturnSuccess
    }

    func release(_ id: IOPMAssertionID) -> IOReturn {
        XCTAssertNotNil(held.removeValue(forKey: id), "Released an assertion this fixture did not hold")
        released.append(id)
        return kIOReturnSuccess
    }

    func id(for type: String) -> IOPMAssertionID? {
        held.values.first { $0.type == type }?.id
    }

    var snapshot: PowerAssertionSnapshot {
        PowerAssertionSnapshot(
            available: true,
            idleSleep: id(for: kIOPMAssertionTypeNoIdleSleep as String) != nil,
            displaySleep: id(for: kIOPMAssertionTypePreventUserIdleDisplaySleep as String) != nil,
            names: held.values.map(\.name).sorted()
        )
    }
}

@MainActor
final class ControlHostAssertionReviewTests: XCTestCase {
    func testActiveSettingsKeepSystemAssertionAndReacquireDisplayWithoutRestartingSession() async throws {
        let suite = "ControlHostAssertionReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "keepAwake.simulateIdleActivity")
        var pulses = 0
        let idle = IdleActivitySimulationService(
            accessibilityAvailable: { true }, currentIdleDuration: { 0 },
            pulsePoster: { pulses += 1; return true }
        )
        let assertions = AppReviewPowerAssertions()
        let controller = KeepAwakeController(
            defaults: defaults, currentPowerSourceIsBattery: { false }, idleActivitySimulator: idle,
            createAssertion: assertions.create, releaseAssertion: assertions.release
        )
        defer { controller.shutdown() }
        let host = ControlHost(defaults: defaults, keepAwake: { controller }, assertions: { assertions.snapshot })

        let on = await host.handle(ControlRequest(command: "awake", arguments: ["on"], options: ["duration": "indefinitely"]))
        XCTAssertTrue(on.ok)
        XCTAssertEqual(on.result?["active"], .bool(true))
        XCTAssertNil(controller.activeUntil)
        XCTAssertNil(controller.remaining)
        XCTAssertTrue(idle.hasScheduledTimer)
        XCTAssertEqual(controller.idleActivityPhase, .waiting)
        let session = controller.expirationSessionToken
        let systemID = try XCTUnwrap(assertions.id(for: kIOPMAssertionTypeNoIdleSleep as String))
        let displayID = try XCTUnwrap(assertions.id(for: kIOPMAssertionTypePreventUserIdleDisplaySleep as String))
        XCTAssertEqual(assertions.created.count, 2)

        let allow = await host.handle(ControlRequest(command: "settings", arguments: ["set", "keepAwake.allowDisplaySleep", "true"]))
        XCTAssertTrue(allow.ok)
        XCTAssertEqual(allow.result?["previousValue"], .bool(false))
        XCTAssertEqual(allow.result?["value"], .bool(true))
        XCTAssertTrue(defaults.bool(forKey: "keepAwake.allowDisplaySleep"))
        XCTAssertEqual(assertions.id(for: kIOPMAssertionTypeNoIdleSleep as String), systemID)
        XCTAssertNil(assertions.id(for: kIOPMAssertionTypePreventUserIdleDisplaySleep as String))
        XCTAssertEqual(assertions.released, [displayID])
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.expirationSessionToken, session)
        XCTAssertTrue(idle.hasScheduledTimer)

        let prevent = await host.handle(ControlRequest(command: "settings", arguments: ["set", "keepAwake.allowDisplaySleep", "false"]))
        XCTAssertTrue(prevent.ok)
        XCTAssertFalse(defaults.bool(forKey: "keepAwake.allowDisplaySleep"))
        XCTAssertEqual(assertions.id(for: kIOPMAssertionTypeNoIdleSleep as String), systemID)
        let replacementDisplayID = try XCTUnwrap(assertions.id(for: kIOPMAssertionTypePreventUserIdleDisplaySleep as String))
        XCTAssertNotEqual(replacementDisplayID, displayID)
        XCTAssertEqual(assertions.created.count, 3)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.expirationSessionToken, session)
        let readback = await host.handle(ControlRequest(command: "settings", arguments: ["get", "keepAwake.allowDisplaySleep"]))
        XCTAssertEqual(readback.result?["value"], .bool(false))

        let off = await host.handle(ControlRequest(command: "awake", arguments: ["off"]))
        XCTAssertTrue(off.ok)
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(assertions.held.isEmpty)
        XCTAssertEqual(assertions.released, [displayID, systemID, replacementDisplayID])
        XCTAssertFalse(idle.hasScheduledTimer)
        XCTAssertEqual(controller.idleActivityPhase, .off)
        XCTAssertEqual(pulses, 0)
        XCTAssertTrue(assertions.created.allSatisfy { $0.name == "Geraldine Keep Awake" })
        XCTAssertTrue(assertions.created.allSatisfy { $0.level == IOPMAssertionLevel(kIOPMAssertionLevelOn) })
    }

    func testAssertionCreationFailurePreservesExistingErrorAndReleasesPriorAssertions() async throws {
        for (type, message) in [
            (kIOPMAssertionTypeNoIdleSleep as String, "Could not prevent system sleep."),
            (kIOPMAssertionTypePreventUserIdleDisplaySleep as String, "Could not prevent display sleep.")
        ] {
            let suite = "ControlHostAssertionReviewTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let assertions = AppReviewPowerAssertions()
            assertions.failingType = type
            let controller = KeepAwakeController(
                defaults: defaults, currentPowerSourceIsBattery: { false },
                idleActivitySimulator: IdleActivitySimulationService(
                    accessibilityAvailable: { false }, currentIdleDuration: { 0 },
                    pulsePoster: { XCTFail("Unexpected activity pulse"); return false }
                ),
                createAssertion: assertions.create, releaseAssertion: assertions.release
            )
            defer { controller.shutdown() }
            let host = ControlHost(defaults: defaults, keepAwake: { controller }, assertions: { assertions.snapshot })
            let response = await host.handle(ControlRequest(command: "awake", arguments: ["on"], options: ["duration": "indefinitely"]))
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, .failed)
            XCTAssertEqual(response.error?.message, message)
            XCTAssertEqual(controller.lastError, message)
            XCTAssertFalse(controller.isActive)
            XCTAssertTrue(assertions.held.isEmpty)
            XCTAssertEqual(Set(assertions.released), Set(assertions.created.map(\.id)))
        }
    }

    func testBuildIdentityIncludesTruthfulBundleRevisionAndBuildMetadata() throws {
        let root = try AppReviewFixtureRoot.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Identity.bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.vincent.geraldine.tests.identity",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "7.8.9",
            "CFBundleVersion": "421",
            "GeraldineBuildCommit": commit,
            "GeraldineBuildCommitShort": "0123456789ab",
            "GeraldineBuildDirty": true,
            "GeraldineBuildDate": "2026-10-23T00:00:00Z",
            "GeraldineBuildConfiguration": "ReviewFixture"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let build = BuildInfo(bundle: try XCTUnwrap(Bundle(url: bundleURL)))
        let identity = ControlHost.appIdentityJSON(build: build)
        XCTAssertEqual(identity["version"], .string("7.8.9"))
        XCTAssertEqual(identity["build"], .string("421"))
        XCTAssertEqual(identity["configuration"], .string("ReviewFixture"))
        XCTAssertEqual(identity["commit"], .string(commit))
        XCTAssertEqual(identity["shortCommit"], .string("0123456789ab"))
        XCTAssertEqual(identity["isDirty"], .bool(true))
        XCTAssertEqual(identity["builtAt"], .string("2026-10-23T00:00:00Z"))
    }
}
