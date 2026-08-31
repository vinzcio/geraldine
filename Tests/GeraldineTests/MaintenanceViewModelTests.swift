import Combine
import XCTest
@testable import Geraldine

@MainActor
final class MaintenanceViewModelTests: XCTestCase {
    func testTaskDefinitionsPreserveExactCommandsAndAdminFlags() {
        let viewModel = MaintenanceViewModel(
            runner: ControlledMaintenanceRunner(),
            clock: ControlledMaintenanceClock()
        )

        XCTAssertEqual(viewModel.tasks.map { TaskSnapshot($0) }, [
            .init(id: "dns", needsAdmin: true,
                  command: "dscacheutil -flushcache; killall -HUP mDNSResponder"),
            .init(id: "purge", needsAdmin: true, command: "/usr/sbin/purge"),
            .init(id: "periodic", needsAdmin: true,
                  command: "periodic daily weekly monthly"),
            .init(id: "spotlight", needsAdmin: true, command: "mdutil -E /"),
            .init(id: "launchservices", needsAdmin: false,
                  command: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user")
        ])
    }

    func testAllTasksUseExactAdminAndNonAdminDispatch() async {
        let runner = ControlledMaintenanceRunner()
        let clock = ControlledMaintenanceClock()
        let viewModel = MaintenanceViewModel(runner: runner, clock: clock)

        for task in viewModel.tasks {
            viewModel.run(task)
        }
        await runner.waitForCalls(5)

        let expected = Set(viewModel.tasks.map { task -> ControlledMaintenanceRunner.Invocation in
            if task.needsAdmin {
                return .admin(command: task.command)
            }
            return .standard(launchPath: "/bin/sh", arguments: ["-c", task.command])
        })
        assertAsyncEqual(Set(await runner.invocations()), expected)

        for index in 0..<5 {
            assertResolved(await runner.resolve(
                at: index,
                with: .init(
                    ok: false,
                    output: "failure-\(index)",
                    finishedAt: Date(timeIntervalSince1970: Double(100 + index))
                )
            ))
        }
        await waitForPublished(viewModel.$status) { status in
            viewModel.tasks.allSatisfy { status[$0.id] == .failed }
        }

        for task in viewModel.tasks {
            XCTAssertEqual(viewModel.lastRun(task.id)?.command, task.command)
        }
        assertAsyncEqual(await clock.waitCallCount(), 0)
    }

    func testSuccessPublishesRawRunThenWaitsForControlledIdleRevertAndFailureDoesNotWait() async throws {
        let runner = ControlledMaintenanceRunner()
        let clock = ControlledMaintenanceClock()
        let viewModel = MaintenanceViewModel(runner: runner, clock: clock)
        let launchServices = try XCTUnwrap(viewModel.tasks.first { $0.id == "launchservices" })
        let dns = try XCTUnwrap(viewModel.tasks.first { $0.id == "dns" })
        let successDate = Date(timeIntervalSince1970: 200)
        let failureDate = Date(timeIntervalSince1970: 201)

        viewModel.run(launchServices)
        XCTAssertEqual(viewModel.status(launchServices.id), .running)
        await runner.waitForCalls(1)
        assertAsyncEqual(
            await runner.invocations(),
            [.standard(launchPath: "/bin/sh", arguments: ["-c", launchServices.command])]
        )
        assertResolved(await runner.resolve(
            at: 0,
            with: .init(ok: true, output: " raw success output\n", finishedAt: successDate)
        ))
        await waitForPublished(viewModel.$status) { $0[launchServices.id] == .done }
        await clock.waitForCalls(1)

        XCTAssertEqual(viewModel.lastRun(launchServices.id), MaintenanceRun(
            ok: true,
            command: launchServices.command,
            output: " raw success output\n",
            finishedAt: successDate
        ))
        assertResolved(await clock.resume(at: 0))
        await waitForPublished(viewModel.$status) { $0[launchServices.id] == .idle }
        XCTAssertEqual(viewModel.lastRun(launchServices.id)?.finishedAt, successDate)

        viewModel.run(dns)
        await runner.waitForCalls(2)
        assertResolved(await runner.resolve(
            at: 1,
            with: .init(ok: false, output: "raw failure", finishedAt: failureDate)
        ))
        await waitForPublished(viewModel.$status) { $0[dns.id] == .failed }

        XCTAssertEqual(viewModel.lastRun(dns.id), MaintenanceRun(
            ok: false,
            command: dns.command,
            output: "raw failure",
            finishedAt: failureDate
        ))
        assertAsyncEqual(await clock.waitCallCount(), 1)
    }

    func testDuplicateSameIDCallsBothRunAndLastCompletionWins() async throws {
        let runner = ControlledMaintenanceRunner()
        let clock = ControlledMaintenanceClock()
        let viewModel = MaintenanceViewModel(runner: runner, clock: clock)
        let dns = try XCTUnwrap(viewModel.tasks.first { $0.id == "dns" })
        let earlierDate = Date(timeIntervalSince1970: 300)
        let laterDate = Date(timeIntervalSince1970: 301)

        viewModel.run(dns)
        viewModel.run(dns)
        XCTAssertEqual(viewModel.status(dns.id), .running)
        await runner.waitForCalls(2)
        assertAsyncEqual(await runner.invocations(), [
            .admin(command: dns.command),
            .admin(command: dns.command)
        ])
        var statusUpdates = viewModel.$status.values.makeAsyncIterator()
        _ = await statusUpdates.next()

        assertResolved(await runner.resolve(
            at: 1,
            with: .init(ok: false, output: "second call failed first", finishedAt: earlierDate)
        ))
        let earlierStatus = await statusUpdates.next()
        XCTAssertEqual(earlierStatus?[dns.id], .failed)
        XCTAssertEqual(viewModel.lastRun(dns.id)?.output, "second call failed first")

        assertResolved(await runner.resolve(
            at: 0,
            with: .init(ok: false, output: "first call failed later", finishedAt: laterDate)
        ))
        let laterStatus = await statusUpdates.next()
        XCTAssertEqual(laterStatus?[dns.id], .failed)
        XCTAssertEqual(viewModel.lastRun(dns.id), MaintenanceRun(
            ok: false,
            command: dns.command,
            output: "first call failed later",
            finishedAt: laterDate
        ))
        XCTAssertEqual(viewModel.status(dns.id), .failed)
        assertAsyncEqual(await clock.waitCallCount(), 0)
    }

    func testGuardedIdleRevertDoesNotOverwriteNewerFailure() async {
        let clock = ControlledMaintenanceClock()
        let viewModel = MaintenanceViewModel(
            runner: ControlledMaintenanceRunner(),
            clock: clock
        )
        let id = "guarded-reset"
        viewModel.status[id] = .done

        let reset = Task { @MainActor in
            await viewModel.resetSuccessfulStateAfterDelay(id)
        }
        await clock.waitForCalls(1)
        viewModel.status[id] = .failed
        assertResolved(await clock.resume(at: 0))
        await reset.value

        XCTAssertEqual(viewModel.status(id), .failed)
        assertAsyncEqual(await clock.waitCallCount(), 1)
    }

    func testDistinctIDsCompleteIndependentlyWhenReordered() async throws {
        let runner = ControlledMaintenanceRunner()
        let clock = ControlledMaintenanceClock()
        let viewModel = MaintenanceViewModel(runner: runner, clock: clock)
        let dns = try XCTUnwrap(viewModel.tasks.first { $0.id == "dns" })
        let launchServices = try XCTUnwrap(viewModel.tasks.first { $0.id == "launchservices" })
        let dnsDate = Date(timeIntervalSince1970: 400)
        let launchServicesDate = Date(timeIntervalSince1970: 401)

        viewModel.run(dns)
        viewModel.run(launchServices)
        await runner.waitForCalls(2)
        let invocations = await runner.invocations()
        let dnsIndex = try XCTUnwrap(invocations.firstIndex(of: .admin(command: dns.command)))
        let launchServicesIndex = try XCTUnwrap(invocations.firstIndex(of: .standard(
            launchPath: "/bin/sh", arguments: ["-c", launchServices.command]
        )))

        assertResolved(await runner.resolve(
            at: launchServicesIndex,
            with: .init(ok: true, output: "launch services ok", finishedAt: launchServicesDate)
        ))
        await waitForPublished(viewModel.$status) { $0[launchServices.id] == .done }
        await clock.waitForCalls(1)
        XCTAssertEqual(viewModel.status(dns.id), .running)
        XCTAssertEqual(viewModel.lastRun(launchServices.id)?.finishedAt, launchServicesDate)
        XCTAssertNil(viewModel.lastRun(dns.id))

        assertResolved(await runner.resolve(
            at: dnsIndex,
            with: .init(ok: false, output: "dns failed", finishedAt: dnsDate)
        ))
        await waitForPublished(viewModel.$status) { $0[dns.id] == .failed }
        XCTAssertEqual(viewModel.status(launchServices.id), .done)
        XCTAssertEqual(viewModel.lastRun(dns.id)?.finishedAt, dnsDate)

        assertResolved(await clock.resume(at: 0))
        await waitForPublished(viewModel.$status) { $0[launchServices.id] == .idle }
        XCTAssertEqual(viewModel.status(dns.id), .failed)
    }

}

private struct TaskSnapshot: Equatable {
    let id: String
    let needsAdmin: Bool
    let command: String

