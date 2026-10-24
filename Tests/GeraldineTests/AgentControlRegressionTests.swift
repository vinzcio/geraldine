import XCTest
import Darwin
@testable import GeraldineControl

// Darwin's Swift overlay exposes the struct with this name but not an
// unambiguous callable overload. This is a read-only sigaction query.
@_silgen_name("sigaction")
private func inspectSignalAction(_ signal: Int32, _ action: UnsafePointer<sigaction>?, _ previous: UnsafeMutablePointer<sigaction>?) -> Int32

final class AgentControlRegressionTests: XCTestCase {
    private var root: URL!

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

    override func setUpWithError() throws {
        let parent = ProcessInfo.processInfo.environment["GERALDINE_CONTROL_TEST_ROOT"] ?? "/private/tmp"
        root = URL(fileURLWithPath: parent).appendingPathComponent("gcr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var socketURL: URL { root.appendingPathComponent("c.sock") }

    private func isolatedDependencies(source: URL? = nil) -> CommandLineDependencies {
        CommandLineDependencies(
            send: { _, _, _ in XCTFail("Unexpected control dispatch"); throw ControlClientError.unavailable(ENOENT) },
            isAppRunning: { XCTFail("Unexpected installed-app lookup"); return false },
            launchApp: { _ in XCTFail("Unexpected app launch") },
            openURL: { _, _ in XCTFail("Unexpected URL fallback") },
            executableURL: { source }
        )
    }

    private func response(_ text: String) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: Data(text.utf8))
    }

    private func fakeHelper(_ app: String) throws -> URL {
        let helper = root.appendingPathComponent("\(app).app/Contents/Helpers/geraldine")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fake \(app)".utf8).write(to: helper)
        XCTAssertEqual(chmod(helper.path, 0o755), 0)
        return helper
    }

