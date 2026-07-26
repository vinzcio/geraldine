import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Geraldine

struct ClipboardHistoryTests {

    // MARK: - Encrypted store

    @Test
    func encryptedStoreRoundTripsWithoutPlaintextOnDisk() async throws {
        try await withVault { store, directory in
            let (entry, payload) = makeCapture(text: "top secret clipboard value")

            try await store.save(entry, payload: payload)

            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(files.count == 2)
            for fileURL in files {
                let bytes = try Data(contentsOf: fileURL)
                #expect(bytes.range(of: Data(entry.preview.utf8)) == nil)
            }

            let result = try await store.load()
            #expect(result.corruptFileCount == 0)
            #expect(result.entries == [entry])
            let storedPayload = try await store.payload(for: entry.id)
            #expect(storedPayload == payload)
        }
    }

    @Test
    func encryptedStoreReportsCorruptionWithoutDeletingEvidence() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptURL = directory.appendingPathComponent("corrupt.gclip")
        try Data("not encrypted".utf8).write(to: corruptURL)
        let store = ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 0x1c, count: 32))

        let result = try await store.load()

        #expect(result.entries.isEmpty)
        #expect(result.corruptFileCount == 1)
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test
    func deletingEntryRemovesBothItsMetadataAndPayload() async throws {
        try await withVault { store, directory in
            let (first, firstPayload) = makeCapture(text: "first")
            let (second, secondPayload) = makeCapture(text: "second")
            try await store.save(first, payload: firstPayload)
            try await store.save(second, payload: secondPayload)

            try await store.delete(id: first.id)

            let result = try await store.load()
            #expect(result.entries == [second])
            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(remaining.allSatisfy { !$0.lastPathComponent.hasPrefix(first.id.uuidString.lowercased()) })
        }
    }

    @Test
    func deleteAllClearsPayloadsToo() async throws {
        try await withVault { store, directory in
            let (entry, payload) = makeCapture(text: "gone")
            try await store.save(entry, payload: payload)

            try await store.deleteAll()

            let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            #expect(remaining.isEmpty)
        }
    }

    @Test
    func metadataOnlySaveLeavesThePayloadBlobUntouched() async throws {
        try await withVault { store, directory in
            var (entry, payload) = makeCapture(text: "pin me")
            try await store.save(entry, payload: payload)
            let payloadURL = directory.appendingPathComponent("\(entry.id.uuidString.lowercased()).gclipdata")
            let originalBytes = try Data(contentsOf: payloadURL)

            entry.isPinned = true
            try await store.save(entry)

            let payloadBytes = try Data(contentsOf: payloadURL)
            #expect(payloadBytes == originalBytes)
            let reloaded = try await store.load()
            #expect(reloaded.entries.first?.isPinned == true)
            let storedPayload = try await store.payload(for: entry.id)
            #expect(storedPayload == payload)
        }
    }

    @Test
    func orphanedPayloadsAreSweptAway() async throws {
        try await withVault { store, directory in
            let orphan = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).gclipdata")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("junk".utf8).write(to: orphan)

            try await store.removeOrphanedPayloads()

            #expect(!FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    /// Vaults written before the metadata/payload split must keep working.
    @Test
    func legacySingleFileEntriesMigrateOnLoad() async throws {
        try await withVault { store, directory in
            let legacy = LegacyClipboardHistoryEntry(
                id: UUID(),
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                lastUsedAt: nil,
                sourceBundleIdentifier: "com.example.source",
                sourceApplicationName: "Example",
                kind: .text,
                preview: "legacy value",
                contentFingerprint: "legacy-fingerprint",
                isPinned: true,
                items: [ClipboardCapturedItem(representations: [
                    ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("legacy value".utf8))
                ])]
            )
            try writeLegacyEntry(legacy, to: directory, keyData: vaultKey)

            let result = try await store.load()

            #expect(result.corruptFileCount == 0)
            let migrated = try #require(result.entries.first)
            #expect(migrated.id == legacy.id)
            #expect(migrated.isPinned)
            #expect(migrated.byteCount == 12)
            let storedPayload = try await store.payload(for: legacy.id)
            #expect(storedPayload.items == legacy.items)
            // A second load reads the rewritten record rather than migrating again.
            let secondLoad = try await store.load()
            #expect(secondLoad.entries == [migrated])
        }
    }

    // MARK: - Retention

    @Test
    func retentionPreservesPinnedEntries() {
        let now = Date()
        var (old, _) = makeCapture(text: "old", capturedAt: now.addingTimeInterval(-10 * 24 * 60 * 60))
        #expect(!ClipboardRetention.oneDay.keeps(old, now: now))

        old.isPinned = true
        #expect(ClipboardRetention.oneDay.keeps(old, now: now))
        #expect(ClipboardRetention.unlimited.keeps(old, now: now))
    }

    /// Retention runs off the last use, so an item you keep pasting never expires.
    @Test
    func retentionCountsFromTheLastUseNotTheFirstCopy() {
        let now = Date()
        var (entry, _) = makeCapture(text: "reused", capturedAt: now.addingTimeInterval(-10 * 24 * 60 * 60))
        #expect(!ClipboardRetention.oneDay.keeps(entry, now: now))

        entry.lastUsedAt = now.addingTimeInterval(-60)
        #expect(ClipboardRetention.oneDay.keeps(entry, now: now))
    }

    @Test
    func effectiveDateIsTheLaterOfCaptureAndUse() {
        let now = Date()
        var (entry, _) = makeCapture(text: "recopied", capturedAt: now)
        entry.lastUsedAt = now.addingTimeInterval(-3_600)
        // Re-copying something previously pasted must still read as "just now".
        #expect(entry.effectiveDate == now)
    }

    // MARK: - Capture classification

    @Test
    func linkDetectionRequiresARecognizedScheme() {
        #expect(ClipboardCaptureBuilder.isLink("https://example.com/a"))
        #expect(ClipboardCaptureBuilder.isLink("mailto:someone@example.com"))
        #expect(!ClipboardCaptureBuilder.isLink("TODO:ship the thing"))
        #expect(!ClipboardCaptureBuilder.isLink("TODO:ship"))
        #expect(!ClipboardCaptureBuilder.isLink("C:\\Users\\vincent"))
        #expect(!ClipboardCaptureBuilder.isLink("just some text"))
    }

    @Test
    func plainTextIsClassifiedAsTextNotLink() throws {
        let capture = try #require(ClipboardCaptureBuilder.make(rawItems: [
            ClipboardCapturedItem(representations: [
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("Note:remember".utf8))
            ])
        ]))
        #expect(capture.entry.kind == .text)
        #expect(capture.entry.preview == "Note:remember")
    }

    @Test
    func fileEntriesPreviewWithTheirFileNames() throws {
        let urls = ["file:///Users/vincent/Reports/Q4%20Summary.pdf", "file:///Users/vincent/notes.txt"]
        let capture = try #require(ClipboardCaptureBuilder.make(rawItems: urls.map {
            ClipboardCapturedItem(representations: [
                ClipboardRepresentation(typeIdentifier: "public.file-url", data: Data($0.utf8))
            ])
        }))
        #expect(capture.entry.kind == .files)
        #expect(capture.entry.preview == "Q4 Summary.pdf, notes.txt")
    }

    /// Uncompressed TIFF off the pasteboard used to blow past the size cap, which
    /// silently dropped screenshots.
    @Test
    func tiffImagesAreReEncodedAsPngAndThumbnailed() throws {
        let tiff = try #require(makeTIFF(width: 400, height: 200))
        let capture = try #require(ClipboardCaptureBuilder.make(rawItems: [
            ClipboardCapturedItem(representations: [
                ClipboardRepresentation(typeIdentifier: "public.tiff", data: tiff)
            ])
        ]))

        let storedTypes = capture.payload.items.flatMap(\.representations).map(\.typeIdentifier)
        #expect(storedTypes == ["public.png"])
        #expect(capture.entry.kind == .image)
        #expect(capture.entry.preview == "Image 400 × 200")
        #expect(capture.entry.byteCount < tiff.count)

        let thumbnail = try #require(capture.entry.thumbnail)
        let thumbnailSize = try #require(ClipboardImage.pixelSize(of: thumbnail))
        #expect(max(thumbnailSize.width, thumbnailSize.height) <= ClipboardImage.thumbnailMaximumPixel)
    }

    @Test
    func oversizedRepresentationsAreSkippedRatherThanStored() throws {
        var limits = ClipboardCaptureBuilder.Limits.default
        limits.maximumRepresentationBytes = 64
        let capture = try #require(ClipboardCaptureBuilder.make(
            rawItems: [ClipboardCapturedItem(representations: [
                ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data("keep".utf8)),
                ClipboardRepresentation(typeIdentifier: "public.html", data: Data(repeating: 0x41, count: 512))
            ])],
            limits: limits
        ))
        #expect(capture.payload.items.flatMap(\.representations).map(\.typeIdentifier) == ["public.utf8-plain-text"])
        #expect(capture.entry.byteCount == 4)
    }

    @Test
    func identicalContentProducesTheSameFingerprint() throws {
        let first = try #require(ClipboardCaptureBuilder.make(rawItems: [textItem("same")]))
        let second = try #require(ClipboardCaptureBuilder.make(rawItems: [textItem("same")]))
        let other = try #require(ClipboardCaptureBuilder.make(rawItems: [textItem("different")]))
        #expect(first.entry.contentFingerprint == second.entry.contentFingerprint)
        #expect(first.entry.contentFingerprint != other.entry.contentFingerprint)
        #expect(first.entry.id != second.entry.id)
    }

    // MARK: - Restoring to a pasteboard

    @Test @MainActor
    func restoringTextPutsTheOriginalStringBack() throws {
        let capture = try #require(ClipboardCaptureBuilder.make(rawItems: [textItem("round trip me")]))
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }

        #expect(ClipboardPasteboardWriter.write(capture.payload, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "round trip me")
    }

    /// Images are stored as PNG, but plenty of apps only read TIFF off the
    /// pasteboard, so restore has to synthesize one.
    @Test @MainActor
    func restoringAnImageAlsoOffersTiffForAppsThatNeedIt() throws {
        let tiff = try #require(makeTIFF(width: 60, height: 40))
        let capture = try #require(ClipboardCaptureBuilder.make(rawItems: [
            ClipboardCapturedItem(representations: [
                ClipboardRepresentation(typeIdentifier: "public.tiff", data: tiff)
            ])
        ]))
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }

        #expect(ClipboardPasteboardWriter.write(capture.payload, to: pasteboard))

        let types = Set(pasteboard.pasteboardItems?.flatMap(\.types).map(\.rawValue) ?? [])
        #expect(types.contains(ClipboardImage.pngType))
        #expect(types.contains(NSPasteboard.PasteboardType.tiff.rawValue))
    }

    @Test @MainActor
    func restoringAnEmptyPayloadReportsFailure() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        #expect(!ClipboardPasteboardWriter.write(ClipboardPayload(items: []), to: pasteboard))
    }

    // MARK: - Controller

    @Test @MainActor
    func controllerDefaultsToThreeMonthsAndEnablesShortcut() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        #expect(controller.retention == .threeMonths)
        #expect(controller.isEnabled)
        #expect(controller.shortcutEnabled)
    }

    @Test @MainActor
    func pinnedEntriesSortAboveEverythingElse() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        let now = Date()

        controller.ingest(capture(text: "oldest", at: now.addingTimeInterval(-300)))
        controller.ingest(capture(text: "middle", at: now.addingTimeInterval(-200)))
        controller.ingest(capture(text: "newest", at: now.addingTimeInterval(-100)))
        #expect(controller.entries.map(\.preview) == ["newest", "middle", "oldest"])

        let oldest = controller.entries[2]
        controller.togglePinned(oldest)
        #expect(controller.entries.map(\.preview) == ["oldest", "newest", "middle"])

        // A brand new copy must not jump above a pinned item.
        controller.ingest(capture(text: "brand new", at: now))
        #expect(controller.entries.map(\.preview) == ["oldest", "brand new", "newest", "middle"])
    }

    @Test @MainActor
    func recopyingAnItemPromotesItAndKeepsItsPin() throws {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        let now = Date()

        controller.ingest(capture(text: "recurring", at: now.addingTimeInterval(-300)))
        controller.ingest(capture(text: "filler", at: now.addingTimeInterval(-200)))
        let recurring = try #require(controller.entries.first(where: { $0.preview == "recurring" }))
        let originalID = recurring.id
        controller.togglePinned(recurring)

        controller.ingest(capture(text: "recurring", at: now))

        #expect(controller.entries.count == 2)
        let promoted = controller.entries[0]
        #expect(promoted.preview == "recurring")
        #expect(promoted.id == originalID)
        #expect(promoted.isPinned)
    }

    @Test @MainActor
    func evictionDropsTheOldestUnpinnedEntries() {
        let (controller, cleanup) = makeController(maximumEntryCount: 3)
        defer { cleanup() }
        let now = Date()

        controller.ingest(capture(text: "one", at: now.addingTimeInterval(-400)))
        let first = controller.entries[0]
        controller.togglePinned(first)
        for (offset, text) in ["two", "three", "four", "five"].enumerated() {
            controller.ingest(capture(text: text, at: now.addingTimeInterval(Double(offset) * 10 - 300)))
        }

        #expect(controller.entries.count == 3)
        #expect(controller.entries.map(\.preview) == ["one", "five", "four"])
    }

    @Test @MainActor
    func retentionChangesPruneStaleEntriesImmediately() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }
        let now = Date()

        controller.ingest(capture(text: "ancient", at: now.addingTimeInterval(-40 * 24 * 60 * 60)))
        controller.ingest(capture(text: "fresh", at: now))
        #expect(controller.entries.count == 2)

        controller.retention = .oneWeek

        #expect(controller.entries.map(\.preview) == ["fresh"])
    }

    @Test @MainActor
    func searchMatchesPreviewTextAndSourceApplication() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        controller.ingest(capture(text: "invoice total", at: Date(), applicationName: "Numbers"))
        controller.ingest(capture(text: "meeting notes", at: Date(), applicationName: "Notes"))

        #expect(controller.matchingEntries(query: "INVOICE").map(\.preview) == ["invoice total"])
        #expect(controller.matchingEntries(query: "numbers").map(\.preview) == ["invoice total"])
        #expect(controller.matchingEntries(query: "  ").count == 2)
        #expect(controller.matchingEntries(query: "", kind: .image).isEmpty)
    }

    @Test @MainActor
    func storedByteCountTracksWhatIsActuallyHeld() {
        let (controller, cleanup) = makeController()
        defer { cleanup() }

        controller.ingest(capture(text: "12345", at: Date()))
        controller.ingest(capture(text: "1234567890", at: Date()))

        #expect(controller.storedByteCount == 15)
    }

    // MARK: - Helpers

    private var vaultKey: Data { Data(repeating: 0x4a, count: 32) }

    /// A private pasteboard, so tests never disturb the user's real clipboard.
    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("GeraldineTests.\(UUID().uuidString)"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("geraldine-clipboard-\(UUID().uuidString)", isDirectory: true)
    }

    private func withVault(
        _ body: (ClipboardHistoryStore, URL) async throws -> Void
    ) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(ClipboardHistoryStore(directoryURL: directory, keyData: vaultKey), directory)
    }

    @MainActor
    private func makeController(
        maximumEntryCount: Int = 2_000
    ) -> (ClipboardHistoryController, () -> Void) {
        let suiteName = "ClipboardHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = temporaryDirectory()
        let controller = ClipboardHistoryController(
            defaults: defaults,
            store: ClipboardHistoryStore(directoryURL: directory, keyData: vaultKey),
            maximumEntryCount: maximumEntryCount
        )
        return (controller, {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func textItem(_ text: String) -> ClipboardCapturedItem {
        ClipboardCapturedItem(representations: [
            ClipboardRepresentation(typeIdentifier: "public.utf8-plain-text", data: Data(text.utf8))
        ])
    }

    private func capture(
        text: String,
        at date: Date,
        applicationName: String? = "Example"
    ) -> ClipboardCaptureBuilder.Capture {
        ClipboardCaptureBuilder.make(
            rawItems: [textItem(text)],
            source: .init(bundleIdentifier: "com.example.source", applicationName: applicationName),
            now: date
        )!
    }

    private func makeCapture(
        text: String,
        capturedAt: Date = Date()
    ) -> (ClipboardHistoryEntry, ClipboardPayload) {
        let built = capture(text: text, at: capturedAt)
        return (built.entry, built.payload)
    }

    private func makeTIFF(width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.current?.flushGraphics()
        return rep.representation(using: .tiff, properties: [:])
    }

    private func writeLegacyEntry(
        _ entry: LegacyClipboardHistoryEntry,
        to directory: URL,
        keyData: Data
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plaintext = try JSONEncoder().encode(entry)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        guard let combined = sealed.combined else {
            throw ClipboardHistoryError.unavailableStore("Could not seal the legacy fixture.")
        }
        let fileURL = directory
            .appendingPathComponent(entry.id.uuidString.lowercased())
            .appendingPathExtension("gclip")
        try combined.write(to: fileURL)
    }
}
