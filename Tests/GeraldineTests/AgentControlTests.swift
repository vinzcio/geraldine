import XCTest
import GeraldineControl

final class AgentControlTests: XCTestCase {
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outText = ""
        private var errText = ""
        var isTTY = false

        var io: CommandLineIO {
            CommandLineIO(
                out: { [weak self] text in self?.append(text, toError: false) },
                err: { [weak self] text in self?.append(text, toError: true) },
                isTTY: isTTY
            )
        }

        var out: String { lock.withLock { outText } }
        var err: String { lock.withLock { errText } }

        private func append(_ text: String, toError: Bool) {
            lock.lock()
            if toError { errText += text } else { outText += text }
            lock.unlock()
        }
    }

    /// Unix socket paths are capped at ~104 bytes, and a full temporary-directory
    /// path with a UUID already exceeds that on macOS. Keep the test socket short
    /// and remove the whole directory in teardown.
    private func temporarySocket() -> URL {
        URL(fileURLWithPath: "/private/tmp/geraldine-control-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("c.sock")
    }

    private func makeServer(
        at socket: URL,
        handler: @escaping ControlServer.Handler
    ) throws -> ControlServer {
        let server = ControlServer(socketURL: socket, handler: handler)
        try server.start()
        return server
    }

    func testRequestEnvelopeRoundTrips() throws {
        let request = ControlRequest(command: "status")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(request)
        XCTAssertNoThrow(try JSONDecoder().decode(ControlRequest.self, from: data))
    }

    // MARK: - Wire protocol

    func testUnixSocketRoundTripAndPermissions() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let server = try makeServer(at: socket) { request in
            ControlResponse.success(
                for: request,
                text: ["hello"],
                result: .object(["echo": .string(request.command)])
            )
        }
        defer { server.stop() }

        let directory = try FileManager.default.attributesOfItem(atPath: socket.deletingLastPathComponent().path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let file = try FileManager.default.attributesOfItem(atPath: socket.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let response = try ControlClient(socketURL: socket)
            .send(ControlRequest(command: "status"), timeout: 2)
        XCTAssertTrue(response.ok, "code=\(String(describing: response.error?.code)) message=\(response.error?.message ?? "none") hint=\(response.error?.hint ?? "none")")
        XCTAssertEqual(response.text, ["hello"])
        XCTAssertEqual(response.result?["echo"]?.stringValue, "status")
        XCTAssertEqual(response.protocolVersion, ControlProtocol.version)
        XCTAssertEqual(response.schemaVersion, ControlProtocol.schemaVersion)

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
    }

    func testSecondServerCannotStealALiveSocket() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let first = try makeServer(at: socket) { request in
            ControlResponse.success(for: request)
        }
        defer { first.stop() }

        let second = ControlServer(socketURL: socket) { request in
            ControlResponse.success(for: request)
        }
        XCTAssertThrowsError(try second.start()) { error in
            guard case ControlServerError.socketInUse = error else {
                return XCTFail("Expected socketInUse, got \(error)")
            }
        }
    }

    func testStaleSocketFileIsReplaced() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: socket.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: socket)

        let server = try makeServer(at: socket) { request in
            ControlResponse.success(for: request)
        }
        defer { server.stop() }
        XCTAssertTrue(server.isRunning)
        XCTAssertNoThrow(try ControlClient(socketURL: socket)
            .send(ControlRequest(command: "status"), timeout: 2))
    }

    func testProtocolVersionMismatchIsRejected() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let server = try makeServer(at: socket) { request in
            ControlResponse.success(for: request)
        }
        defer { server.stop() }

        let response = try ControlClient(socketURL: socket).send(
            ControlRequest(command: "status", protocolVersion: 99),
            timeout: 2
        )
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unsupported)
        XCTAssertEqual(response.error?.exitCode, 3)
    }

    // MARK: - CLI surface

    func testHelpIsAvailableWithoutAnApp() {
        let box = OutputBox()
        let code = GeraldineCommandLine.run(arguments: ["geraldine", "--help"], environment: [:], io: box.io)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(box.out.contains("geraldine"))
        XCTAssertTrue(box.err.isEmpty)
    }

    func testEveryCatalogCommandHasHelp() {
        for command in CommandCatalog.commands {
            let box = OutputBox()
            let code = GeraldineCommandLine.run(
                arguments: ["geraldine", command.name, "--help"],
                environment: [:],
                io: box.io
            )
            XCTAssertEqual(code, 0, "\(command.name) --help failed")
            XCTAssertTrue(box.out.contains(command.name), "\(command.name) help is missing its name")
        }
    }

    func testCommandsJSONCarriesSchemaAndCatalog() throws {
        let box = OutputBox()
        let code = GeraldineCommandLine.run(
            arguments: ["geraldine", "commands", "--json"],
            environment: [:],
            io: box.io
        )
        XCTAssertEqual(code, 0)
        let data = try XCTUnwrap(box.out.data(using: .utf8))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let object = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, ControlProtocol.schemaVersion)
        let commands = try XCTUnwrap(object["commands"] as? [[String: Any]])
        let names = Set(commands.compactMap { $0["name"] as? String })
        for required in ["status", "awake", "stay-active", "settings", "stats", "doctor", "commands"] {
            XCTAssertTrue(names.contains(required), "missing \(required)")
        }
        for command in commands {
            XCTAssertNotNil(command["needsRunningApp"] as? Bool)
            XCTAssertNotNil(command["sideEffects"] as? [String])
        }
    }

    func testJSONUsageFailuresGoToStderr() throws {
        let box = OutputBox()
        let code = GeraldineCommandLine.run(
            arguments: ["geraldine", "--json", "not-a-command"],
            environment: [:],
            io: box.io
        )
        XCTAssertEqual(code, 2)
        XCTAssertTrue(box.out.isEmpty)
        let data = try XCTUnwrap(box.err.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "usage")
        XCTAssertNotNil(object["schemaVersion"] as? Int)
    }

    func testUnavailableAppExitCodeAndHint() throws {
        let box = OutputBox()
        let socket = temporarySocket()
        let code = GeraldineCommandLine.run(
            arguments: ["geraldine", "--json", "--socket", socket.path, "permissions"],
            environment: [:],
            io: box.io
        )
        XCTAssertEqual(code, 3)
        let data = try XCTUnwrap(box.err.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? String, "notRunning")
        XCTAssertNotNil((object["error"] as? [String: Any])?["hint"] as? String)
    }

    func testCLIRoundTripAgainstInProcessServer() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let server = try makeServer(at: socket) { request in
            ControlResponse.success(
                for: request,
                text: ["Geraldine is awake."],
                result: .object(["active": .bool(true)])
            )
        }
        defer { server.stop() }

        let box = OutputBox()
        let code = GeraldineCommandLine.run(
            arguments: ["geraldine", "--json", "--socket", socket.path, "status"],
            environment: [:],
            io: box.io
        )
        XCTAssertEqual(code, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(box.out.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual((object["result"] as? [String: Any])?["active"] as? Bool, true)
        XCTAssertEqual(object["command"] as? String, "status")
    }

    // MARK: - Latency

    func testInProcessRoundTripStaysUnderFiftyMilliseconds() throws {
        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let server = try makeServer(at: socket) { request in
            ControlResponse.success(for: request, text: ["ok"], result: .object(["ok": .bool(true)]))
        }
        defer { server.stop() }

        let box = OutputBox()
        let client = ControlClient(socketURL: socket)
        _ = try client.send(ControlRequest(command: "status"), timeout: 2)

        var samples: [TimeInterval] = []
        for _ in 0..<25 {
            let start = Date()
            let code = GeraldineCommandLine.run(
                arguments: ["geraldine", "--json", "--socket", socket.path, "status"],
                environment: [:],
                io: box.io
            )
            samples.append(Date().timeIntervalSince(start))
            XCTAssertEqual(code, 0)
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        XCTAssertLessThan(p95, 0.050, "p95 in-process CLI round trip was \(p95 * 1000) ms")
    }

    func testBuiltCLIStartsWithSubFiftyMillisecondMedian() throws {
        guard let binary = ProcessInfo.processInfo.environment["GERALDINE_CLI_BINARY"],
              FileManager.default.isExecutableFile(atPath: binary) else {
            throw XCTSkip("Set GERALDINE_CLI_BINARY to the built geraldine executable.")
        }

        let socket = temporarySocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let server = try makeServer(at: socket) { request in
            ControlResponse.success(for: request, text: ["ok"], result: .object(["ok": .bool(true)]))
        }
        defer { server.stop() }

        // `Process.waitUntilExit` polls on a run loop and adds ~60 ms in
        // xctest, which would hide the real start-up cost. posix_spawn +
        // waitpid measures the same start-to-exit boundary without that noise.
        func measure() throws -> TimeInterval {
            var argv: [UnsafeMutablePointer<CChar>?] = (
                [binary, "--json", "--socket", socket.path, "status"]
            ).map { strdup($0) }
            argv.append(nil)
            defer { for pointer in argv { free(pointer) } }

            var pid: pid_t = 0
            let start = Date()
            let spawned = posix_spawn(&pid, binary, nil, nil, &argv, environ)
            XCTAssertEqual(spawned, 0)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(status, 0)
            return elapsed
        }

        _ = try measure()
        var samples = try (0..<15).map { _ in try measure() }
        samples.sort()
        let median = samples[samples.count / 2]
        XCTAssertLessThan(median, 0.050, "median real CLI start-to-exit was \(median * 1000) ms")
    }

    // MARK: - Catalog and preferences

    func testBackwardCompatiblePreferenceKeysRemain() {
        for key in [
            "keepAwake.simulateIdleActivity",
            "keepAwake.defaultDuration",
            "keepAwake.idleActivityDelayMinutes",
            "keepAwake.allowDisplaySleep"
        ] {
            XCTAssertNotNil(SettingsCatalog.definition(for: key), "missing \(key)")
        }
    }

    func testOfflineSettingsReaderUsesDefaultsAndNeverInventsRunningValues() {
        let suite = "com.vincent.geraldine.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let reader = SettingsReader(defaults: defaults, appRunning: false)
        let duration = SettingsCatalog.definition(for: "keepAwake.defaultDuration")!
        XCTAssertEqual(reader.value(for: duration), .string("oneHour"))
        XCTAssertNil(reader.value(for: SettingsCatalog.definition(for: "geraldine.aiUsage.connected")!))
    }
}