    init(_ task: MaintenanceTask) {
        id = task.id
        needsAdmin = task.needsAdmin
        command = task.command
    }

    init(id: String, needsAdmin: Bool, command: String) {
        self.id = id
        self.needsAdmin = needsAdmin
        self.command = command
    }
}

private actor ControlledMaintenanceRunner: MaintenanceCommandRunning {
    enum Invocation: Hashable, Sendable {
        case standard(launchPath: String, arguments: [String])
        case admin(command: String)
    }

    private struct CallWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var calls: [Invocation] = []
    private var continuations: [CheckedContinuation<MaintenanceCommandResult, Never>?] = []
    private var callWaiters: [CallWaiter] = []

    func run(_ launchPath: String, arguments: [String]) async -> MaintenanceCommandResult {
        await suspend(.standard(launchPath: launchPath, arguments: arguments))
    }

    func runAdmin(_ command: String) async -> MaintenanceCommandResult {
        await suspend(.admin(command: command))
    }

    private func suspend(_ invocation: Invocation) async -> MaintenanceCommandResult {
        await withCheckedContinuation { continuation in
            calls.append(invocation)
            continuations.append(continuation)
            resumeCallWaiters()
        }
    }

    func callCount() -> Int { calls.count }
    func invocations() -> [Invocation] { calls }

    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(.init(count: count, continuation: continuation))
        }
    }

    func resolve(at index: Int, with result: MaintenanceCommandResult) -> Bool {
        guard continuations.indices.contains(index),
              let continuation = continuations[index] else { return false }
        continuations[index] = nil
        continuation.resume(returning: result)
        return true
    }

    private func resumeCallWaiters() {
        let ready = callWaiters.filter { $0.count <= calls.count }
        callWaiters.removeAll { $0.count <= calls.count }
        ready.forEach { $0.continuation.resume() }
    }
}

