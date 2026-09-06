import XCTest
@testable import Geraldine

final class GPUSamplerTests: XCTestCase {
    func testUtilizationNormalizesDriverPercentIncludingIdle() {
        XCTAssertEqual(GPUSampler.utilization(from: ["Device Utilization %": 42.5]), 0.425)
        XCTAssertEqual(GPUSampler.utilization(from: ["Device Utilization %": 0]), 0)
        XCTAssertEqual(GPUSampler.utilization(from: ["Device Utilization %": 100]), 1)
    }

    func testUnavailableOrInvalidCountersDoNotBecomeIdleReadings() {
        for statistics: [String: Any] in [[:], ["Renderer Utilization %": 20],
            ["Device Utilization %": -1], ["Device Utilization %": 101],
            ["Device Utilization %": Double.nan], ["Device Utilization %": true],
            ["Device Utilization %": "50"]] {
            XCTAssertNil(GPUSampler.utilization(from: statistics))
        }
    }
}

extension GPUSamplerTests {
    func testAlternateDriverCounterAndPrimaryPrecedence() {
        XCTAssertEqual(GPUSampler.utilization(from: ["GPU Activity(%)": 73]), 0.73)
        XCTAssertEqual(GPUSampler.utilization(from: ["Device Utilization %": 0, "GPU Activity(%)": 73]), 0)
        XCTAssertEqual(GPUSampler.utilization(from: ["Device Utilization %": -1, "GPU Activity(%)": 73]), 0.73)
        XCTAssertNil(GPUSampler.utilization(from: ["GPU Activity(%)": Double.infinity]))
    }

    func testAppleAndPCIDeviceNames() {
        XCTAssertEqual(GPUSampler.modelName("Apple M2"), "Apple M2")
        XCTAssertEqual(GPUSampler.modelName(Data("AMD Radeon\0\0".utf8)), "AMD Radeon")
        XCTAssertNil(GPUSampler.modelName(Data([0xff])))
        XCTAssertNil(GPUSampler.modelName(" \0 "))
    }
}
