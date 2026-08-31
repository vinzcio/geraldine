import Combine
import Foundation
import XCTest
@testable import Geraldine

@MainActor
final class DeviceMonitorRefreshTests: XCTestCase {
    func testCoordinatorKeepsOneRunningAndCoalescesOnePendingRequest() {
        var coordinator = DeviceRefreshCoordinator()

        XCTAssertTrue(coordinator.requestRefresh())
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertFalse(coordinator.hasPendingRequest)

        XCTAssertFalse(coordinator.requestRefresh())
        XCTAssertFalse(coordinator.requestRefresh())
        XCTAssertTrue(coordinator.hasPendingRequest)

        XCTAssertTrue(coordinator.completeRefresh())
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertFalse(coordinator.hasPendingRequest)

        XCTAssertFalse(coordinator.completeRefresh())
        XCTAssertFalse(coordinator.isRunning)
    }

    func testRequestsDuringScanPublishOneCoalescedFollowUpWithoutOverlap() async {
        let scanner = ControlledDeviceScanner()
        let publications = DeviceScanPublicationObserver()
        let monitor = DeviceMonitor(
            scanner: { await scanner.scan() },
            onScanPublication: { devices, scanning in
                publications.record(devices: devices, scanning: scanning)
            }
        )
        var scanningValues: [Bool] = []
        let scanningToken = monitor.$scanning.sink { scanningValues.append($0) }
        defer { scanningToken.cancel() }
        let first = [device(id: "first", name: "First", kind: .drive)]
        let second = [device(id: "second", name: "Second", kind: .bluetooth)]

        monitor.refresh()
        await scanner.waitForInvocationCount(1)
        monitor.refresh()
        monitor.refresh()
        monitor.refresh()

        XCTAssertTrue(monitor.scanning)
        let firstInvocationCount = await scanner.invocations
        XCTAssertEqual(firstInvocationCount, 1)

        await scanner.completeNext(with: first)
        await publications.waitForCount(1)
        await scanner.waitForInvocationCount(2)

        XCTAssertTrue(monitor.scanning)
        XCTAssertEqual(monitor.devices.map(\.id), ["first"])
        XCTAssertEqual(scanningValues, [false, true])
        XCTAssertEqual(publications.events.map(\.scanning), [true])
        let firstMaximumConcurrency = await scanner.maximumConcurrentInvocations
        XCTAssertEqual(firstMaximumConcurrency, 1)

        await scanner.completeNext(with: second)
        await publications.waitForCount(2)

        XCTAssertFalse(monitor.scanning)
        XCTAssertEqual(scanningValues, [false, true, false])
        XCTAssertEqual(publications.events.map(\.scanning), [true, false])
        XCTAssertEqual(monitor.devices.map(\.id), ["second"])
        let finalInvocationCount = await scanner.invocations
        let finalMaximumConcurrency = await scanner.maximumConcurrentInvocations
        XCTAssertEqual(finalInvocationCount, 2)
        XCTAssertEqual(finalMaximumConcurrency, 1)
    }

    func testRequestDuringFollowUpSchedulesExactlyOneThirdPass() async {
        let scanner = ControlledDeviceScanner()
        let publications = DeviceScanPublicationObserver()
        let monitor = DeviceMonitor(
            scanner: { await scanner.scan() },
            onScanPublication: { devices, scanning in
                publications.record(devices: devices, scanning: scanning)
            }
        )

        monitor.refresh()
        await scanner.waitForInvocationCount(1)
        monitor.refresh()
        await scanner.completeNext(with: [device(id: "one", name: "One", kind: .drive)])
        await publications.waitForCount(1)
        await scanner.waitForInvocationCount(2)

        monitor.refresh()
        monitor.refresh()
        await scanner.completeNext(with: [device(id: "two", name: "Two", kind: .drive)])
        await publications.waitForCount(2)
        await scanner.waitForInvocationCount(3)

        XCTAssertTrue(monitor.scanning)
        XCTAssertEqual(monitor.devices.map(\.id), ["two"])
        let invocationCount = await scanner.invocations
        XCTAssertEqual(invocationCount, 3)

        await scanner.completeNext(with: [device(id: "three", name: "Three", kind: .drive)])
        await publications.waitForCount(3)

        XCTAssertFalse(monitor.scanning)
        XCTAssertEqual(monitor.devices.map(\.id), ["three"])
        let maximumConcurrency = await scanner.maximumConcurrentInvocations
        XCTAssertEqual(maximumConcurrency, 1)
    }

