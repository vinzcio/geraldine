import Combine
import XCTest
@testable import Geraldine

@MainActor
final class UpdaterViewModelTests: XCTestCase {
    func testUnavailableBrewUsesInjectedClockAndResetsCheckCollections() async {
        let runner = ControlledUpdaterRunner()
        let now = Date(timeIntervalSince1970: 10)
        let viewModel = UpdaterViewModel(runner: runner, clock: FixedUpdaterClock(now: now))
        let oldApp = makeApp(token: "old-app", name: "Old App")
        viewModel.completed = [oldApp]
        viewModel.upgradeFeedback[oldApp.token] = BrewCommandFeedback(
            ok: false, message: "old", output: "old", checkedAt: now
        )

        viewModel.load()

        XCTAssertTrue(viewModel.loading)
        XCTAssertEqual(viewModel.checkState, .unchecked)
        XCTAssertTrue(viewModel.completed.isEmpty)
        XCTAssertTrue(viewModel.upgradeFeedback.isEmpty)
        await runner.waitForBrewCalls(1)
        assertResolved(await runner.resolveBrew(at: 0, with: nil))
        await waitForPublished(viewModel.$loading) { !$0 }

        XCTAssertNil(viewModel.brewPath)
        XCTAssertTrue(viewModel.outdated.isEmpty)
        XCTAssertEqual(viewModel.checkState, .unavailable(checkedAt: now))
        XCTAssertEqual(viewModel.displayPhase, .unavailable)
        XCTAssertTrue(viewModel.checked)
        assertAsyncEqual(await runner.runCallCount(), 0)
    }

    func testMalformedStatusZeroOutputUsesUnreadableMessage() async {
        await assertMalformedCheck(
            status: 0,
            expectedMessage: "Homebrew returned output Geraldine could not read."
        )
    }

    func testMalformedNonzeroOutputUsesExitCodeMessage() async {
        await assertMalformedCheck(
            status: 7,
            expectedMessage: "Homebrew outdated check failed with exit code 7."
        )
    }

    func testValidNonzeroJSONIsAuthoritativeAndPreservesFallbackMappingAndSorting() async {
        let runner = ControlledUpdaterRunner()
        let checkedAt = Date(timeIntervalSince1970: 20)
        let viewModel = UpdaterViewModel(runner: runner, clock: FixedUpdaterClock(now: .distantPast))
        let alpha = "geraldine-fixture-alpha-4f71"
        let zeta = "geraldine-fixture-zeta-9c82"
        let json = """
        {"casks":[
          {"name":"\(zeta)","installed_versions":["1.0","1.2"],"current_version":"2.0"},
          {"ignored":"missing name"},
          {"name":"\(alpha)"}
        ]}
        """

        viewModel.load()
        await runner.waitForBrewCalls(1)
        assertResolved(await runner.resolveBrew(at: 0, with: "/fake/brew"))
        await runner.waitForRunCalls(1)
        assertAsyncEqual(
            await runner.runInvocations(),
            [.init(launchPath: "/fake/brew", arguments: ["outdated", "--cask", "--json=v2"])]
        )
        assertResolved(await runner.resolveRun(
            at: 0,
            with: commandResult(status: 42, stdout: json, output: "warning", finishedAt: checkedAt)
        ))
        await waitForPublished(viewModel.$loading) { !$0 }

        XCTAssertEqual(viewModel.brewPath, "/fake/brew")
        XCTAssertEqual(viewModel.outdated.map(\.token), [alpha, zeta])
        XCTAssertEqual(viewModel.outdated[0].current, "-")
        XCTAssertEqual(viewModel.outdated[0].latest, "-")
        XCTAssertEqual(viewModel.outdated[0].name,
                       alpha.replacingOccurrences(of: "-", with: " ").capitalized)
        XCTAssertEqual(viewModel.outdated[1].current, "1.2")
        XCTAssertEqual(viewModel.outdated[1].latest, "2.0")
        XCTAssertEqual(viewModel.checkState, .updatesAvailable(checkedAt: checkedAt))
    }

