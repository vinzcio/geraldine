import XCTest
@testable import Geraldine

final class KeyboardTransportReducerTests: XCTestCase {
    func testClassifierUsesTransportWhenBluetoothSharesWiredProductName() {
        XCTAssertEqual(
            KeyboardTransportClassifier.classify(
                product: "Akko Multi-modes Keyboard-B",
                transport: "Bluetooth Low Energy"
            ),
            .bluetooth
        )
    }

    func testClassifierRejectsUnrelatedBluetoothKeyboards() {
        XCTAssertNil(
            KeyboardTransportClassifier.classify(
                product: "MacBook Keyboard",
                transport: "Bluetooth"
            )
        )
    }

    func testInitialSnapshotEstablishesSilentBaseline() {
        var reducer = KeyboardTransportReducer()

        XCTAssertNil(reducer.consume(sample(wired: (12, 120), wireless: (4, 40))))
        XCTAssertEqual(reducer.currentTransport, .wired)
    }

    func testWiredActivityDoesNotDuplicateCurrentTransport() {
        var reducer = KeyboardTransportReducer()
        _ = reducer.consume(sample(wired: (12, 120), wireless: (4, 40)))

        XCTAssertNil(reducer.consume(sample(wired: (14, 140), wireless: (4, 40))))
    }

    func testReceiverActivityConfirms24GHzSwitch() {
        var reducer = KeyboardTransportReducer()
        _ = reducer.consume(sample(wired: (12, 120), wireless: (4, 40)))

        XCTAssertEqual(
            reducer.consume(sample(wired: (14, 140), wireless: (6, 160))),
            .wireless24GHz
        )
        XCTAssertEqual(reducer.currentTransport, .wireless24GHz)
    }

    func testIdleReceiverPresenceDoesNotCauseSwitch() {
        var reducer = KeyboardTransportReducer()
        _ = reducer.consume(sample(wired: (12, 120), wireless: (4, 40)))

        XCTAssertNil(reducer.consume(sample(wired: (13, 130), wireless: (4, 40))))
        XCTAssertEqual(reducer.currentTransport, .wired)
    }

    func testCounterResetDoesNotCauseFalseSwitch() {
        var reducer = KeyboardTransportReducer()
        _ = reducer.consume(sample(wired: (12, 120), wireless: (40, 400)))

        XCTAssertNil(reducer.consume(sample(wired: (12, 120), wireless: (1, 5))))
        XCTAssertEqual(reducer.currentTransport, .wireless24GHz)
    }

    func testBluetoothActivityCanBecomeConfirmedTransport() {
        var reducer = KeyboardTransportReducer()
        _ = reducer.consume(KeyboardTransportSample(activities: [
            .wired: .init(inputReportCount: 12, lastInputReportTime: 120),
            .bluetooth: .init(inputReportCount: 3, lastInputReportTime: 30)
        ]))

        let change = reducer.consume(KeyboardTransportSample(activities: [
            .wired: .init(inputReportCount: 12, lastInputReportTime: 120),
            .bluetooth: .init(inputReportCount: 5, lastInputReportTime: 150)
        ]))

        XCTAssertEqual(change, .bluetooth)
    }

    func testAllInterfacesDisappearingReportsDisconnectedOnce() {
        var reducer = KeyboardTransportReducer()
        _ = reducer.consume(sample(wired: (12, 120), wireless: nil))

        XCTAssertEqual(reducer.consume(.empty), .disconnected)
        XCTAssertNil(reducer.consume(.empty))
    }

    func testCurrentInterfaceDisappearingReportsDisconnectedWhenIdleInterfaceRemains() {
        var reducer = KeyboardTransportReducer()
        _ = reducer.consume(sample(wired: (12, 120), wireless: (4, 40)))

        XCTAssertEqual(
            reducer.consume(sample(wired: nil, wireless: (4, 40))),
            .disconnected
        )
        XCTAssertNil(reducer.currentTransport)
    }

    private func sample(
        wired: (UInt64, UInt64)?,
        wireless: (UInt64, UInt64)?
    ) -> KeyboardTransportSample {
        var activities: [KeyboardTransport: KeyboardTransportActivity] = [:]
        if let wired {
            activities[.wired] = .init(
                inputReportCount: wired.0,
                lastInputReportTime: wired.1
            )
        }
        if let wireless {
            activities[.wireless24GHz] = .init(
                inputReportCount: wireless.0,
                lastInputReportTime: wireless.1
            )
        }
        return KeyboardTransportSample(activities: activities)
    }
}
