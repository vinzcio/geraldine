import XCTest
@testable import Geraldine

final class ActivityExplorationTests: XCTestCase {
    func testInspectionDoesNotInventValuesAcrossGapsOrSessions() {
        let firstSession = UUID(), secondSession = UUID()
        let samples = [
            MetricSample(timestamp: 10, value: 0.2, sessionID: firstSession),
            MetricSample(timestamp: 12, value: 0.4, sessionID: firstSession),
            MetricSample(timestamp: 20, value: 0.8, sessionID: firstSession),
            MetricSample(timestamp: 22, value: 0.6, sessionID: secondSession),
            MetricSample(timestamp: 24, value: 0.5, sessionID: secondSession)
        ]
        let timeline = TimelineWindow(end: 30, duration: 30)
        func inspect(_ time: Double) -> MetricSample? {
            ChartInspection.sample(at: time, samples: samples, timeline: timeline, gapThreshold: 3)
        }
        XCTAssertEqual(inspect(11.5)?.value, 0.4)
        XCTAssertNil(inspect(16), "A missing interval must not borrow a neighboring measurement")
        XCTAssertNil(inspect(21), "Separate monitoring sessions must not be joined")
        XCTAssertNil(inspect(5), "History before the first sample is unavailable")
        XCTAssertNil(inspect(29), "History after the final sample is unavailable")
        XCTAssertNil(inspect(.nan))
        XCTAssertEqual(inspect(20)?.value, 0.8)
    }

    func testSharedTimeInspectsDifferentSeriesWithoutChangingTheirTimestamps() throws {
        let timeline = TimelineWindow(end: 100, duration: 20)
        let time = try XCTUnwrap(ChartInspection.timestamp(fraction: 0.5, in: timeline))
        let cpu = [MetricSample(timestamp: 89, value: 0.3), MetricSample(timestamp: 91, value: 0.7)]
        let memory = [MetricSample(timestamp: 88, value: 0.5), MetricSample(timestamp: 92, value: 0.6)]
        XCTAssertEqual(time, 90)
        XCTAssertEqual(ChartInspection.sample(at: time, samples: cpu, timeline: timeline, gapThreshold: 5)?.timestamp, 89)
        XCTAssertEqual(ChartInspection.sample(at: time, samples: memory, timeline: timeline, gapThreshold: 5)?.timestamp, 88)
        XCTAssertEqual(ChartInspection.timestamp(fraction: -1, in: timeline), 80)
        XCTAssertEqual(ChartInspection.timestamp(fraction: 2, in: timeline), 100)
        XCTAssertNil(ChartInspection.timestamp(fraction: .infinity, in: timeline))
    }

    func testProcessesGroupByOuterBundleAndKeepUnrelatedNamesSeparate() throws {
        let processes = [
            ProcUsage(id: 1, name: "Editor", cpu: 20, mem: 2,
                      executablePath: "/Applications/Editor.app/Contents/MacOS/Editor"),
            ProcUsage(id: 2, name: "Renderer", cpu: 100, mem: 3,
                      executablePath: "/Applications/Editor.app/Contents/Frameworks/Helper.app/Contents/MacOS/Renderer"),
            ProcUsage(id: 3, name: "Renderer", cpu: 4, mem: 9,
                      executablePath: "/Applications/Other.app/Contents/MacOS/Renderer"),
            ProcUsage(id: 4, name: "Renderer", cpu: 0, mem: 1, executablePath: "/usr/bin/Renderer")
        ]
        let groups = ProcessGroup.ranked(processes, byMemory: false)
        XCTAssertEqual(groups.count, 3)
        let editor = try XCTUnwrap(groups.first)
        XCTAssertEqual(editor.name, "Editor")
        XCTAssertEqual(editor.cpu, 120)
        XCTAssertEqual(editor.memory, 5)
        XCTAssertEqual(editor.processes.map(\.id), [1, 2])
        XCTAssertEqual(ProcessGroup.ranked(processes, byMemory: true).first?.name, "Other")
        XCTAssertEqual(ProcessGroup.ranked(processes, byMemory: false, query: "editor 2").map(\.name), ["Editor"])
        XCTAssertEqual(ProcessGroup.ranked(processes, byMemory: false, query: " rEnDeReR ").count, 3)
        XCTAssertTrue(ProcessGroup.ranked(processes, byMemory: false, query: "missing").isEmpty)
    }

    @MainActor
    func testExpansionAndSearchReachBeyondFirstEightGroups() {
        let vm = ActivityViewModel()
        vm.consumers = (1...12).map { ProcUsage(id: Int32($0), name: "Worker \($0)", cpu: Double($0), mem: Double(13 - $0)) }
        XCTAssertEqual(vm.visibleGroups.count, 8)
        XCTAssertEqual(vm.visibleGroups.first?.name, "Worker 12")
        vm.showsAll = true
        XCTAssertEqual(vm.visibleGroups.count, 12)
        vm.showsAll = false
        vm.query = "Worker 1"
        XCTAssertTrue(vm.visibleGroups.contains { $0.name == "Worker 1" })
        vm.query = ""
        vm.sortByMemory = true
        XCTAssertEqual(vm.visibleGroups.first?.name, "Worker 1")
    }

    func testCommandSearchFindsDestinationsAndOnlyExplicitRefreshAction() throws {
        XCTAssertEqual(Set(GeraldineCommand.all.map(\.id)).count, GeraldineCommand.all.count)
        XCTAssertEqual(GeraldineCommand.matching("show memory").first?.action, .activity(.memory))
        XCTAssertEqual(GeraldineCommand.matching("find large").first?.action, .module(.largeFiles))
        XCTAssertEqual(GeraldineCommand.matching("keep awake").first?.action, .module(.keepAwake))
        XCTAssertEqual(GeraldineCommand.matching("refresh codex").first?.action, .refreshCodingUsage)
        XCTAssertEqual(GeraldineCommand.matching("  CODING usage ").first?.action, .module(.codingUsage))
        XCTAssertTrue(GeraldineCommand.matching("not-a-real-command").isEmpty)
        let modules = GeraldineCommand.all.compactMap { command -> Module? in
            if case .module(let module) = command.action { return module }
            return nil
        }
        XCTAssertEqual(Set(modules), Set(Module.allCases))
    }
}