    func testEmptyValidNonzeroJSONProducesNoUpdates() async {
        let runner = ControlledUpdaterRunner()
        let checkedAt = Date(timeIntervalSince1970: 30)
        let viewModel = UpdaterViewModel(runner: runner, clock: FixedUpdaterClock(now: .distantPast))

        viewModel.load()
        await runner.waitForBrewCalls(1)
        assertResolved(await runner.resolveBrew(at: 0, with: "/fake/brew"))
        await runner.waitForRunCalls(1)
        assertResolved(await runner.resolveRun(
            at: 0,
            with: commandResult(
                status: 3,
                stdout: #"{"casks":[]}"#,
                output: "nonzero output is ignored for valid JSON",
                finishedAt: checkedAt
            )
        ))
        await waitForPublished(viewModel.$loading) { !$0 }

        XCTAssertTrue(viewModel.outdated.isEmpty)
        XCTAssertEqual(viewModel.checkState, .noUpdates(checkedAt: checkedAt))
    }

    func testOverlappingLoadsBothRunAndPublishInCompletionOrder() async throws {
        let runner = ControlledUpdaterRunner()
        let viewModel = UpdaterViewModel(runner: runner, clock: FixedUpdaterClock(now: .distantPast))
        let firstDate = Date(timeIntervalSince1970: 40)
        let secondDate = Date(timeIntervalSince1970: 41)

        viewModel.load()
        viewModel.load()
        await runner.waitForBrewCalls(2)

        assertResolved(await runner.resolveBrew(at: 0, with: "/fake/brew-first"))
        await runner.waitForRunCalls(1)
        assertResolved(await runner.resolveBrew(at: 1, with: "/fake/brew-second"))
        await runner.waitForRunCalls(2)

        let invocations = await runner.runInvocations()
        let firstIndex = try XCTUnwrap(invocations.firstIndex { $0.launchPath == "/fake/brew-first" })
        let secondIndex = try XCTUnwrap(invocations.firstIndex { $0.launchPath == "/fake/brew-second" })
        assertResolved(await runner.resolveRun(
            at: secondIndex,
            with: commandResult(
                status: 0,
                stdout: #"{"casks":[{"name":"second-load","installed_versions":["1"],"current_version":"2"}]}"#,
                output: "",
                finishedAt: secondDate
            )
        ))
        await waitForPublished(viewModel.$outdated) { $0.map(\.token) == ["second-load"] }
        XCTAssertEqual(viewModel.checkState, .updatesAvailable(checkedAt: secondDate))

        assertResolved(await runner.resolveRun(
            at: firstIndex,
            with: commandResult(
                status: 0,
                stdout: #"{"casks":[{"name":"first-load","installed_versions":["3"],"current_version":"4"}]}"#,
                output: "",
                finishedAt: firstDate
            )
        ))
        await waitForPublished(viewModel.$outdated) { $0.map(\.token) == ["first-load"] }

        XCTAssertEqual(viewModel.brewPath, "/fake/brew-first")
        XCTAssertEqual(viewModel.checkState, .updatesAvailable(checkedAt: firstDate))
        XCTAssertFalse(viewModel.loading)
        XCTAssertTrue(viewModel.checked)
    }

