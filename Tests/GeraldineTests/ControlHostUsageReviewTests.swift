import Foundation
import XCTest
import GeraldineControl
@testable import Geraldine

@MainActor
final class ControlHostUsageReviewTests: XCTestCase {
    private actor RefreshGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    func testConcurrentRequestsWaitForRealMonitorCompletion() async throws {
        try await exerciseRefresh(cancel: nil)
    }

    func testStoppingHostCancelsEveryConcurrentUsageRequest() async throws {
        try await exerciseRefresh(cancel: "host")
    }

    func testCancellingOneRequestLeavesTheOtherRequestWaiting() async throws {
        try await exerciseRefresh(cancel: "request")
    }

    private func exerciseRefresh(cancel: String?) async throws {
        let suite = "ControlHostUsageReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let home = try AppReviewFixtureRoot.create()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let gate = RefreshGate()
        let usage = AIUsageMonitor(defaults: defaults, userHome: home, fetchUsage: { identity, _ in
            await gate.wait()
            return .failed(identity.provider, message: "Isolated provider fixture")
        })
        defer { usage.stop() }
        usage.connect(.codex)
        let host = ControlHost(defaults: defaults, usage: { usage })
        defer { host.stop() }
        let request = ControlRequest(command: "usage", options: ["refresh": "true"])
        let first = Task { @MainActor in await host.handle(request) }
        let second = Task { @MainActor in await host.handle(request) }
        await waitForRequests(2, host: host)
        XCTAssertTrue(usage.isRefreshing)
        if cancel == "host" {
            host.stop()
            let responses = [await first.value, await second.value]
            XCTAssertTrue(responses.allSatisfy { $0.result?["refreshed"] == .bool(false) })
            XCTAssertTrue(responses.allSatisfy { $0.warnings.contains { $0.contains("cancelled") } })
            XCTAssertTrue(usage.isRefreshing, "Cancelling control requests must leave the shared provider batch alone")
            await gate.release()
        } else {
            if cancel == "request" {
                first.cancel()
                await waitForRequests(1, host: host)
                let cancelled = await first.value
                XCTAssertEqual(cancelled.result?["refreshed"], .bool(false))
                XCTAssertTrue(usage.isRefreshing)
            }
            await gate.release()
            let completed = await second.value
            XCTAssertEqual(completed.result?["refreshed"], .bool(true))
            XCTAssertNotNil(usage.lastRefresh)
            if cancel == nil {
                let alsoCompleted = await first.value
                XCTAssertEqual(alsoCompleted.result?["refreshed"], .bool(true))
            }
        }
        XCTAssertEqual(host.pendingUsageRefreshCount, 0)
    }

    private func waitForRequests(_ count: Int, host: ControlHost) async {
        for _ in 0..<1_000 where host.pendingUsageRefreshCount != count { await Task.yield() }
        XCTAssertEqual(host.pendingUsageRefreshCount, count)
        if host.pendingUsageRefreshCount != count { host.stop() }
    }
}
