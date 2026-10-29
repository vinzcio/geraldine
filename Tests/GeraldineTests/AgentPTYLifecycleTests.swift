import Darwin
import XCTest
@testable import Geraldine

final class AgentPTYLifecycleTests: XCTestCase {
    private func home() throws -> URL {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GERALDINE_CREDENTIAL_TEST_ROOT"] ?? NSTemporaryDirectory())
            .appendingPathComponent("pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func executable(_ script: String, home: URL, path: String = "child") throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testShutdownClosesFloodedTerminalAndKillsStubbornProcessGroup() throws {
        let home = try home()
        let script = try executable("""
        #!/usr/bin/python3
        import os, signal, time
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = os.fork()
        if child == 0:
            while True: time.sleep(.1)
        with open('pids', 'w') as f: f.write(str(os.getpid()) + ' ' + str(child))
        os.write(1, b'READY\\n')
        while True:
            try: os.write(1, b'x' * 65536)
            except OSError: time.sleep(.1)
        """, home: home)
        let start = Date()
        _ = AgentPTY.capture(executable: script, arguments: [], homeDirectory: home,
                             steps: [], stopContaining: [], timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let ids = try String(contentsOf: home.appendingPathComponent("pids")).split(separator: " ").compactMap { Int32($0) }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(kill(ids[0], 0), -1, "Session leader must be reaped")
        // launchd can take a moment to reap the orphaned descendant.
        let end = Date().addingTimeInterval(2)
        while kill(ids[1], 0) == 0 && Date() < end { usleep(10_000) }
        XCTAssertEqual(kill(ids[1], 0), -1, "SIGKILL must reach the process group")
    }

    func testGracefulShutdownSendsTERMBeforeKill() throws {
        let home = try home()
        let script = try executable("""
        #!/usr/bin/python3
        import os, signal, time
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        def term(*args):
            with open('term', 'w') as f: f.write('received')
            os._exit(0)
        signal.signal(signal.SIGTERM, term)
        os.write(1, b'READY\\n')
        while True: time.sleep(.05)
        """, home: home)
        _ = AgentPTY.capture(executable: script, arguments: [], homeDirectory: home,
                             steps: [], stopContaining: ["READY"], timeout: 3)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("term")), "received")
    }

    @MainActor
    func testCursorColdStartPastOldDeadlineKeepsMainActorResponsiveAndUsesNativeSignIn() async throws {
        let home = try home()
        XCTAssertGreaterThanOrEqual(CursorCLIUsage().timeout, 45)
        _ = try executable("""
        #!/bin/bash
        [ -z "$CURSOR_AUTH_TOKEN" ] || exit 8
        stty raw -echo
        sleep 28.5
        printf 'Plan, search, build anything\\r\\n'
        typed=""
        while [ "${#typed}" -lt 6 ]; do IFS= read -r -n1 ch; typed="$typed$ch"; done
        [ "$typed" = /usage ] || exit 9
        printf 'Show plan and on-demand usage\\r\\n'
        IFS= read -r -n1 enter
        sleep 1.2
        printf 'Usage • Premium   Resets Nov 3\\r\\nIncluded 7%% used\\r\\n'
        exec sleep 90
        """, home: home, path: ".local/bin/cursor-agent")
        let started = Date()
        let task = Task { await CursorCLIUsage().snapshot(homeDirectory: home, now: .now) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The main actor must run while Cursor starts")
        let snapshot = await task.value
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 7)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 28)
        XCTAssertLessThan(Date().timeIntervalSince(started), 45)
    }

    func testCursorSilentCLIHonorsConfiguredBackgroundTimeout() async throws {
        let home = try home()
        _ = try executable("#!/bin/sh\nexec sleep 90\n", home: home, path: ".local/bin/cursor-agent")
        let start = Date()
        let snapshot = await CursorCLIUsage(timeout: 0.2).snapshot(homeDirectory: home, now: .now)
        if case .error = snapshot.status {} else { XCTFail("Silent CLI must fail") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testLiveCursorNativeSession() async throws {
        guard ProcessInfo.processInfo.environment["CURSOR_USAGE_LIVE"] == "1" else { throw XCTSkip("Opt-in native Cursor usage check") }
        let start = Date()
        let snapshot = await CursorCLIUsage().snapshot(homeDirectory: FileManager.default.homeDirectoryForCurrentUser, now: .now)
        XCTAssertEqual(snapshot.status, .ready)
        XCTAssertFalse(snapshot.windows.isEmpty)
        print("CURSOR_NATIVE_USAGE elapsed=\(Date().timeIntervalSince(start)), windows=\(snapshot.windows.count), remaining=\(snapshot.remainingPercent ?? -1)")
    }
}