    func testDuplicateUpgradeCallsBothRunAndLastCompletionWinsFeedback() async {
        let runner = ControlledUpdaterRunner()
        let viewModel = UpdaterViewModel(runner: runner, clock: FixedUpdaterClock(now: .distantPast))
        let app = makeApp(token: "duplicate-app", name: "Duplicate App")
        let failureDate = Date(timeIntervalSince1970: 50)
        let successDate = Date(timeIntervalSince1970: 51)
        viewModel.brewPath = "/fake/brew"
        viewModel.outdated = [app]

        viewModel.upgrade(app)
        viewModel.upgrade(app)
        XCTAssertEqual(viewModel.upgrading, [app.token])
        await runner.waitForRunCalls(2)
        assertAsyncEqual(
            await runner.runInvocations(),
            [
                .init(launchPath: "/fake/brew", arguments: ["upgrade", "--cask", app.token]),
                .init(launchPath: "/fake/brew", arguments: ["upgrade", "--cask", app.token])
            ]
        )

        assertResolved(await runner.resolveRun(
            at: 1,
            with: commandResult(status: 9, stdout: "", output: " first failure\n", finishedAt: failureDate)
        ))
        await waitForPublished(viewModel.$upgradeFeedback) {
            $0[app.token]?.checkedAt == failureDate
        }
        XCTAssertTrue(viewModel.upgrading.isEmpty)
        XCTAssertEqual(viewModel.upgradeFeedback[app.token], BrewCommandFeedback(
            ok: false,
            message: "Homebrew could not update Duplicate App.",
            output: "first failure",
            checkedAt: failureDate
        ))
        XCTAssertEqual(viewModel.outdated, [app])
        XCTAssertTrue(viewModel.completed.isEmpty)

        assertResolved(await runner.resolveRun(
            at: 0,
            with: commandResult(status: 0, stdout: "", output: " success\n", finishedAt: successDate)
        ))
        await waitForPublished(viewModel.$upgradeFeedback) {
            $0[app.token]?.checkedAt == successDate
        }

        XCTAssertEqual(viewModel.upgradeFeedback[app.token], BrewCommandFeedback(
            ok: true,
            message: "Updated Duplicate App.",
            output: "success",
            checkedAt: successDate
        ))
        XCTAssertTrue(viewModel.outdated.isEmpty)
        XCTAssertEqual(viewModel.completed, [app])
        XCTAssertEqual(viewModel.checkState, .noUpdates(checkedAt: successDate))
    }

    func testDistinctUpgradesCompleteIndependentlyWhenReordered() async throws {
        let runner = ControlledUpdaterRunner()
        let viewModel = UpdaterViewModel(runner: runner, clock: FixedUpdaterClock(now: .distantPast))
        let alpha = makeApp(token: "alpha-app", name: "Alpha App")
        let beta = makeApp(token: "beta-app", name: "Beta App")
        let alphaDate = Date(timeIntervalSince1970: 60)
        let betaDate = Date(timeIntervalSince1970: 61)
        viewModel.brewPath = "/fake/brew"
        viewModel.outdated = [alpha, beta]

        viewModel.upgrade(alpha)
        viewModel.upgrade(beta)
        await runner.waitForRunCalls(2)
        let invocations = await runner.runInvocations()
        let alphaIndex = try XCTUnwrap(invocations.firstIndex { $0.arguments.last == alpha.token })
        let betaIndex = try XCTUnwrap(invocations.firstIndex { $0.arguments.last == beta.token })

        assertResolved(await runner.resolveRun(
            at: betaIndex,
            with: commandResult(status: 0, stdout: "", output: "beta ok", finishedAt: betaDate)
        ))
        await waitForPublished(viewModel.$upgradeFeedback) {
            $0[beta.token]?.checkedAt == betaDate
        }
        XCTAssertEqual(viewModel.upgrading, [alpha.token])
        XCTAssertEqual(viewModel.completed, [beta])
        XCTAssertEqual(viewModel.outdated, [alpha])
        XCTAssertEqual(viewModel.upgradeFeedback[beta.token]?.message, "Updated Beta App.")

        assertResolved(await runner.resolveRun(
            at: alphaIndex,
            with: commandResult(status: 5, stdout: "", output: "alpha failed", finishedAt: alphaDate)
        ))
        await waitForPublished(viewModel.$upgradeFeedback) {
            $0[alpha.token]?.checkedAt == alphaDate
        }
        XCTAssertTrue(viewModel.upgrading.isEmpty)
        XCTAssertEqual(viewModel.completed, [beta])
        XCTAssertEqual(viewModel.outdated, [alpha])
        XCTAssertEqual(viewModel.upgradeFeedback[alpha.token]?.message,
                       "Homebrew could not update Alpha App.")
    }