private actor ControlledMaintenanceClock: MaintenanceClock {
    private struct CallWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var continuations: [CheckedContinuation<Void, Never>?] = []
    private var callWaiters: [CallWaiter] = []

    func waitForIdleRevert() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            resumeCallWaiters()
        }
    }

    func waitCallCount() -> Int { continuations.count }

    func waitForCalls(_ count: Int) async {
        guard continuations.count < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(.init(count: count, continuation: continuation))
        }
    }

    func resume(at index: Int) -> Bool {
        guard continuations.indices.contains(index),
              let continuation = continuations[index] else { return false }
        continuations[index] = nil
        continuation.resume()
        return true
    }

    private func resumeCallWaiters() {
        let ready = callWaiters.filter { $0.count <= continuations.count }
        callWaiters.removeAll { $0.count <= continuations.count }
        ready.forEach { $0.continuation.resume() }
    }
}

@MainActor
private func waitForPublished<Value>(
    _ publisher: Published<Value>.Publisher,
    _ predicate: @escaping (Value) -> Bool
) async {
    for await value in publisher.values {
        if predicate(value) { return }
    }
}

private func assertResolved(
    _ value: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(value, "Expected the pending operation to resolve", file: file, line: line)
}

private func assertAsyncEqual<Value: Equatable>(
    _ actual: Value,
    _ expected: Value,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