    func testPublicationPreservesOrderingAndEjectErrorPruning() async {
        let scanner = ControlledDeviceScanner()
        let publications = DeviceScanPublicationObserver()
        let monitor = DeviceMonitor(
            scanner: { await scanner.scan() },
            initialEjectErrors: ["drive": "kept", "gone": "removed"],
            onScanPublication: { devices, scanning in
                publications.record(devices: devices, scanning: scanning)
            }
        )
        let lowBattery = ConnectedDevice(
            id: "low",
            name: "Zeta",
            kind: .bluetooth,
            battery: 0.1,
            detail: "Connected",
            volumeURL: nil
        )
        let drive = device(id: "drive", name: "Alpha", kind: .drive)

        monitor.refresh()
        await scanner.waitForInvocationCount(1)
        await scanner.completeNext(with: [drive, lowBattery])
        await publications.waitForCount(1)

        XCTAssertEqual(monitor.devices.map(\.id), ["low", "drive"])
        XCTAssertEqual(monitor.ejectErrors, ["drive": "kept"])
        XCTAssertEqual(publications.events.map(\.deviceIDs), [["low", "drive"]])
        XCTAssertEqual(publications.events.map(\.scanning), [false])
    }

    private func device(id: String, name: String, kind: ConnectedDevice.Kind) -> ConnectedDevice {
        ConnectedDevice(
            id: id,
            name: name,
            kind: kind,
            battery: nil,
            detail: "Connected",
            volumeURL: kind == .drive ? URL(fileURLWithPath: "/Volumes/\(name)") : nil
        )
    }
}

@MainActor
private final class DeviceScanPublicationObserver {
    struct Event {
        let deviceIDs: [String]
        let scanning: Bool
    }

    private struct Waiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var events: [Event] = []
    private var waiters: [Waiter] = []

    func record(devices: [ConnectedDevice], scanning: Bool) {
        events.append(Event(deviceIDs: devices.map(\.id), scanning: scanning))
        let satisfied = waiters.filter { events.count >= $0.target }
        waiters.removeAll { events.count >= $0.target }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ target: Int) async {
        guard events.count < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(target: target, continuation: continuation))
        }
    }
}

private actor ControlledDeviceScanner {
    private struct PendingInvocation {
        let continuation: CheckedContinuation<[ConnectedDevice], Never>
    }

    private struct InvocationWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var pending: [PendingInvocation] = []
    private var waiters: [InvocationWaiter] = []
    private var activeInvocations = 0
    private(set) var invocations = 0
    private(set) var maximumConcurrentInvocations = 0

    func scan() async -> [ConnectedDevice] {
        invocations += 1
        activeInvocations += 1
        maximumConcurrentInvocations = max(maximumConcurrentInvocations, activeInvocations)

        return await withCheckedContinuation { continuation in
            pending.append(PendingInvocation(continuation: continuation))
            resumeSatisfiedWaiters()
        }
    }

    func waitForInvocationCount(_ target: Int) async {
        guard invocations < target else { return }
        await withCheckedContinuation { continuation in
            waiters.append(InvocationWaiter(target: target, continuation: continuation))
        }
    }

    func completeNext(with devices: [ConnectedDevice]) {
        precondition(!pending.isEmpty, "No controlled device scan is pending")
        let invocation = pending.removeFirst()
        activeInvocations -= 1
        invocation.continuation.resume(returning: devices)
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter { invocations >= $0.target }
        waiters.removeAll { invocations >= $0.target }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
