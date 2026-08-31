import Foundation
import XCTest
@testable import Geraldine

@MainActor
final class SmartCareScanCancellationTests: XCTestCase {
    func testNormalInjectedScanPublishesExistingFindingContent() async {
        let scanner = ControlledSmartCareScanner()
        let model = SmartCareViewModel(scanner: { generation in
            await scanner.scan(generation: generation)
        })

        model.scan()
        await scanner.waitForInvocationCount(1)
        let ownedWorker = model.ownedScanTaskForTesting()
        XCTAssertNotNil(ownedWorker)
        await scanner.finishInvocation(
            1,
            with: SmartCareScanExtras(junk: 3_000_000_000, startupItems: 9)
        )
        await ownedWorker?.value

        XCTAssertNotNil(model.scanDate)
        XCTAssertNil(model.ownedScanTaskForTesting())
        XCTAssertTrue(model.findings.contains { $0.title.contains("Of Reviewable Junk") })
        XCTAssertTrue(model.findings.contains { $0.title == "9 User Launch Agents" })
        let maximumConcurrency = await scanner.maximumConcurrentInvocations
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testReplacementCancelsAndDrainsPredecessorBeforeEnteringScanner() async {
        let scanner = ControlledSmartCareScanner()
        let model = SmartCareViewModel(scanner: { generation in
            await scanner.scan(generation: generation)
        })

        let firstGeneration = model.scan()
        await scanner.waitForInvocationCount(1)
        let secondGeneration = model.scan()
        let replacementWorker = model.ownedScanTaskForTesting()
        XCTAssertNotNil(replacementWorker)
        await scanner.waitForCancellationCount(1)

        let countWhilePredecessorIsSuspended = await scanner.invocations
        XCTAssertEqual(countWhilePredecessorIsSuspended, 1)
        XCTAssertEqual(model.phase, .scanning)

        await scanner.finishInvocation(
            1,
            with: SmartCareScanExtras(junk: 9_000_000_000, startupItems: 99)
        )
        await scanner.waitForInvocationCount(2)

        XCTAssertEqual(model.phase, .scanning)
        XCTAssertFalse(model.findings.contains { $0.title == "99 User Launch Agents" })
        let replacementGenerations = await scanner.startedGenerations
        XCTAssertEqual(replacementGenerations, [firstGeneration, secondGeneration])

        await scanner.finishInvocation(
            2,
            with: SmartCareScanExtras(junk: 0, startupItems: 0)
        )
        await replacementWorker?.value

        XCTAssertNil(model.ownedScanTaskForTesting())
        XCTAssertTrue(model.findings.contains { $0.title == "Startup Is Lean" })
        XCTAssertTrue(model.findings.contains { $0.title == "Little Junk To Clean" })
        XCTAssertFalse(model.findings.contains { $0.title == "99 User Launch Agents" })
        let maximumConcurrency = await scanner.maximumConcurrentInvocations
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testThreeRapidScansSkipTheCancelledMiddleScanner() async {
        let scanner = ControlledSmartCareScanner()
        let model = SmartCareViewModel(scanner: { generation in
            await scanner.scan(generation: generation)
        })

        let firstGeneration = model.scan()
        await scanner.waitForInvocationCount(1)
        let middleGeneration = model.scan()
        let latestGeneration = model.scan()
        let latestWorker = model.ownedScanTaskForTesting()
        XCTAssertNotNil(latestWorker)
        await scanner.waitForCancellationCount(1)

        await scanner.finishInvocation(
            1,
            with: SmartCareScanExtras(junk: 8_000_000_000, startupItems: 88)
        )
        await scanner.waitForInvocationCount(2)

        let invocationCount = await scanner.invocations
        XCTAssertEqual(invocationCount, 2, "the middle task must stop before entering the scanner")
        let startedGenerations = await scanner.startedGenerations
        XCTAssertEqual(startedGenerations, [firstGeneration, latestGeneration])
        XCTAssertFalse(startedGenerations.contains(middleGeneration))
        XCTAssertEqual(model.phase, .scanning)

        await scanner.finishInvocation(
            2,
            with: SmartCareScanExtras(junk: 0, startupItems: 2)
        )
        await latestWorker?.value

        XCTAssertNil(model.ownedScanTaskForTesting())
        XCTAssertTrue(model.findings.contains { $0.title == "Startup Is Lean" })
        XCTAssertFalse(model.findings.contains { $0.title == "88 User Launch Agents" })
        let maximumConcurrency = await scanner.maximumConcurrentInvocations
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testCancelScanReturnsToIdleAndAQuickRestartWaitsForDrain() async {
        let scanner = ControlledSmartCareScanner()
        let model = SmartCareViewModel(scanner: { generation in
            await scanner.scan(generation: generation)
        })

        model.scan()
        await scanner.waitForInvocationCount(1)
        let cancelledWorker = model.ownedScanTaskForTesting()
        XCTAssertNotNil(cancelledWorker)
        model.cancelScan()
        await scanner.waitForCancellationCount(1)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.scanDate)

        model.scan()
        let restartWorker = model.ownedScanTaskForTesting()
        XCTAssertNotNil(restartWorker)
        let countBeforeDrain = await scanner.invocations
        XCTAssertEqual(countBeforeDrain, 1)
        XCTAssertEqual(model.phase, .scanning)

        await scanner.finishInvocation(
            1,
            with: SmartCareScanExtras(junk: 7_000_000_000, startupItems: 77)
        )
        await cancelledWorker?.value
        await scanner.waitForInvocationCount(2)

        XCTAssertFalse(model.findings.contains { $0.title == "77 User Launch Agents" })
        await scanner.finishInvocation(
            2,
            with: SmartCareScanExtras(junk: 0, startupItems: 1)
        )
        await restartWorker?.value

        XCTAssertNil(model.ownedScanTaskForTesting())
        XCTAssertTrue(model.findings.contains { $0.title == "Startup Is Lean" })
        let maximumConcurrency = await scanner.maximumConcurrentInvocations
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testCancelScanCannotPublishWhenCancelledScannerEventuallyReturns() async {
        let scanner = ControlledSmartCareScanner()
        let model = SmartCareViewModel(scanner: { generation in
            await scanner.scan(generation: generation)
        })

        model.scan()
        await scanner.waitForInvocationCount(1)
        let cancelledWorker = model.ownedScanTaskForTesting()
        XCTAssertNotNil(cancelledWorker)
        model.cancelScan()
        await scanner.waitForCancellationCount(1)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.scanDate)

        await scanner.finishInvocation(
            1,
            with: SmartCareScanExtras(junk: 6_000_000_000, startupItems: 66)
        )
        await cancelledWorker?.value

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.scanDate)
        XCTAssertFalse(model.findings.contains { $0.title == "66 User Launch Agents" })
    }

    func testCancelAfterCompletionIsANoOp() async {
        let scanner = ControlledSmartCareScanner()
        let model = SmartCareViewModel(scanner: { generation in
            await scanner.scan(generation: generation)
        })

        model.scan()
        await scanner.waitForInvocationCount(1)
        let ownedWorker = model.ownedScanTaskForTesting()
        XCTAssertNotNil(ownedWorker)
        await scanner.finishInvocation(
            1,
            with: SmartCareScanExtras(junk: 0, startupItems: 1)
        )
        await ownedWorker?.value

        XCTAssertNil(model.ownedScanTaskForTesting())
        let priorScore = model.score
        let priorDate = model.scanDate
        let priorTitles = model.findings.map(\.title)
        model.cancelScan()

        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(model.score, priorScore)
        XCTAssertEqual(model.scanDate, priorDate)
        XCTAssertEqual(model.findings.map(\.title), priorTitles)
    }
}

private actor ControlledSmartCareScanner {
    private struct PendingInvocation {
        let continuation: CheckedContinuation<SmartCareScanExtras, Never>
    }

    private struct CountWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var pending: [Int: PendingInvocation] = [:]
    private var invocationWaiters: [CountWaiter] = []
    private var cancellationWaiters: [CountWaiter] = []
    private var cancelledIDs: Set<Int> = []
    private var activeInvocations = 0
    private(set) var invocations = 0
    private(set) var maximumConcurrentInvocations = 0
    private(set) var startedGenerations: [UUID] = []

    func scan(generation: UUID) async -> SmartCareScanExtras {
        invocations += 1
        let invocationID = invocations
        startedGenerations.append(generation)
        activeInvocations += 1
        maximumConcurrentInvocations = max(maximumConcurrentInvocations, activeInvocations)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending[invocationID] = PendingInvocation(continuation: continuation)
                resumeSatisfiedInvocationWaiters()
            }
        } onCancel: {
            Task { await self.recordCancellation(of: invocationID) }
        }
    }

    func waitForInvocationCount(_ target: Int) async {
        guard invocations < target else { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append(CountWaiter(target: target, continuation: continuation))
        }
    }

    func waitForCancellationCount(_ target: Int) async {
        guard cancelledIDs.count < target else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(CountWaiter(target: target, continuation: continuation))
        }
    }

    func finishInvocation(_ invocationID: Int, with result: SmartCareScanExtras) {
        guard let invocation = pending.removeValue(forKey: invocationID) else {
            preconditionFailure("Invocation \(invocationID) is not pending")
        }
        activeInvocations -= 1
        invocation.continuation.resume(returning: result)
    }

    private func recordCancellation(of invocationID: Int) {
        cancelledIDs.insert(invocationID)
        let satisfied = cancellationWaiters.filter { cancelledIDs.count >= $0.target }
        cancellationWaiters.removeAll { cancelledIDs.count >= $0.target }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    private func resumeSatisfiedInvocationWaiters() {
        let satisfied = invocationWaiters.filter { invocations >= $0.target }
        invocationWaiters.removeAll { invocations >= $0.target }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
