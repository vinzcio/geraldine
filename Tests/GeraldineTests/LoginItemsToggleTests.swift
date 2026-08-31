import XCTest
@testable import Geraldine

@MainActor
final class LoginItemsToggleTests: XCTestCase {
    func testEnabledToDisabledCollisionPreservesBothFilesAndRows() async throws {
        try await assertCollisionPreservesBothFilesAndRows(selectedIsEnabled: true)
    }

    func testDisabledToEnabledCollisionPreservesBothFilesAndRows() async throws {
        try await assertCollisionPreservesBothFilesAndRows(selectedIsEnabled: false)
    }

    func testParentCreationFailureRequestsNoMoveAndPublishesFailure() async throws {
        let fixture = try ToggleFixture()
        defer { fixture.remove() }

        let sourceURL = fixture.enabledDirectory.appendingPathComponent("com.example.agent.plist")
        let sourceData = Data("enabled".utf8)
        try sourceData.write(to: sourceURL)
        let item = makeItem(at: sourceURL, enabled: true)
        let fileOperator = ToggleFileOperatorSpy()
        fileOperator.createError = ToggleInjectedError(message: "Directory unavailable")
        var rescanCount = 0
        let viewModel = makeViewModel(fixture: fixture, fileOperator: fileOperator) {
            rescanCount += 1
        }
        viewModel.items = [item]

        viewModel.toggle(item)
        await waitForToggleToFinish(viewModel, item: item)

        XCTAssertEqual(fileOperator.existenceChecks,
                       [fixture.disabledDirectory.appendingPathComponent(sourceURL.lastPathComponent)])
        XCTAssertEqual(fileOperator.createdDirectories, [fixture.disabledDirectory])
        XCTAssertTrue(fileOperator.moves.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(viewModel.items, [item])
        XCTAssertEqual(rescanCount, 0)
        assertFailure(viewModel, item: item, contains: "Directory unavailable")
    }

    func testMoveFailureLeavesSourceAndRowUnchangedAndPublishesFailure() async throws {
        let fixture = try ToggleFixture()
        defer { fixture.remove() }

        let sourceURL = fixture.enabledDirectory.appendingPathComponent("com.example.agent.plist")
        let destinationURL = fixture.disabledDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let sourceData = Data("enabled".utf8)
        try sourceData.write(to: sourceURL)
        let item = makeItem(at: sourceURL, enabled: true)
        let fileOperator = ToggleFileOperatorSpy()
        fileOperator.moveError = ToggleInjectedError(message: "Move unavailable")
        var rescanCount = 0
        let viewModel = makeViewModel(fixture: fixture, fileOperator: fileOperator) {
            rescanCount += 1
        }
        viewModel.items = [item]

        viewModel.toggle(item)
        await waitForToggleToFinish(viewModel, item: item)

        XCTAssertEqual(fileOperator.moves, [.init(source: sourceURL, destination: destinationURL)])
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(viewModel.items, [item])
        XCTAssertEqual(rescanCount, 0)
        assertFailure(viewModel, item: item, contains: "Move unavailable")
    }

    func testDestinationCreatedAfterCheckIsNotDeletedOrOverwritten() async throws {
        let fixture = try ToggleFixture()
        defer { fixture.remove() }

        let sourceURL = fixture.enabledDirectory.appendingPathComponent("com.example.agent.plist")
        let destinationURL = fixture.disabledDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let sourceData = Data("selected source".utf8)
        let racedData = Data("racing destination".utf8)
        try sourceData.write(to: sourceURL)
        let item = makeItem(at: sourceURL, enabled: true)
        let fileOperator = ToggleFileOperatorSpy()
        fileOperator.destinationDataCreatedDuringMove = racedData
        var rescanCount = 0
        let viewModel = makeViewModel(fixture: fixture, fileOperator: fileOperator) {
            rescanCount += 1
        }
        viewModel.items = [item]

        viewModel.toggle(item)
        await waitForToggleToFinish(viewModel, item: item)

        XCTAssertEqual(fileOperator.moves, [.init(source: sourceURL, destination: destinationURL)])
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        XCTAssertEqual(try Data(contentsOf: destinationURL), racedData)
        XCTAssertEqual(viewModel.items, [item])
        XCTAssertEqual(rescanCount, 0)
        assertFailure(viewModel, item: item, contains: "Could not disable")
    }

    func testSuccessfulDisableMovesOnceAndPreservesPublishedBehavior() async throws {
        try await assertSuccessfulToggle(selectedIsEnabled: true)
    }

    func testSuccessfulEnableMovesOnceAndPreservesPublishedBehavior() async throws {
        try await assertSuccessfulToggle(selectedIsEnabled: false)
    }

    private func assertCollisionPreservesBothFilesAndRows(selectedIsEnabled: Bool) async throws {
        let fixture = try ToggleFixture()
        defer { fixture.remove() }

        let filename = "com.example.agent.plist"
        let enabledURL = fixture.enabledDirectory.appendingPathComponent(filename)
        let disabledURL = fixture.disabledDirectory.appendingPathComponent(filename)
        let enabledData = Data("enabled bytes".utf8)
        let disabledData = Data("disabled bytes".utf8)
        try enabledData.write(to: enabledURL)
        try disabledData.write(to: disabledURL)
        let enabledItem = makeItem(at: enabledURL, enabled: true)
        let disabledItem = makeItem(at: disabledURL, enabled: false)
        let selected = selectedIsEnabled ? enabledItem : disabledItem
        let originalRows = [enabledItem, disabledItem]
        let fileOperator = ToggleFileOperatorSpy()
        var rescanCount = 0
        let viewModel = makeViewModel(fixture: fixture, fileOperator: fileOperator) {
            rescanCount += 1
        }
        viewModel.items = originalRows

        viewModel.toggle(selected)
        await waitForToggleToFinish(viewModel, item: selected)

        let expectedDestination = selectedIsEnabled ? disabledURL : enabledURL
        XCTAssertEqual(fileOperator.existenceChecks, [expectedDestination])
        XCTAssertTrue(fileOperator.createdDirectories.isEmpty)
        XCTAssertTrue(fileOperator.moves.isEmpty)
        XCTAssertEqual(try Data(contentsOf: enabledURL), enabledData)
        XCTAssertEqual(try Data(contentsOf: disabledURL), disabledData)
        XCTAssertEqual(viewModel.items, originalRows)
        XCTAssertEqual(rescanCount, 0)

        let verb = selectedIsEnabled ? "disable" : "enable"
        let expectedMessage = "Could not \(verb) \(selected.displayName): A launch item named \(filename) already exists there. Neither item was changed."
        XCTAssertEqual(viewModel.actionState(for: selected), .failure(expectedMessage))
        XCTAssertEqual(viewModel.lastError, expectedMessage)
        XCTAssertEqual(viewModel.latestOutcome?.itemID, selected.id)
        XCTAssertEqual(viewModel.latestOutcome?.message, expectedMessage)
        XCTAssertEqual(viewModel.latestOutcome?.kind, .failure)
    }

    private func assertSuccessfulToggle(selectedIsEnabled: Bool) async throws {
        let fixture = try ToggleFixture()
        defer { fixture.remove() }

        let sourceDirectory = selectedIsEnabled ? fixture.enabledDirectory : fixture.disabledDirectory
        let destinationDirectory = selectedIsEnabled ? fixture.disabledDirectory : fixture.enabledDirectory
        let sourceURL = sourceDirectory.appendingPathComponent("com.example.agent.plist")
        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        let sourceData = Data("selected bytes".utf8)
        try sourceData.write(to: sourceURL)
        let item = makeItem(at: sourceURL, enabled: selectedIsEnabled)
        let fileOperator = ToggleFileOperatorSpy()
        var rescanCount = 0
        let viewModel = makeViewModel(fixture: fixture, fileOperator: fileOperator) {
            rescanCount += 1
        }
        viewModel.items = [item]

        viewModel.toggle(item)
        await waitForToggleToFinish(viewModel, item: item)

        XCTAssertEqual(fileOperator.existenceChecks, [destinationURL])
        XCTAssertEqual(fileOperator.createdDirectories, [destinationDirectory])
        XCTAssertEqual(fileOperator.moves, [.init(source: sourceURL, destination: destinationURL)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: destinationURL), sourceData)
        XCTAssertEqual(rescanCount, 1)
        XCTAssertNil(viewModel.lastError)

        let expectedMessage = "\(selectedIsEnabled ? "Disabled" : "Enabled") \(item.displayName)."
        XCTAssertEqual(viewModel.actionState(for: item), .success(expectedMessage))
        XCTAssertEqual(viewModel.latestOutcome?.itemID, item.id)
        XCTAssertEqual(viewModel.latestOutcome?.message, expectedMessage)
        XCTAssertEqual(viewModel.latestOutcome?.kind, .success)
        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(viewModel.items[0].id, item.id)
        XCTAssertEqual(viewModel.items[0].plistURL, destinationURL)
        XCTAssertEqual(viewModel.items[0].enabled, !selectedIsEnabled)

        // The existing delayed-clear tasks must not erase success in the same turn.
        await Task.yield()
        XCTAssertEqual(viewModel.actionState(for: item), .success(expectedMessage))
        XCTAssertEqual(viewModel.latestOutcome?.message, expectedMessage)
    }

    private func makeViewModel(
        fixture: ToggleFixture,
        fileOperator: ToggleFileOperatorSpy,
        toggleRescan: @escaping @MainActor () -> Void
    ) -> LoginItemsViewModel {
        LoginItemsViewModel(
            toggleFileOperator: fileOperator,
            disabledDirectory: fixture.disabledDirectory,
            userAgentsDirectory: fixture.enabledDirectory,
            toggleRescan: toggleRescan
        )
    }

    private func makeItem(at url: URL, enabled: Bool) -> LaunchItem {
        LaunchItem(label: "com.example.agent", program: "/tmp/example",
                   plistURL: url, scope: .user, enabled: enabled)
    }

    private func waitForToggleToFinish(_ viewModel: LoginItemsViewModel, item: LaunchItem) async {
        for _ in 0..<200 {
            if viewModel.actionState(for: item) != .working { return }
            await Task.yield()
        }
        XCTFail("Toggle did not leave its working state after deterministic yields")
    }

    private func assertFailure(
        _ viewModel: LoginItemsViewModel,
        item: LaunchItem,
        contains expectedText: String
    ) {
        guard let state = viewModel.actionState(for: item),
              case .failure(let message) = state else {
            return XCTFail("Expected a failure state")
        }
        XCTAssertTrue(message.contains(expectedText), "Unexpected failure: \(message)")
        XCTAssertEqual(viewModel.lastError, message)
        XCTAssertEqual(viewModel.latestOutcome?.itemID, item.id)
        XCTAssertEqual(viewModel.latestOutcome?.message, message)
        XCTAssertEqual(viewModel.latestOutcome?.kind, .failure)
    }
}

private final class ToggleFileOperatorSpy: LoginItemToggleFileOperating {
    struct Move: Equatable {
        let source: URL
        let destination: URL
    }

    var createError: Error?
    var moveError: Error?
    var destinationDataCreatedDuringMove: Data?
    private(set) var existenceChecks: [URL] = []
    private(set) var createdDirectories: [URL] = []
    private(set) var moves: [Move] = []

    private let fileManager = FileManager.default

    func itemExists(at url: URL) -> Bool {
        existenceChecks.append(url)
        return fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(at url: URL) throws {
        createdDirectories.append(url)
        if let createError { throw createError }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        moves.append(.init(source: source, destination: destination))
        if let destinationDataCreatedDuringMove {
            try destinationDataCreatedDuringMove.write(to: destination)
        }
        if let moveError { throw moveError }
        try fileManager.moveItem(at: source, to: destination)
    }
}

private struct ToggleInjectedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class ToggleFixture {
    let root: URL
    let enabledDirectory: URL
    let disabledDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeraldineLoginItemsToggle-\(UUID().uuidString)")
        enabledDirectory = root.appendingPathComponent("LaunchAgents", isDirectory: true)
        disabledDirectory = root.appendingPathComponent("DisabledLaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: enabledDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
