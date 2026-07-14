import XCTest
@testable import Geraldine

final class StoragePresentationTests: XCTestCase {
    func testCapacityClampsFreeSpaceToVolumeBounds() {
        XCTAssertEqual(StorageCapacity(total: 1_000, free: 1_200),
                       StorageCapacity(total: 1_000, free: 1_000))
        XCTAssertEqual(StorageCapacity(total: 1_000, free: -20),
                       StorageCapacity(total: 1_000, free: 0))
    }

    func testCapacityDerivesUsedSpaceAndFraction() {
        let capacity = StorageCapacity(total: 1_000, free: 250)

        XCTAssertEqual(capacity.used, 750)
        XCTAssertEqual(capacity.usedFraction, 0.75, accuracy: 0.000_001)
    }

    func testZeroCapacityNeverProducesInvalidFraction() {
        let capacity = StorageCapacity(total: 0, free: 100)

        XCTAssertEqual(capacity.free, 0)
        XCTAssertEqual(capacity.used, 0)
        XCTAssertEqual(capacity.usedFraction, 0)
    }

    func testStorageIsPresentedAsCapacityInsteadOfTimeSeries() {
        XCTAssertFalse(MetricKind.storage.isTimeSeries)
    }
}