    func testInstallerCreatesIdempotentSymlinkAndTracksBundleReplacement() throws {
        let source = try fakeHelper("First")
        let directory = root.appendingPathComponent("bin", isDirectory: true)
        let link = directory.appendingPathComponent("geraldine")
        let dependencies = isolatedDependencies(source: source)
        let arguments = ["geraldine", "install-cli", "--dir", directory.path, "--json"]
        let first = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: arguments, environment: ["PATH": directory.path], io: first.io, dependencies: dependencies), 0)
        XCTAssertTrue(first.err.isEmpty)
        XCTAssertEqual(try response(first.out).result?["onPath"], .bool(true))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), source.resolvingSymlinksInPath().path)
        var before = stat()
        XCTAssertEqual(lstat(link.path, &before), 0)
        let second = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: arguments, environment: [:], io: second.io, dependencies: dependencies), 0)
        var after = stat()
        XCTAssertEqual(lstat(link.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino, "An already correct link should be left alone")

        try Data("upgraded helper".utf8).write(to: source, options: .atomic)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "upgraded helper")
    }

    func testInstallerUpdatesBundledLinksAndPreservesUnrelatedDestinations() throws {
        let old = try fakeHelper("Old")
        let source = try fakeHelper("New")
        let directory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("geraldine")
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: old.path)
        let arguments = ["geraldine", "install-cli", "--dir", directory.path, "--json"]
        let dependencies = isolatedDependencies(source: source)
        let updated = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: arguments, environment: [:], io: updated.io, dependencies: dependencies), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: destination)

        try Data("unrelated executable".utf8).write(to: destination)
        let regular = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: arguments, environment: [:], io: regular.io, dependencies: dependencies), 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "unrelated executable")
        XCTAssertTrue(regular.out.isEmpty)
        try FileManager.default.removeItem(at: destination)

        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: "unrelated-script")
        let unrelated = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: arguments, environment: [:], io: unrelated.io, dependencies: dependencies), 1)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), "unrelated-script")
        XCTAssertEqual(try response(unrelated.err).error?.code, .failed)
    }

    func testMalformedGlobalArgumentsFailAsJSONBeforeAnyAction() throws {
        let cases: [[String]] = [
            ["awake", "on", "--socket"], ["awake", "off", "--socket", "--launch"],
            ["--socket="], ["--socket", ""], ["--timeout"], ["--timeout="],
            ["--timeout", "nan"], ["--timeout=inf"], ["--timeout=-inf"],
            ["--timeout=1e999"], ["--timeout=0"],
            ["--timeout=-1"], ["--timeout", "--launch"], ["--timeout=oops"]
        ]
        for arguments in cases {
            let output = Output()
            let code = GeraldineCommandLine.run(arguments: ["geraldine"] + arguments + ["--json"], environment: [:], io: output.io, dependencies: isolatedDependencies())
            XCTAssertEqual(code, 2, "\(arguments)")
            XCTAssertTrue(output.out.isEmpty, "\(arguments)")
            XCTAssertEqual(try response(output.err).error?.code, .usage, "\(arguments)")
        }
    }

    func testUnsupportedArgumentsFailBeforeAnyAction() throws {
        let cases: [[String]] = [
            ["commands", "extra"], ["usage", "--refresh", "extra"], ["usage", "--unknown"],
            ["stats", "cpu", "gpu"], ["stats", "cpu", "--unknown"], ["stats", "--watch"],
            ["open", "dashboard", "extra"], ["help", "status", "extra"], ["help", "unknown"],
            ["unknown", "--help"], ["--version", "extra"], ["install-cli", "--dir"],
            ["settings", "set", "calendar.customDateFormat", "a", "b"]
        ]
        for arguments in cases {
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--json"] + arguments, environment: [:], io: output.io, dependencies: isolatedDependencies()), 2, "\(arguments)")
            XCTAssertTrue(output.out.isEmpty)
            XCTAssertEqual(try response(output.err).error?.code, .usage)
        }
    }

    func testJSONHelpAndVersionUseTheEnvelope() throws {
        for arguments in [["--help"], ["help"], ["help", "status"], ["status", "--help"], ["--version"], ["-v"]] {
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--json"] + arguments, environment: [:], io: output.io, dependencies: isolatedDependencies()), 0)
            let envelope = try response(output.out)
            XCTAssertTrue(envelope.ok)
            XCTAssertEqual(envelope.schemaVersion, ControlProtocol.schemaVersion)
            XCTAssertNotNil(envelope.result)
            XCTAssertTrue(output.err.isEmpty)
        }
        for command in CommandCatalog.commands {
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", command.name, "--help", "--json"], environment: [:], io: output.io, dependencies: isolatedDependencies()), 0)
            XCTAssertEqual(try response(output.out).result?["topic"], command.name == "help" ? .null : .string(command.name))
        }
    }

    func testExplicitEndpointsNeverUseProductionFallbacks() throws {
        var dependencies = isolatedDependencies()
        dependencies.send = { _, _, _ in throw ControlClientError.unavailable(ENOENT) }
        for command in [["awake", "off"], ["awake", "toggle", "--launch"], ["settings", "get", "keepAwake.defaultDuration"], ["doctor"], ["status", "--launch"]] {
            for useEnvironment in [false, true] {
                let output = Output()
                let environment = useEnvironment ? [ControlEndpoint.environmentKey: socketURL.path] : [:]
                let options = useEnvironment ? [] : ["--socket", socketURL.path]
                XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "--json"] + options + command, environment: environment, io: output.io, dependencies: dependencies), 3)
                XCTAssertTrue(output.out.isEmpty)
                XCTAssertEqual(try response(output.err).error?.code, .notRunning)
            }
        }
        let empty = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "awake", "on", "--json"], environment: [ControlEndpoint.environmentKey: ""], io: empty.io, dependencies: isolatedDependencies()), 2)
    }

    func testAmbiguousTransportFailuresNeverRetryOrFallBack() throws {
        let failures: [(ControlClientError, Int32)] = [
            (.malformedResponse, 1), (.transportFailed(EPIPE), 1), (.timedOut, 1),
            (.unsupportedProtocol(99), 3), (.unsupportedSchema(99), 3), (.untrustedPeer, 4)
        ]
        for (failure, expectedCode) in failures {
            var dependencies = isolatedDependencies()
            dependencies.send = { _, _, _ in throw failure }
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "awake", "toggle", "--json", "--launch"], environment: [:], io: output.io, dependencies: dependencies), expectedCode)
            XCTAssertFalse(try response(output.err).ok)
            XCTAssertTrue(output.out.isEmpty)
        }
    }

    func testDefaultEndpointKeepsLegacyURLFallbackWithInjectedEffectsOnly() throws {
        var dependencies = isolatedDependencies()
        dependencies.send = { _, _, _ in throw ControlClientError.unavailable(ENOENT) }
        dependencies.isAppRunning = { true }
        var opened: [String] = []
        dependencies.openURL = { url, _ in opened.append(url) }
        let output = Output()
        XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "awake", "off", "--json"], environment: [:], io: output.io, dependencies: dependencies), 0)
        XCTAssertEqual(opened, ["geraldine:deactivate"])
        XCTAssertEqual(try response(output.out).result?["method"], .string("url"))
    }

    func testDoctorHasNoImplicitDeadlineAndHonorsExplicitTimeout() throws {
        for options in [[], ["--timeout", "2.5"]] {
            var dependencies = isolatedDependencies()
            dependencies.send = { request, _, timeout in
                if options.isEmpty { XCTAssertNil(timeout) }
                else {
                    XCTAssertGreaterThan(timeout ?? 0, 0)
                    XCTAssertLessThanOrEqual(timeout ?? .infinity, 2.5)
                }
                return .success(for: request)
            }
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "doctor", "--json"] + options, environment: [:], io: output.io, dependencies: dependencies), 0)
            XCTAssertTrue(try response(output.out).ok)
        }
    }

    func testRegularFilesAndSymlinksAtSocketPathArePreserved() throws {
        let bytes = Data("not a socket".utf8)
        try bytes.write(to: socketURL)
        let server = ControlServer(socketURL: socketURL) { .success(for: $0) }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try Data(contentsOf: socketURL), bytes)
        try FileManager.default.removeItem(at: socketURL)
        for target in [root.appendingPathComponent("missing").path, root.path] {
            try FileManager.default.createSymbolicLink(atPath: socketURL.path, withDestinationPath: target)
            XCTAssertThrowsError(try server.start())
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: socketURL.path), target)
            try FileManager.default.removeItem(at: socketURL)
        }
    }

    func testExistingParentPermissionsAndSymlinkAreNeverRepaired() throws {
        let parent = root.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let server = ControlServer(socketURL: parent.appendingPathComponent("c.sock")) { .success(for: $0) }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions] as? Int, 0o755)
        let link = root.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)
        let throughLink = ControlServer(socketURL: link.appendingPathComponent("c.sock")) { .success(for: $0) }
        XCTAssertThrowsError(try throughLink.start())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.path)
    }

    func testStopPreservesReplacementSocket() throws {
        let first = ControlServer(socketURL: socketURL) { .success(for: $0) }
        try first.start()
        defer { first.stop() }
        XCTAssertEqual(unlink(socketURL.path), 0)
        let replacement = ControlServer(socketURL: socketURL) { .success(for: $0, result: .string("replacement")) }
        try replacement.start()
        defer { replacement.stop() }
        first.stop()
        XCTAssertEqual(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status"), timeout: 2).result, .string("replacement"))
    }

    func testStopPreservesReplacementRegularFile() throws {
        let server = ControlServer(socketURL: socketURL) { .success(for: $0) }
        try server.start()
        XCTAssertEqual(unlink(socketURL.path), 0)
        try Data("replacement".utf8).write(to: socketURL)
        server.stop()
        XCTAssertEqual(try String(contentsOf: socketURL, encoding: .utf8), "replacement")
    }

    func testConcurrentStartStopCanRestartAndServe() throws {
        let server = ControlServer(socketURL: socketURL) { .success(for: $0) }
        defer { server.stop() }
        DispatchQueue.concurrentPerform(iterations: 20) { iteration in
            if iteration.isMultiple(of: 2) {
                do { try server.start() }
                catch { XCTFail("Concurrent start failed: \(error)") }
            }
            else { server.stop() }
        }
        try server.start()
        XCTAssertTrue(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status"), timeout: 2).ok)
    }

    func testConcurrentServersCannotStealAnInProgressStartup() throws {
        let first = ControlServer(socketURL: socketURL) { .success(for: $0) }
        let second = ControlServer(socketURL: socketURL) { .success(for: $0) }
        defer { first.stop(); second.stop() }
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            do { try (index == 0 ? first : second).start() }
            catch {
                guard case ControlServerError.socketInUse = error else {
                    return XCTFail("Unexpected startup error: \(error)")
                }
            }
        }
        XCTAssertNotEqual(first.isRunning, second.isRunning)
        XCTAssertTrue(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status"), timeout: 2).ok)
    }

    func testStopInterruptsAcceptedIdleConnections() throws {
        let server = ControlServer(socketURL: socketURL) { .success(for: $0) }
        try server.start()
        defer { server.stop() }
        let idle = fixtureConnection()
        XCTAssertGreaterThanOrEqual(idle, 0)
        defer { Darwin.close(idle) }
        XCTAssertTrue(writeAll(Data("{".utf8), to: idle))
        // A second completed request proves the accept loop passed the idle
        // connection; no sleep or timing guess is needed.
        XCTAssertTrue(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status"), timeout: 2).ok)
        server.stop()
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(Darwin.recv(idle, &byte, 1, 0), 0)
    }

    func testServerDoesNotChangeProcessSIGPIPEDisposition() throws {
        var before = sigaction()
        var after = sigaction()
        XCTAssertEqual(inspectSignalAction(SIGPIPE, nil, &before), 0)
        let server = ControlServer(socketURL: socketURL) { .success(for: $0) }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(inspectSignalAction(SIGPIPE, nil, &after), 0)
        XCTAssertEqual(withUnsafeBytes(of: before) { Data($0) }, withUnsafeBytes(of: after) { Data($0) })
    }

    func testClientRejectsUncorrelatedAndUnsupportedReplies() throws {
        let server = ControlServer(socketURL: socketURL) { request in
            var reply = ControlResponse.success(for: request)
            switch request.options["case"] {
            case "id": reply.id = "someone-else"
            case "command": reply.command = "awake"
            case "protocol": reply.protocolVersion = 99
            case "schema": reply.schemaVersion = 99
            case "error": reply.ok = false
            default: break
            }
            return reply
        }
        try server.start()
        defer { server.stop() }
        let cases: [(String, ControlClientError)] = [("id", .malformedResponse), ("command", .malformedResponse), ("protocol", .unsupportedProtocol(99)), ("schema", .unsupportedSchema(99)), ("error", .malformedResponse)]
        for (kind, expected) in cases {
            XCTAssertThrowsError(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status", options: ["case": kind]), timeout: 2)) {
                XCTAssertEqual($0 as? ControlClientError, expected)
            }
        }
    }

    func testClientInvalidTimeoutsDoNotTrapOrConnect() {
        for timeout in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertThrowsError(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status"), timeout: timeout)) {
                XCTAssertEqual($0 as? ControlClientError, .invalidTimeout)
            }
        }
    }

    func testLargeValidRequestAndResponseAreNotCapped() throws {
        let payload = String(repeating: "scan-data", count: 300_000)
        let server = ControlServer(socketURL: socketURL) { request in
            .success(for: request, result: .string(request.arguments.first ?? ""))
        }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try ControlClient(socketURL: socketURL).send(ControlRequest(command: "status", arguments: [payload]), timeout: 5).result, .string(payload))
    }

    func testEncodingFailureKeepsCompleteCorrelatedErrorEnvelope() throws {
        let request = ControlRequest(command: "stats")
        let invalid = ControlResponse.success(for: request, result: .double(.infinity))
        let failure = try response(invalid.encodedLine())
        XCTAssertFalse(failure.ok)
        XCTAssertEqual(failure.id, request.id)
        XCTAssertEqual(failure.command, request.command)
        XCTAssertEqual(failure.error?.code, .failed)
        XCTAssertEqual(failure.protocolVersion, ControlProtocol.version)
        for value in [Double.infinity, -.infinity, .nan, Double(Int.max), 1.5] {
            XCTAssertNil(JSONValue.double(value).intValue)
        }
    }

    func testJSONEncodingErrorsUseStderrAndFailureExitIncludingWatch() throws {
        for options in [[], ["--watch", "0.25"]] {
            var dependencies = isolatedDependencies()
            dependencies.send = { request, _, _ in .success(for: request, result: .double(.nan)) }
            let output = Output()
            XCTAssertEqual(GeraldineCommandLine.run(arguments: ["geraldine", "stats", "--json"] + options, environment: [:], io: output.io, dependencies: dependencies), 1)
            XCTAssertTrue(output.out.isEmpty)
            XCTAssertTrue(output.err.hasSuffix("\n"))
            XCTAssertEqual(try response(output.err).error?.code, .failed)
        }
    }

    // MARK: - Raw framing and I/O regressions

    private func listener() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let bound = ControlSocketAddress.withAddress(path: socketURL.path) { Darwin.bind(descriptor, $0, $1) }
        guard bound == 0, Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptor
    }

    private func fixtureConnection() -> Int32 {
        let descriptor = ControlSocketAddress.connect(path: socketURL.path, timeout: 2)
        if descriptor >= 0 {
            XCTAssertEqual(fcntl(descriptor, F_SETFL, 0), 0)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            XCTAssertEqual(setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)), 0)
        }
        return descriptor
    }

    @discardableResult
    private func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    private func withRawReply(_ makeChunks: @escaping (ControlRequest) -> [Data], delay: TimeInterval = 0,
                              body: (ControlClient) throws -> Void) throws {
        let descriptor = try listener()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { finished.signal() }
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !data.contains(0x0A) {
                let count = Darwin.recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { return }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard let newline = data.firstIndex(of: 0x0A), let request = try? JSONDecoder().decode(ControlRequest.self, from: data[..<newline]) else { return }
            for chunk in makeChunks(request) {
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if !self.writeAll(chunk, to: client) { return }
            }
        }
        defer {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        }
        try body(ControlClient(socketURL: socketURL))
    }

    func testClientReadsFragmentedResponseAndRejectsTruncation() throws {
        try withRawReply({ request in
            let data = Data((ControlResponse.success(for: request, result: .string("fragmented")).encodedLine() + "\n").utf8)
            return [Data(data.prefix(7)), Data(data.dropFirst(7).dropLast()), Data([0x0A])]
        }) { client in
            XCTAssertEqual(try client.send(ControlRequest(command: "status"), timeout: 2).result, .string("fragmented"))
        }
        XCTAssertEqual(unlink(socketURL.path), 0)
        try withRawReply({ request in [Data(ControlResponse.success(for: request).encodedLine().utf8)] }) { client in
            XCTAssertThrowsError(try client.send(ControlRequest(command: "status"), timeout: 2)) {
                // Darwin can reject SO_RCVTIMEO with EINVAL after the peer
                // closes. Either path must reject the unterminated frame.
                let failure = $0 as? ControlClientError
                XCTAssertTrue(failure == .malformedResponse || failure == .transportFailed(EINVAL))
            }
        }
    }

    func testPartialRepliesCannotExtendTheRequestedDeadline() throws {
        try withRawReply({ request in
            Array((ControlResponse.success(for: request).encodedLine() + "\n").utf8).map { Data([$0]) }
        }, delay: 0.01) { client in
            let start = Date()
            XCTAssertThrowsError(try client.send(ControlRequest(command: "status"), timeout: 0.04)) {
                XCTAssertEqual($0 as? ControlClientError, .timedOut)
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        }
    }

    func testServerReadsLargeFragmentedRequestBeyondFormerLineLimit() throws {
        let calls = Output()
        let server = ControlServer(socketURL: socketURL) { request in
            calls.io.out("called")
            return .success(for: request, result: .int(request.arguments.first?.count ?? 0))
        }
        try server.start()
        defer { server.stop() }
        let client = fixtureConnection()
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { Darwin.close(client) }
        let length = 1_048_577
        let request = ControlRequest(command: "status", arguments: [String(repeating: "x", count: length)])
        let bytes = try JSONEncoder().encode(request)
        for offset in stride(from: 0, to: bytes.count, by: 997) {
            XCTAssertTrue(writeAll(bytes.subdata(in: offset..<min(offset + 997, bytes.count)), to: client))
        }
        XCTAssertTrue(writeAll(Data([0x0A]), to: client))
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(client, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(count, 0)
        if count > 0 { XCTAssertEqual(try response(String(decoding: buffer.prefix(count), as: UTF8.self)).result, .int(length)) }
        XCTAssertEqual(calls.out, "called")
    }
}
