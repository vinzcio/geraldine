import XCTest
import Darwin
@testable import GeraldineControl

final class AgentControlRound2Tests: XCTestCase {
    private var root: URL!
    private var socketURL: URL { root.appendingPathComponent("c.sock") }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = ""
        private var stderr = ""
        var out: String { lock.withLock { stdout } }
        var err: String { lock.withLock { stderr } }
        var io: CommandLineIO {
            CommandLineIO(out: { text in self.lock.withLock { self.stdout += text } },
                          err: { text in self.lock.withLock { self.stderr += text } }, isTTY: false)
        }
    }

    /// Cancellation can either release a cooperative handler, or leave it
    /// suspended until the test releases it to model an already-started action.
    private final class HandlerGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private let releaseOnCancel: Bool

        init(releaseOnCancel: Bool = true) { self.releaseOnCancel = releaseOnCancel }

        func suspend() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resume = lock.withLock {
                        if released { return true }
                        self.continuation = continuation
                        return false
                    }
                    entered.signal()
                    if resume { continuation.resume() }
                }
            } onCancel: {
                self.cancelled.signal()
                if self.releaseOnCancel { self.release() }
            }
            returned.signal()
        }

        func release() {
            let continuation = lock.withLock {
                released = true
                let pending = self.continuation
                self.continuation = nil
                return pending
            }
            continuation?.resume()
        }
    }

    override func setUpWithError() throws {
        let parent = ProcessInfo.processInfo.environment["GERALDINE_CONTROL_TEST_ROOT"] ?? "/private/tmp"
        root = URL(fileURLWithPath: parent).appendingPathComponent("gc2-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func isolatedDependencies() -> CommandLineDependencies {
        CommandLineDependencies(
            send: { _, _, _ in XCTFail("Unexpected request"); throw ControlClientError.unavailable(ENOENT) },
            isAppRunning: { XCTFail("Unexpected installed-process lookup"); return false },
            launchApp: { _ in XCTFail("Unexpected launch") },
            openURL: { _, _ in XCTFail("Unexpected URL") },
            executableURL: { nil },
            sleep: { _ in XCTFail("Unexpected sleep") }
        )
    }

    private func decode(_ output: String) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: Data(output.utf8))
    }

    private func connectAndSend(_ request: ControlRequest) throws -> Int32 {
        let descriptor = ControlSocketAddress.connect(path: socketURL.path, timeout: 2)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        XCTAssertEqual(fcntl(descriptor, F_SETFL, 0), 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        XCTAssertEqual(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if sent < 0, errno == EINTR { continue }
            guard sent > 0 else { Darwin.close(descriptor); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            offset += sent
        }
        return descriptor
    }

    func testProcessLookupFindsCurrentUserProcessAndRejectsMissingName() throws {
        // Independently query this PID to get the kernel's possibly truncated
        // command name; no installed-app lookup or app execution is involved.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        XCTAssertEqual(sysctl(&mib, 4, &process, &size, nil, 0), 0)
        let name = withUnsafePointer(to: process.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(ProcessLookup.isRunning(named: name))
        XCTAssertFalse(ProcessLookup.isRunning(named: "none-\(UUID().uuidString.prefix(8))"))
    }

    func testFoundationJSONPreservesNumericBooleansIntegersAndDoubles() throws {
        let data = Data("[0,1,2,true,false,9223372036854775807,-9223372036854775808,1.25]".utf8)
        let expected = JSONValue.array([.int(0), .int(1), .int(2), .bool(true), .bool(false), .int(Int.max), .int(Int.min), .double(1.25)])
        let value = JSONValue.from(try JSONSerialization.jsonObject(with: data))
        XCTAssertEqual(value, expected)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), expected)
        XCTAssertEqual(JSONValue.from(NSNumber(value: Int64.max)), .int(Int.max))
        XCTAssertEqual(JSONValue.from(NSNumber(value: Int64.min)), .int(Int.min))
        XCTAssertEqual(JSONValue.from(["zero": 0, "one": 1]), .object(["zero": .int(0), "one": .int(1)]))
        XCTAssertNotNil(JSONValue.encodeLine(JSONValue.from(NSNumber(value: UInt64.max))))
    }

    func testBareCommandDispatchesStatusAndPreservesJSONErrorStream() throws {
        for json in [false, true] {
            var dependencies = isolatedDependencies()
            dependencies.send = { request, url, timeout in
                XCTAssertEqual(request.command, "status")
                XCTAssertTrue(request.arguments.isEmpty)
                XCTAssertEqual(url, self.socketURL)
                XCTAssertNil(timeout)
                return .success(for: request, text: ["fixture status"], result: .bool(true))
            }
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--socket", socketURL.path] + (json ? ["--json"] : []), environment: [:], io: output.io, dependencies: dependencies), 0)
            XCTAssertTrue(output.err.isEmpty)
            if json { XCTAssertEqual(try decode(output.out).command, "status") }
            else { XCTAssertEqual(output.out, "fixture status\n") }
        }
        var missing = isolatedDependencies()
        missing.send = { _, _, _ in throw ControlClientError.unavailable(ENOENT) }
        let output = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--json", "--socket", socketURL.path], environment: [:], io: output.io, dependencies: missing), 3)
        XCTAssertTrue(output.out.isEmpty)
        XCTAssertEqual(try decode(output.err).command, "status")
    }

    func testCallerSelectedNumericOptionsDispatchWithoutInventedCaps() throws {
        let cases: [([String], String, String)] = [
            (["awake", "on", "--for", "0.1s"], "duration", "1"),
            (["awake", "toggle", "--for", "1.01s"], "duration", "2"),
            (["awake", "on", "--for", "31d"], "duration", "2678400"),
            (["processes", "--top", "201"], "top", "201"),
            (["processes", "--top", String(Int.max / 2)], "top", String(Int.max / 2)),
            (["large-files", "scan", "--min-size", String(UInt64.max / 1_000_000)], "minSizeMB", String(UInt64.max / 1_000_000))
        ]
        for (arguments, key, expected) in cases {
            var dependencies = isolatedDependencies()
            dependencies.send = { request, _, timeout in
                XCTAssertEqual(request.options[key], expected)
                XCTAssertNil(timeout)
                return .success(for: request)
            }
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--json", "--socket", socketURL.path] + arguments, environment: [:], io: Output().io, dependencies: dependencies), 0)
        }
        let invalid = [
            ["processes", "--top", String(Int.max)],
            ["large-files", "scan", "--min-size", String(UInt64.max / 1_000_000 + 1)],
            ["awake", "on", "--for", "9223372036854775808s"]
        ]
        for arguments in invalid {
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--json"] + arguments, environment: [:], io: output.io, dependencies: isolatedDependencies()), 2)
            XCTAssertEqual(try decode(output.err).error?.code, .usage)
        }
    }

    func testWatchRequiresAndUsesExplicitIntervalWithOneEnvelopePerSample() throws {
        for extra in [[], ["0"], ["-1"], ["nan"], ["inf"], ["1e100"], ["1", "--watch", "2"]] {
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "stats", "--watch"] + extra + ["--json"], environment: [:], io: output.io, dependencies: isolatedDependencies()), 2)
            XCTAssertTrue(output.out.isEmpty)
        }
        var count = 0
        var intervals: [TimeInterval] = []
        var dependencies = isolatedDependencies()
        dependencies.send = { request, _, timeout in
            count += 1
            XCTAssertEqual(request.arguments, ["cpu"])
            XCTAssertNil(timeout)
            return count < 3 ? .success(for: request, result: .int(count)) : .failure(for: request, code: .failed, message: "fixture stopped")
        }
        dependencies.sleep = { intervals.append($0) }
        let output = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "stats", "--watch", "0.125", "cpu", "--json"], environment: [:], io: output.io, dependencies: dependencies), 1)
        XCTAssertEqual(intervals, [0.125, 0.125])
        let samples = try output.out.split(separator: "\n").map { try decode(String($0)) }
        XCTAssertEqual(samples.map(\.result), [.int(1), .int(2)])
        XCTAssertEqual(try decode(output.err).error?.message, "fixture stopped")
    }

    func testLaunchRetriesOnceWithoutSleepIncludingSettingsAndDoctor() throws {
        for arguments in [["status"], ["settings", "list"], ["doctor"]] {
            var attempts = 0
            var launches = 0
            var dependencies = isolatedDependencies()
            dependencies.isAppRunning = { false }
            dependencies.send = { request, _, timeout in
                XCTAssertNil(timeout)
                attempts += 1
                if attempts == 1 { throw ControlClientError.unavailable(ENOENT) }
                return .success(for: request, result: .object(["fixture": .bool(true)]))
            }
            dependencies.launchApp = { timeout in XCTAssertNil(timeout); launches += 1 }
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--json", "--launch"] + arguments, environment: [:], io: output.io, dependencies: dependencies), 0)
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(launches, 1)
            XCTAssertEqual(try decode(output.out).result?["fixture"], .bool(true))
        }
    }

    func testLaunchNotReadyIsUnconfirmedAndDoesNotTryAnotherTransport() throws {
        var attempts = 0
        var launches = 0
        var dependencies = isolatedDependencies()
        dependencies.isAppRunning = { false }
        dependencies.send = { _, _, _ in attempts += 1; throw ControlClientError.unavailable(ECONNREFUSED) }
        dependencies.launchApp = { _ in launches += 1 }
        let output = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "awake", "toggle", "--json", "--launch"], environment: [:], io: output.io, dependencies: dependencies), 3)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(output.out.isEmpty)
        XCTAssertTrue(try decode(output.err).error?.hint?.contains("did not return a confirmed result") == true)
    }

    func testExplicitTimeoutIsNotResetAcrossLaunchRetry() throws {
        var attempts = 0
        var dependencies = isolatedDependencies()
        dependencies.isAppRunning = { false }
        dependencies.send = { _, _, timeout in
            attempts += 1
            XCTAssertLessThanOrEqual(timeout ?? .infinity, 0.01)
            throw ControlClientError.unavailable(ENOENT)
        }
        dependencies.launchApp = { timeout in
            XCTAssertGreaterThan(timeout ?? 0, 0)
            Thread.sleep(forTimeInterval: 0.02) // a fixture launch slower than this caller's budget
        }
        let output = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "status", "--json", "--launch", "--timeout", "0.01"], environment: [:], io: output.io, dependencies: dependencies), 1)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(try decode(output.err).error?.code, .failed)
    }

    func testDefaultClientHasNoImplicitDeadline() throws {
        let server = ControlServer(socketURL: socketURL) { .success(for: $0, result: .string("no deadline")) }
        try server.start()
        defer { server.stop() }
        var tick = 0.0
        let client = ControlClient(socketURL: socketURL, now: { tick += 1_000; return Date(timeIntervalSince1970: tick) })
        XCTAssertEqual(try client.send(ControlRequest(command: "status")).result, .string("no deadline"))
        XCTAssertEqual(tick, 0, "No deadline means no clock-dependent expiry")
        XCTAssertEqual(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status"), timeout: 1e100).result, .string("no deadline"))
        var dependencies = isolatedDependencies()
        dependencies.send = { request, _, timeout in
            XCTAssertEqual(timeout, 1e100)
            return .success(for: request)
        }
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "status", "--json", "--timeout=1e100"], environment: [:], io: Output().io, dependencies: dependencies), 0)
    }

    func testClientDisconnectCancelsSuspendedHandler() throws {
        let gate = HandlerGate()
        let server = ControlServer(socketURL: socketURL) { request in
            await gate.suspend()
            return .success(for: request)
        }
        try server.start()
        defer { gate.release(); server.stop() }
        let client = try connectAndSend(ControlRequest(command: "usage"))
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        Darwin.close(client)
        XCTAssertEqual(gate.cancelled.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(gate.returned.wait(timeout: .now() + 2), .success)
    }

    func testApprovedDefaultDirectoryUpgradeIsNarrowAndIdempotent() throws {
        let directory = root.appendingPathComponent("Geraldine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        var before = stat()
        XCTAssertEqual(lstat(directory.path, &before), 0)
        let endpoint = directory.appendingPathComponent("c.sock")
        let server = ControlServer(socketURL: endpoint, defaultDirectoryURL: directory) { .success(for: $0) }
        try server.start()
        defer { server.stop() }
        var after = stat()
        XCTAssertEqual(lstat(directory.path, &after), 0)
        XCTAssertEqual(after.st_mode & 0o7777, 0o700)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_uid, before.st_uid)
        XCTAssertTrue(try ControlClient(socketURL: endpoint).send(ControlRequest(command: "status"), timeout: 2).ok)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))
        try server.start()
        XCTAssertEqual(lstat(directory.path, &after), 0)
        XCTAssertEqual(after.st_mode & 0o7777, 0o700)
        XCTAssertTrue(try ControlClient(socketURL: endpoint).send(ControlRequest(command: "status"), timeout: 2).ok)
    }

    func testDefaultDirectoryUpgradePreservesCustomDirectoriesAndOtherModes() throws {
        let defaultDirectory = root.appendingPathComponent("Geraldine", isDirectory: true)
        let customDirectory = root.appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let custom = ControlServer(socketURL: customDirectory.appendingPathComponent("c.sock"), defaultDirectoryURL: defaultDirectory) { .success(for: $0) }
        XCTAssertThrowsError(try custom.start())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: customDirectory.path)[.posixPermissions] as? Int, 0o755)
        try FileManager.default.createDirectory(at: defaultDirectory, withIntermediateDirectories: true)
        for mode in [0o750, 0o777] {
            XCTAssertEqual(chmod(defaultDirectory.path, mode_t(mode)), 0)
            let server = ControlServer(socketURL: defaultDirectory.appendingPathComponent("c.sock"), defaultDirectoryURL: defaultDirectory) { .success(for: $0) }
            XCTAssertThrowsError(try server.start())
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: defaultDirectory.path)[.posixPermissions] as? Int, mode)
        }
    }

    func testDefaultDirectoryUpgradeNeverFollowsASymlink() throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("Geraldine", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let server = ControlServer(socketURL: link.appendingPathComponent("c.sock"), defaultDirectoryURL: link) { .success(for: $0) }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o755)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testStopCancelsHandlerClosesConnectionAndRemovesSocket() throws {
        let gate = HandlerGate()
        let server = ControlServer(socketURL: socketURL) { request in
            await gate.suspend()
            return .success(for: request)
        }
        try server.start()
        defer { gate.release(); server.stop() }
        let client = try connectAndSend(ControlRequest(command: "usage"))
        defer { Darwin.close(client) }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertEqual(gate.cancelled.wait(timeout: .now() + 2), .success)
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(Darwin.recv(client, &byte, 1, 0), 0)
    }

    func testClientTimeoutClosesConnectionAndCancelsOnlyItsHandler() throws {
        let gate = HandlerGate()
        let server = ControlServer(socketURL: socketURL) { request in
            if request.command == "usage" { await gate.suspend() }
            return .success(for: request)
        }
        try server.start()
        defer { gate.release(); server.stop() }
        XCTAssertThrowsError(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "usage"), timeout: 0.2)) {
            XCTAssertEqual($0 as? ControlClientError, .timedOut)
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(gate.cancelled.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status"), timeout: 2).ok)
    }

    func testRestartCannotSendAnOldHandlerResultToANewConnection() throws {
        let old = HandlerGate(releaseOnCancel: false)
        let new = HandlerGate()
        let server = ControlServer(socketURL: socketURL) { request in
            let gate = request.arguments == ["old"] ? old : new
            await gate.suspend()
            return .success(for: request, result: .string(request.arguments.first ?? ""))
        }
        try server.start()
        defer { old.release(); new.release(); server.stop() }
        let oldClient = try connectAndSend(ControlRequest(command: "status", arguments: ["old"]))
        defer { Darwin.close(oldClient) }
        XCTAssertEqual(old.entered.wait(timeout: .now() + 2), .success)
        server.stop()
        XCTAssertEqual(old.cancelled.wait(timeout: .now() + 2), .success)
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(Darwin.recv(oldClient, &byte, 1, 0), 0)
        try server.start()
        let request = ControlRequest(command: "status", arguments: ["new"])
        let newClient = try connectAndSend(request)
        defer { Darwin.close(newClient) }
        XCTAssertEqual(new.entered.wait(timeout: .now() + 2), .success)
        old.release()
        XCTAssertEqual(old.returned.wait(timeout: .now() + 2), .success)
        new.release()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(newClient, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(count, 0)
        let response = try decode(String(decoding: buffer.prefix(max(0, count)), as: UTF8.self))
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.result, .string("new"))
    }

    private var appIdentity: [String: JSONValue] {
        ["version": .string("9.2"), "build": .string("92"), "commit": .string(String(repeating: "a", count: 40)),
         "shortCommit": .string(String(repeating: "a", count: 12)), "isDirty": .bool(false),
         "builtAt": .string("2026-10-23T00:00:00Z"), "configuration": .string("release")]
    }

    private func fakeBundledHelper() throws -> URL {
        let contents = root.appendingPathComponent("Fixture.app/Contents")
        let helper = contents.appendingPathComponent("Helpers/geraldine")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: helper)
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        let plist: [String: Any] = [
            "CFBundleIdentifier": SettingsCatalog.suiteName, "CFBundleShortVersionString": "9.2", "CFBundleVersion": "92",
            "GeraldineBuildCommit": String(repeating: "a", count: 40), "GeraldineBuildCommitShort": String(repeating: "a", count: 12),
            "GeraldineBuildDirty": false, "GeraldineBuildDate": "2026-10-23T00:00:00Z", "GeraldineBuildConfiguration": "release"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return helper
    }

    func testDoctorResolvesPATHSymlinkAndComparesActualBundleBuildIdentity() throws {
        let helper = try fakeBundledHelper()
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("geraldine")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
        for mismatch in [false, true] {
            var identity = appIdentity
            if mismatch { identity["commit"] = .string(String(repeating: "b", count: 40)) }
            var dependencies = isolatedDependencies()
            dependencies.executableURL = { link }
            dependencies.installedAppURL = { self.root.appendingPathComponent("Fixture.app") }
            dependencies.send = { request, _, _ in
                .success(for: request, result: .object(["app": .object(identity), "checks": .array([
                    .object(["name": .string("CLI on PATH"), "status": .string("fail"), "detail": .string("app-process PATH is irrelevant")])
                ])]))
            }
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "doctor", "--json", "--socket", socketURL.path], environment: ["PATH": bin.path], io: output.io, dependencies: dependencies), mismatch ? 1 : 0)
            let result = try decode(mismatch ? output.err : output.out).result
            XCTAssertEqual(result?["cliAppIdentityMatch"], .string(mismatch ? "mismatch" : "match"))
            XCTAssertEqual(result?["appInstalled"], .bool(true))
            XCTAssertEqual(result?["cli"]?["currentHelperOnPATH"], .bool(true))
            XCTAssertEqual(result?["cli"]?["bundle"]?["version"], .string("9.2"))
            let pathChecks = result?["checks"]?.arrayValue?.filter { $0["name"] == .string("CLI on PATH") }
            XCTAssertEqual(pathChecks?.count, 1)
            XCTAssertEqual(pathChecks?.first?["status"], .string("ok"))
        }
    }

    func testDoctorReportsUnknownUnbundledIdentityAndMissingPATHTruthfully() throws {
        let helper = root.appendingPathComponent("GeraldineCLI")
        try Data("debug fixture".utf8).write(to: helper)
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        var dependencies = isolatedDependencies()
        dependencies.executableURL = { helper }
        dependencies.send = { request, _, _ in .success(for: request, result: .object(["app": .object(self.appIdentity)])) }
        let output = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "doctor", "--json", "--socket", socketURL.path], environment: ["PATH": self.root.appendingPathComponent("missing").path], io: output.io, dependencies: dependencies), 0)
        let result = try decode(output.out).result
        XCTAssertEqual(result?["cliAppIdentityMatch"], .string("unknown"))
        XCTAssertEqual(result?["cli"]?["bundle"], .null)
        XCTAssertEqual(result?["cli"]?["pathOnPATH"], .null)
        XCTAssertEqual(result?["appInstalled"], .bool(false))
    }

    func testCatalogCarriesTypedConditionalArgumentsAndNumericVersions() throws {
        let output = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "commands", "--json"], environment: [:], io: output.io, dependencies: isolatedDependencies()), 0)
        let result = try decode(output.out).result
        XCTAssertEqual(result?["protocolVersion"], .int(1))
        let commands = try XCTUnwrap(result?["commands"]?.arrayValue)
        for command in commands {
            let args = try XCTUnwrap(command["arguments"]?.arrayValue)
            XCTAssertTrue(args.contains { $0["name"] == .string("--timeout") && $0["type"] == .string("number") })
            XCTAssertTrue(args.contains { $0["name"] == .string("--json") && $0["required"] == .bool(false) })
        }
        let awake = try XCTUnwrap(commands.first { $0["name"] == .string("awake") })
        XCTAssertTrue(awake["arguments"]?.arrayValue?.contains { $0["name"] == .string("action") && $0["required"] == .bool(true) } == true)
        XCTAssertTrue(CommandCatalog.command(named: "usage")?.sideEffects.joined().contains("contact their providers") == true)
        XCTAssertTrue(CommandCatalog.command(named: "settings")?.summary.contains("offline") == true)
    }
}
