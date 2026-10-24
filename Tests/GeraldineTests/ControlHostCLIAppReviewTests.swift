import Foundation
import IOKit.pwr_mgt
import XCTest
import GeraldineControl
@testable import Geraldine

/// Reuses the socket suite's fixture-root setting. The parent registers this
/// root before verification; each test removes only its unique child directory.
enum AppReviewFixtureRoot {
    static func create() throws -> URL {
        guard let parent = ProcessInfo.processInfo.environment["GERALDINE_CONTROL_TEST_ROOT"], !parent.isEmpty else {
            throw XCTSkip("Set GERALDINE_CONTROL_TEST_ROOT to the registered verification fixture root.")
        }
        let root = URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent("gapp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }
}

private struct AppReviewCLIResult: Sendable {
    let exitCode: Int32
    let response: ControlResponse
}

@MainActor
final class ControlHostCLIAppReviewTests: XCTestCase {
    func testBuiltCLIUsesRealHostForActiveSettingsPersistenceAndReadback() async throws {
        guard let binary = ProcessInfo.processInfo.environment["GERALDINE_CLI_BINARY"],
              FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("Set GERALDINE_CLI_BINARY to the built geraldine executable.")
        }
        let root = try AppReviewFixtureRoot.create()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ControlHostCLIAppReviewTests.\(UUID().uuidString)"
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
        defer { host.stop() }
        let socket = root.appendingPathComponent("c.sock")
        let server = ControlServer(socketURL: socket) { request in await host.handle(request) }
        try server.start()
        defer { server.stop() }

        let on = try await Self.runCLI(binary: binary, socket: socket, arguments: ["awake", "on", "--indefinitely"])
        XCTAssertEqual(on.exitCode, 0)
        XCTAssertTrue(on.response.ok)
        XCTAssertEqual(on.response.command, "awake")
        XCTAssertEqual(on.response.protocolVersion, ControlProtocol.version)
        XCTAssertEqual(on.response.schemaVersion, ControlProtocol.schemaVersion)
        XCTAssertEqual(on.response.result?["active"], .bool(true))
        XCTAssertEqual(on.response.result?["activeUntil"], .null)
        XCTAssertEqual(on.response.result?["assertions"]?["systemSleepPrevented"], .bool(true))
        XCTAssertEqual(on.response.result?["assertions"]?["displaySleepPrevented"], .bool(true))
        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(idle.hasScheduledTimer)
        let session = controller.expirationSessionToken
        let systemID = try XCTUnwrap(assertions.id(for: kIOPMAssertionTypeNoIdleSleep as String))
        let displayID = try XCTUnwrap(assertions.id(for: kIOPMAssertionTypePreventUserIdleDisplaySleep as String))

        for allowed in [true, false] {
            let rawValue = allowed ? "true" : "false"
            let changed = try await Self.runCLI(binary: binary, socket: socket,
                                                arguments: ["settings", "set", "keepAwake.allowDisplaySleep", rawValue])
            XCTAssertEqual(changed.exitCode, 0)
            XCTAssertTrue(changed.response.ok)
            XCTAssertEqual(changed.response.result?["previousValue"], .bool(!allowed))
            XCTAssertEqual(changed.response.result?["value"], .bool(allowed))
            XCTAssertEqual(defaults.bool(forKey: "keepAwake.allowDisplaySleep"), allowed)
            let persisted = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(persisted.persistentDomain(forName: suite)?["keepAwake.allowDisplaySleep"] as? Bool, allowed)
            XCTAssertEqual(controller.allowDisplaySleep, allowed)
            XCTAssertTrue(controller.isActive)
            XCTAssertEqual(controller.expirationSessionToken, session)
            XCTAssertNil(controller.activeUntil)
            XCTAssertEqual(assertions.id(for: kIOPMAssertionTypeNoIdleSleep as String), systemID)
            XCTAssertEqual(assertions.snapshot.displaySleep, !allowed)
            XCTAssertTrue(idle.hasScheduledTimer)

            let readback = try await Self.runCLI(binary: binary, socket: socket,
                                                 arguments: ["settings", "get", "keepAwake.allowDisplaySleep"])
            XCTAssertEqual(readback.exitCode, 0)
            XCTAssertTrue(readback.response.ok)
            XCTAssertEqual(readback.response.result?["value"], .bool(allowed))
        }
        let replacementDisplayID = try XCTUnwrap(assertions.id(for: kIOPMAssertionTypePreventUserIdleDisplaySleep as String))
        XCTAssertNotEqual(replacementDisplayID, displayID)
        XCTAssertEqual(assertions.created.count, 3)
        XCTAssertEqual(assertions.released, [displayID])

        let beforeMalformed = defaults.persistentDomain(forName: suite) as NSDictionary?
        let malformed = try await Self.runCLI(binary: binary, socket: socket, arguments: ["awake", "off", "extra"])
        XCTAssertEqual(malformed.exitCode, 2)
        XCTAssertFalse(malformed.response.ok)
        XCTAssertEqual(malformed.response.error?.code, .usage)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.expirationSessionToken, session)
        XCTAssertEqual(assertions.created.count, 3)
        XCTAssertEqual(assertions.released, [displayID])
        XCTAssertEqual(defaults.persistentDomain(forName: suite) as NSDictionary?, beforeMalformed)

        let off = try await Self.runCLI(binary: binary, socket: socket, arguments: ["awake", "off"])
        XCTAssertEqual(off.exitCode, 0)
        XCTAssertTrue(off.response.ok)
        XCTAssertEqual(off.response.result?["active"], .bool(false))
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(assertions.held.isEmpty)
        XCTAssertEqual(assertions.released, [displayID, systemID, replacementDisplayID])
        XCTAssertFalse(idle.hasScheduledTimer)
        XCTAssertEqual(pulses, 0)
    }

    /// The host handles requests on MainActor. Waiting for the CLI process on
    /// that actor would deadlock the socket response, so all blocking I/O lives here.
    nonisolated private static func runCLI(binary: String, socket: URL, arguments: [String]) async throws -> AppReviewCLIResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["--json", "--socket", socket.path] + arguments
            process.currentDirectoryURL = socket.deletingLastPathComponent()
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return AppReviewCLIResult(exitCode: process.terminationStatus,
                                      response: try JSONDecoder().decode(ControlResponse.self, from: data))
        }.value
    }
}
