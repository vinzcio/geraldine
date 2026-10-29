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

    func testConcurrentRefreshRequestsReturnCacheBeforeProviderCompletes() async throws {
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
        // A watchdog releases the fixture if the old foreground wait returns.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await gate.release()
        }
        let start = Date()
        let first = await host.handle(request)
        let second = await host.handle(request)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertTrue(usage.isRefreshing)
        XCTAssertEqual(first.result?["refreshed"], .bool(false))
        XCTAssertEqual(second.result?["refreshed"], .bool(false))
        XCTAssertTrue(first.warnings.contains { $0.contains("background") })
        host.stop()
        XCTAssertTrue(usage.isRefreshing, "The request does not own the provider refresh")
        watchdog.cancel()
        await gate.release()
    }
}
