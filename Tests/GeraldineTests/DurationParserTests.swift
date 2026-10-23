import XCTest
import GeraldineControl

final class DurationParserTests: XCTestCase {
    func testIndefiniteForms() throws {
        for raw in ["indefinitely", "forever", "∞", "none"] {
            XCTAssertEqual(try DurationParser.parse(raw), .indefinite)
        }
    }

    func testBareMinutesAndCompoundUnits() throws {
        XCTAssertEqual(try DurationParser.parse("90"), .seconds(5_400))
        XCTAssertEqual(try DurationParser.parse("90m"), .seconds(5_400))
        XCTAssertEqual(try DurationParser.parse("1h30m"), .seconds(5_400))
        XCTAssertEqual(try DurationParser.parse("2 hours"), .seconds(7_200))
        XCTAssertEqual(try DurationParser.parse("1.5h"), .seconds(5_400))
        XCTAssertEqual(try DurationParser.parse("45s"), .seconds(45))
        XCTAssertEqual(try DurationParser.parse("1d"), .seconds(86_400))
    }

    func testInvalidAndTooLongDurationsAreRejected() {
        XCTAssertThrowsError(try DurationParser.parse(""))
        XCTAssertThrowsError(try DurationParser.parse("soon"))
        XCTAssertThrowsError(try DurationParser.parse("31d"))
        XCTAssertThrowsError(try DurationParser.parse("0s"))
    }

    func testFormattingMatchesTheHumanSurface() {
        XCTAssertEqual(DurationParser.format(0), "0s")
        XCTAssertEqual(DurationParser.format(45), "45s")
        XCTAssertEqual(DurationParser.format(90), "1m 30s")
        XCTAssertEqual(DurationParser.format(5_400), "1h 30m")
        XCTAssertEqual(DurationParser.format(86_400), "1d 0h")
    }

    func testErrorExitCodesMatchTheDocumentedContract() {
        XCTAssertEqual(ControlErrorPayload(code: .usage, message: "").exitCode, 2)
        XCTAssertEqual(ControlErrorPayload(code: .invalidValue, message: "").exitCode, 2)
        XCTAssertEqual(ControlErrorPayload(code: .notRunning, message: "").exitCode, 3)
        XCTAssertEqual(ControlErrorPayload(code: .unsupported, message: "").exitCode, 3)
        XCTAssertEqual(ControlErrorPayload(code: .permission, message: "").exitCode, 4)
        XCTAssertEqual(ControlErrorPayload(code: .failed, message: "").exitCode, 1)
    }
}
