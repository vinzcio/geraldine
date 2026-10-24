import XCTest
import GeraldineControl
@testable import Geraldine

@MainActor
final class ControlHostAppReviewTests: XCTestCase {
    func testSettingsRequestPersistsAndRefreshesTheInjectedIdleController() async throws {
        let suite = "ControlHostAppReviewTests.\(UUID().uuidString)"
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
        // Seed a fake waiting runtime; the live settings setter must stop it.
        idle.start()
        XCTAssertTrue(idle.hasScheduledTimer)
        XCTAssertEqual(controller.idleActivityPhase, .waiting)
        let host = ControlHost(defaults: defaults, keepAwake: { controller }, assertions: { assertions.snapshot })
        let response = await host.handle(ControlRequest(
            command: "settings", arguments: ["set", "keepAwake.simulateIdleActivity", "false"]
        ))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["previousValue"], .bool(true))
        XCTAssertEqual(response.result?["value"], .bool(false))
        XCTAssertFalse(defaults.bool(forKey: "keepAwake.simulateIdleActivity"))
        XCTAssertFalse(controller.simulateIdleActivity)
        XCTAssertFalse(idle.hasScheduledTimer)
        XCTAssertEqual(controller.idleActivityPhase, .off)
        XCTAssertEqual(pulses, 0)
        XCTAssertFalse(controller.isActive)
        let readback = await host.handle(ControlRequest(
            command: "settings", arguments: ["get", "keepAwake.simulateIdleActivity"]
        ))
        XCTAssertEqual(readback.result?["value"], .bool(false))
        let off = await host.handle(ControlRequest(command: "awake", arguments: ["off"]))
        XCTAssertTrue(off.ok)
        XCTAssertEqual(off.result?["assertions"]?["available"], .bool(true))
    }

    func testMalformedRequestsNeverResolveControllersOrSampleProcesses() async throws {
        let suite = "ControlHostAppReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Even a validation regression cannot create a real assertion here.
        defaults.set(true, forKey: "keepAwake.deactivateOnBattery")
        let assertions = AppReviewPowerAssertions()
        let controller = KeepAwakeController(
            defaults: defaults, currentPowerSourceIsBattery: { true },
            idleActivitySimulator: IdleActivitySimulationService(
                accessibilityAvailable: { false }, currentIdleDuration: { 0 }, pulsePoster: { XCTFail("Unexpected pulse"); return false }
            ),
            createAssertion: assertions.create, releaseAssertion: assertions.release
        )
        defer { controller.shutdown() }
        var controllerReads = 0
        var processReads = 0
        let host = ControlHost(defaults: defaults, keepAwake: { controllerReads += 1; return controller }, assertions: { .unavailable },
                               sampleProcesses: { _ in processReads += 1; return [] })
        let before = defaults.persistentDomain(forName: suite) as NSDictionary?
        let invalid = [
            ControlRequest(command: "awake", arguments: ["on", "extra"]),
            ControlRequest(command: "awake", arguments: ["off"], options: ["duration": "60"]),
            ControlRequest(command: "awake", arguments: ["on"], options: ["duration": "inf"]),
            ControlRequest(command: "awake", arguments: ["on"], options: ["duration": "nan"]),
            ControlRequest(command: "awake", arguments: ["on"], options: ["duration": "1e300"]),
            ControlRequest(command: "stay-active", arguments: ["on", "extra"]),
            ControlRequest(command: "settings", arguments: ["set", "keepAwake.allowDisplaySleep", "true", "extra"]),
            ControlRequest(command: "processes", options: ["top": String(Int.max)]),
            ControlRequest(command: "processes", options: ["top": "0"]),
            ControlRequest(command: "processes", options: ["sort": "disk"]),
            ControlRequest(command: "processes", arguments: ["extra"])
        ]
        for request in invalid {
            let response = await host.handle(request)
            XCTAssertFalse(response.ok, "\(request.command) \(request.arguments) \(request.options)")
            XCTAssertEqual(response.error?.code, .usage)
        }
        XCTAssertEqual(controllerReads, 0)
        XCTAssertEqual(processReads, 0)
        XCTAssertTrue(assertions.created.isEmpty)
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, before)
        XCTAssertFalse(controller.isActive)
    }

    func testProcessRequestHasNoTwoHundredRowCeilingAndPreservesMemoryRanking() async {
        var limit = 0
        let host = ControlHost(sampleProcesses: { count in
            limit = count
            return (1...250).map { ProcUsage(id: Int32($0), name: "fixture-\($0)", cpu: Double(251 - $0), mem: Double($0)) }
        })
        let response = await host.handle(ControlRequest(command: "processes", options: ["top": "250", "sort": "memory"]))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(limit, 500)
        let rows = response.result?["processes"]?.arrayValue
        XCTAssertEqual(rows?.count, 250)
        XCTAssertEqual(rows?.first?["pid"], .int(250))
        XCTAssertEqual(rows?.last?["pid"], .int(1))
    }
}
