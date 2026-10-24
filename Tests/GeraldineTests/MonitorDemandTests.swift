import XCTest
@testable import Geraldine

final class MonitorDemandTests: XCTestCase {
    func testHiddenMetricsAreNotSampled() {
        let demand = MonitorDemand(showsThermal: false, showsGPU: false)
        XCTAssertFalse(demand.samplesThermal)
        XCTAssertFalse(demand.samplesGPU)
    }

    func testVisibleMetricsAreSampled() {
        let demand = MonitorDemand(showsThermal: true, showsGPU: true)
        XCTAssertTrue(demand.samplesThermal)
        XCTAssertTrue(demand.samplesGPU)
    }

    func testSleepingDisplaysPauseEveryExpensiveSample() {
        let demand = MonitorDemand(showsThermal: true, showsGPU: true, displaysAsleep: true)
        XCTAssertFalse(demand.samplesThermal)
        XCTAssertFalse(demand.samplesGPU)
    }

}