    private func assertMalformedCheck(status: Int32, expectedMessage: String) async {
        let runner = ControlledUpdaterRunner()
        let checkedAt = Date(timeIntervalSince1970: 11)
        let viewModel = UpdaterViewModel(runner: runner, clock: FixedUpdaterClock(now: .distantPast))

        viewModel.load()
        await runner.waitForBrewCalls(1)
        assertResolved(await runner.resolveBrew(at: 0, with: "/fake/brew"))
        await runner.waitForRunCalls(1)
        assertResolved(await runner.resolveRun(
            at: 0,
            with: commandResult(
                status: status,
                stdout: "not json",
                output: " stdout and stderr \n",
                finishedAt: checkedAt
            )
        ))
        await waitForPublished(viewModel.$loading) { !$0 }

        XCTAssertEqual(viewModel.brewPath, "/fake/brew")
        XCTAssertTrue(viewModel.outdated.isEmpty)
        XCTAssertEqual(viewModel.checkState, .failed(
            message: expectedMessage,
            output: "stdout and stderr",
            checkedAt: checkedAt
        ))
    }

    private func makeApp(token: String, name: String) -> OutdatedApp {
        OutdatedApp(token: token, name: name, current: "1", latest: "2", applicationURL: nil)
    }

    private func commandResult(
        status: Int32,
        stdout: String,
        output: String,
        finishedAt: Date
    ) -> UpdaterCommandResult {
        UpdaterCommandResult(status: status, stdout: stdout, output: output, finishedAt: finishedAt)
    }

}

private struct FixedUpdaterClock: UpdaterClock {
    let fixedDate: Date

    init(now: Date) {
        fixedDate = now
    }

    func now() -> Date { fixedDate }
}

private actor ControlledUpdaterRunner: UpdaterCommandRunning {
    struct Invocation: Equatable, Sendable {
        let launchPath: String
        let arguments: [String]
    }

    private struct CallWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var brewContinuations: [CheckedContinuation<String?, Never>?] = []
    private var brewCallWaiters: [CallWaiter] = []
    private var invocations: [Invocation] = []
    private var runContinuations: [CheckedContinuation<UpdaterCommandResult, Never>?] = []
    private var runCallWaiters: [CallWaiter] = []

    func locateBrew() async -> String? {
        await withCheckedContinuation { continuation in
            brewContinuations.append(continuation)
            resumeBrewCallWaiters()
        }
    }

    func run(_ launchPath: String, arguments: [String]) async -> UpdaterCommandResult {
        await withCheckedContinuation { continuation in
            invocations.append(.init(launchPath: launchPath, arguments: arguments))
            runContinuations.append(continuation)
            resumeRunCallWaiters()
        }
    }

    func brewCallCount() -> Int { brewContinuations.count }
    func runCallCount() -> Int { invocations.count }
    func runInvocations() -> [Invocation] { invocations }

    func waitForBrewCalls(_ count: Int) async {
        guard brewContinuations.count < count else { return }
        await withCheckedContinuation { continuation in
            brewCallWaiters.append(.init(count: count, continuation: continuation))
        }
    }

    func waitForRunCalls(_ count: Int) async {
        guard invocations.count < count else { return }
        await withCheckedContinuation { continuation in
            runCallWaiters.append(.init(count: count, continuation: continuation))
        }
    }

    func resolveBrew(at index: Int, with value: String?) -> Bool {
        guard brewContinuations.indices.contains(index),
              let continuation = brewContinuations[index] else { return false }
        brewContinuations[index] = nil
        continuation.resume(returning: value)
        return true
    }

    func resolveRun(at index: Int, with result: UpdaterCommandResult) -> Bool {
        guard runContinuations.indices.contains(index),
              let continuation = runContinuations[index] else { return false }
        runContinuations[index] = nil
        continuation.resume(returning: result)
        return true
    }

    private func resumeBrewCallWaiters() {
        let ready = brewCallWaiters.filter { $0.count <= brewContinuations.count }
        brewCallWaiters.removeAll { $0.count <= brewContinuations.count }
        ready.forEach { $0.continuation.resume() }
    }

    private func resumeRunCallWaiters() {
        let ready = runCallWaiters.filter { $0.count <= invocations.count }
        runCallWaiters.removeAll { $0.count <= invocations.count }
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
