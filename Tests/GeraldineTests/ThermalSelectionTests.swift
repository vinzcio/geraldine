import XCTest
@testable import Geraldine

final class ThermalSelectionTests: XCTestCase {
    func testUnrelatedHIDSensorsNeverBecomeCPUTemperature() {
        let sensors = [
            Thermal.Sensor(name: "gas gauge battery", temp: 32),
            Thermal.Sensor(name: "PMU tdie1", temp: 80),
            Thermal.Sensor(name: "GPU MTR Temp Sensor0", temp: 90),
            Thermal.Sensor(name: "SOC MTR Temp Sensor0", temp: 70),
            Thermal.Sensor(name: "NAND CH0 temp", temp: 40)
        ]
        let result = Thermal.summarize(sensors)
        XCTAssertFalse(result.available)
        XCTAssertEqual(result.cpuSource, "Unavailable")
        XCTAssertEqual(result.hidCPUCandidateCount, 0)
        XCTAssertEqual(result.sensors.count, sensors.count)
        XCTAssertEqual(result.battery, 32)
        XCTAssertEqual(result.storage, 40)
    }

    func testHIDCPUFallbackIncludesPerformanceAndEfficiencySensorsOnly() {
        let result = Thermal.summarize([
            .init(name: "pACC MTR Temp Sensor0", temp: 60),
            .init(name: "eACC MTR Temp Sensor0", temp: 40),
            .init(name: "PMU tdie1", temp: 90),
            .init(name: "GPU MTR Temp Sensor0", temp: 95)
        ])
        XCTAssertTrue(result.available)
        XCTAssertEqual(result.cpu, 60)
        XCTAssertEqual(result.cpuAverage, 50)
        XCTAssertEqual(result.cpuPeak, 60)
        XCTAssertEqual(result.hidCPUCandidateCount, 2)
        XCTAssertEqual(result.cpuSource, "HID CPU sensor peak")
    }

    func testRejectedSMCReadingDoesNotPublishZeroAsAvailable() {
        let result = Thermal.summarize([.init(name: "SMC Tp01", temp: 15)])
        XCTAssertFalse(result.available)
        XCTAssertEqual(result.cpuSource, "Unavailable")
        XCTAssertEqual(result.sensors.count, 1)
    }

    func testExistingSMCSelectionPrecedenceIsPreserved() {
        let result = Thermal.summarize([
            .init(name: "SMC TC0D", temp: 55),
            .init(name: "SMC Tp01", temp: 70),
            .init(name: "pACC MTR Temp Sensor0", temp: 80)
        ])
        XCTAssertTrue(result.available)
        XCTAssertEqual(result.cpu, 55)
        XCTAssertEqual(result.cpuSource, "SMC TC0D")
        XCTAssertEqual(result.cpuPeak, 80)
    }
}
