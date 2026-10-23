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

    func testThermalPolicySamplesImmediatelyThenWaitsForInterval() {
        XCTAssertTrue(ThermalSamplePolicy.shouldSample(
            now: 100, lastSampleAt: nil, isDisplayed: true
        ))
        XCTAssertFalse(ThermalSamplePolicy.shouldSample(
            now: 103, lastSampleAt: 100, isDisplayed: true
        ))
        XCTAssertTrue(ThermalSamplePolicy.shouldSample(
            now: 105, lastSampleAt: 100, isDisplayed: true
        ))
    }

    func testThermalPolicyNeverSamplesWhileHidden() {
        XCTAssertFalse(ThermalSamplePolicy.shouldSample(
            now: 100, lastSampleAt: nil, isDisplayed: false
        ))
        XCTAssertFalse(ThermalSamplePolicy.shouldSample(
            now: 1_000, lastSampleAt: 1, isDisplayed: false
        ))
    }

    func testThermalPolicyRecoversFromABackwardsClock() {
        XCTAssertTrue(ThermalSamplePolicy.shouldSample(
            now: 50, lastSampleAt: 100, isDisplayed: true
        ))
    }

    func testThermalPolicyRejectsNonFiniteTime() {
        XCTAssertFalse(ThermalSamplePolicy.shouldSample(
            now: .nan, lastSampleAt: nil, isDisplayed: true
        ))
    }
}
