import AppKit
import Combine
import CryptoKit
import Security

enum ClipboardRetention: String, CaseIterable, Codable, Identifiable {
    case oneDay
    case oneWeek
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear
    case unlimited

    static let defaultsKey = "clipboardHistoryRetention"
    static let defaultValue: ClipboardRetention = .threeMonths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oneDay: return "1 Day"
        case .oneWeek: return "1 Week"
        case .oneMonth: return "1 Month"
        case .threeMonths: return "3 Months"
        case .sixMonths: return "6 Months"
        case .oneYear: return "1 Year"
        case .unlimited: return "Unlimited"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .oneDay: return 24 * 60 * 60
        case .oneWeek: return 7 * 24 * 60 * 60
        case .oneMonth: return 30 * 24 * 60 * 60
        case .threeMonths: return 90 * 24 * 60 * 60
        case .sixMonths: return 180 * 24 * 60 * 60
        case .oneYear: return 365 * 24 * 60 * 60
        case .unlimited: return nil
        }
    }

    /// Retention is measured from the last time the entry was *used*, not first copied,
    /// so an item you keep reaching for never ages out from under you.
    func keeps(_ entry: ClipboardHistoryEntry, now: Date = Date()) -> Bool {
        guard !entry.isPinned, let timeInterval else { return true }
        return entry.effectiveDate >= now.addingTimeInterval(-timeInterval)
    }
}

enum ClipboardContentKind: String, Codable, CaseIterable, Identifiable {
    case text
    case richText
    case link
    case image
    case files
    case color
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Rich Text"
        case .link: return "Links"
        case .image: return "Images"
        case .files: return "Files"
        case .color: return "Colors"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .color: return "paintpalette"
        case .other: return "clipboard"
        }
    }
}

struct ClipboardRepresentation: Codable, Hashable, Sendable {
    let typeIdentifier: String
    let data: Data
}

struct ClipboardCapturedItem: Codable, Hashable, Sendable {
    let representations: [ClipboardRepresentation]
}

/// The heavy half of an entry. Kept on disk and read back only when an item is
/// actually restored, so a long history of screenshots never sits in memory.
struct ClipboardPayload: Codable, Hashable, Sendable {
    let items: [ClipboardCapturedItem]
}

/// The light half of an entry: everything the list and picker need to render.
struct ClipboardHistoryEntry: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var capturedAt: Date
    var lastUsedAt: Date?
    var sourceBundleIdentifier: String?
    var sourceApplicationName: String?
    var kind: ClipboardContentKind
    var preview: String
    var contentFingerprint: String
    var isPinned: Bool
    var byteCount: Int
    /// Downscaled PNG for image entries; nil for everything else.
    var thumbnail: Data?
    /// `#RRGGBB` for color entries; nil for everything else.
    var colorHex: String?

    init(
        id: UUID,
        capturedAt: Date,
        lastUsedAt: Date? = nil,
        sourceBundleIdentifier: String? = nil,
        sourceApplicationName: String? = nil,
        kind: ClipboardContentKind,
        preview: String,
        contentFingerprint: String,
        isPinned: Bool = false,
        byteCount: Int,
        thumbnail: Data? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.lastUsedAt = lastUsedAt
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceApplicationName = sourceApplicationName
        self.kind = kind
        self.preview = preview
        self.contentFingerprint = contentFingerprint
        self.isPinned = isPinned
        self.byteCount = byteCount
        self.thumbnail = thumbnail
        self.colorHex = colorHex
    }

    /// Re-copying an item you previously pasted must still count as "just now",
    /// so this is the later of the two timestamps rather than a plain fallback.
    var effectiveDate: Date { max(capturedAt, lastUsedAt ?? .distantPast) }

    /// `ByteCountFormatter` renders anything under a kilobyte as "0 KB", which is
    /// most text entries.
    var sizeDescription: String {
        byteCount < 1_024 ? "\(byteCount) bytes" : Fmt.size(Int64(byteCount))
    }

    var accessibilityLabel: String {
        "\(kind.label), \(preview), copied \(capturedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// The pre-split on-disk shape, still readable so existing vaults survive the upgrade.
struct LegacyClipboardHistoryEntry: Codable {
    let id: UUID
    var capturedAt: Date
    var lastUsedAt: Date?
    var sourceBundleIdentifier: String?
    var sourceApplicationName: String?
    var kind: ClipboardContentKind
    var preview: String
    var contentFingerprint: String
    var isPinned: Bool
    var items: [ClipboardCapturedItem]
}

struct ClipboardHistoryLoadResult {
    let entries: [ClipboardHistoryEntry]
    let corruptFileCount: Int
}

enum ClipboardHistoryError: LocalizedError {
    case keychain(OSStatus)
    case randomKeyGeneration(OSStatus)
    case unavailableStore(String)
    case missingPayload
    case emptyPasteboardEntry
    case accessibilityRequired

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "The clipboard encryption key is unavailable (Keychain status \(status))."
        case .randomKeyGeneration(let status):
            return "Geraldine could not create a clipboard encryption key (status \(status))."
        case .unavailableStore(let message):
            return message
        case .missingPayload:
            return "The stored contents for that clipboard item are missing."
        case .emptyPasteboardEntry:
            return "The clipboard did not contain a supported item."
        case .accessibilityRequired:
            return "Accessibility is required to paste automatically. The item was copied to the clipboard instead."
        }
    }
}

enum ClipboardVaultKey {
    private static let service = "com.vincent.geraldine.clipboard-vault"
    private static let account = "local-v1"
    private static let keySize = 32

    static func loadOrCreate() throws -> Data {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &item)
        if lookupStatus == errSecSuccess, let data = item as? Data, data.count == keySize {
            return data
        }
        guard lookupStatus == errSecItemNotFound else {
            throw ClipboardHistoryError.keychain(lookupStatus)
        }

        var bytes = [UInt8](repeating: 0, count: keySize)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else {
            throw ClipboardHistoryError.randomKeyGeneration(randomStatus)
        }
        let data = Data(bytes)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return try loadOrCreate()
        }
        guard addStatus == errSecSuccess else {
            throw ClipboardHistoryError.keychain(addStatus)
        }
        return data
    }
}

// MARK: - Encrypted store

actor ClipboardHistoryStore {
    private static let metadataExtension = "gclip"
    private static let payloadExtension = "gclipdata"

    private let directoryURL: URL
    private let key: SymmetricKey
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Payloads are mostly `Data`, which JSON would base64 into a third more bytes
    /// on disk. Binary plists store it as-is.
    private let payloadEncoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()
    private let payloadDecoder = PropertyListDecoder()
    private var directoryPrepared = false

    init(directoryURL: URL? = nil, keyData: Data) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.directoryURL = directoryURL
            ?? base
                .appendingPathComponent("Geraldine", isDirectory: true)
                .appendingPathComponent("ClipboardHistory", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        key = SymmetricKey(data: keyData)
    }

    func load() throws -> ClipboardHistoryLoadResult {
        try prepareDirectory()
        let files = try contents(withExtension: Self.metadataExtension)

        var entries: [ClipboardHistoryEntry] = []
        var corruptFileCount = 0
        entries.reserveCapacity(files.count)
        for fileURL in files {
            guard let plaintext = try? decrypt(contentsOf: fileURL) else {
                corruptFileCount += 1
                continue
            }
            if let entry = try? decoder.decode(ClipboardHistoryEntry.self, from: plaintext) {
                entries.append(entry)
            } else if let legacy = try? decoder.decode(LegacyClipboardHistoryEntry.self, from: plaintext) {
                let migrated = ClipboardCaptureBuilder.migrate(legacy: legacy)
                // Best effort: a failed rewrite just means we migrate again next launch.
                try? save(migrated.entry, payload: migrated.payload)
                entries.append(migrated.entry)
            } else {
                corruptFileCount += 1
            }
        }
        return ClipboardHistoryLoadResult(entries: entries, corruptFileCount: corruptFileCount)
    }

    /// Saves the metadata record, and the payload too when one is supplied.
    /// Pin/last-used edits pass `nil` so the heavy blob is never rewritten.
    func save(_ entry: ClipboardHistoryEntry, payload: ClipboardPayload? = nil) throws {
        try prepareDirectory()
        if let payload {
            try write(try payloadEncoder.encode(payload), to: payloadURL(for: entry.id))
        }
        try write(try encoder.encode(entry), to: metadataURL(for: entry.id))
    }

    func payload(for id: UUID) throws -> ClipboardPayload {
        let fileURL = payloadURL(for: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ClipboardHistoryError.missingPayload
        }
        let plaintext = try decrypt(contentsOf: fileURL)
        if let payload = try? payloadDecoder.decode(ClipboardPayload.self, from: plaintext) {
            return payload
        }
        // Payloads written before the switch to binary plists.
        return try decoder.decode(ClipboardPayload.self, from: plaintext)
    }

    func delete(id: UUID) throws {
        for fileURL in [metadataURL(for: id), payloadURL(for: id)] {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func delete(ids: [UUID]) throws {
        var firstFailure: Error?
        for id in ids {
            do {
                try delete(id: id)
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    func deleteAll() throws {
        try prepareDirectory()
        let files = try contents(withExtension: Self.metadataExtension)
            + contents(withExtension: Self.payloadExtension)
        for fileURL in files {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Drops payload blobs whose metadata record is gone — cheap self-healing for
    /// a crash between the two writes.
    func removeOrphanedPayloads() throws {
        let known = Set(try contents(withExtension: Self.metadataExtension).map { $0.deletingPathExtension().lastPathComponent })
        for fileURL in try contents(withExtension: Self.payloadExtension)
        where !known.contains(fileURL.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func contents(withExtension pathExtension: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == pathExtension }
    }

    private func decrypt(contentsOf fileURL: URL) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: try Data(contentsOf: fileURL))
        return try AES.GCM.open(sealedBox, using: key)
    }

    private func write(_ plaintext: Data, to fileURL: URL) throws {
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw ClipboardHistoryError.unavailableStore("Geraldine could not seal the clipboard entry.")
        }
        try combined.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    private func prepareDirectory() throws {
        // Every save would otherwise pay a stat plus a chmod, and saves happen on
        // every capture, pin toggle, and restore.
        if directoryPrepared { return }
        defer { directoryPrepared = true }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directoryURL.path) {
            // An existing vault may predate the permission attribute below.
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directoryURL.path
            )
            return
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    }

    /// The on-disk naming rule, in one place: `removeOrphanedPayloads` pairs
    /// metadata and payload files by stem, so the two must never diverge.
    private func url(for id: UUID, extension pathExtension: String) -> URL {
        directoryURL
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension(pathExtension)
    }

    private func metadataURL(for id: UUID) -> URL {
        url(for: id, extension: Self.metadataExtension)
    }

    private func payloadURL(for id: UUID) -> URL {
        url(for: id, extension: Self.payloadExtension)
    }
}

// MARK: - Image helpers

enum ClipboardImage {
    static let pngType = "public.png"
    /// Roughly 2× the largest size a thumbnail is drawn at, so Retina stays crisp
    /// without carrying a second copy of the image around in memory.
    static let thumbnailMaximumPixel: CGFloat = 128

    static func pixelSize(of data: Data) -> CGSize? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// TIFF off the pasteboard is uncompressed — a Retina screenshot easily runs
    /// past any sane cap — so images are re-encoded before they are ever stored.
    static func pngData(from data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func tiffData(from pngData: Data) -> Data? {
        NSBitmapImageRep(data: pngData)?.representation(using: .tiff, properties: [:])
    }

    static func thumbnailPNG(from data: Data, maximumPixel: CGFloat = thumbnailMaximumPixel) -> Data? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        let sourceWidth = CGFloat(source.pixelsWide)
        let sourceHeight = CGFloat(source.pixelsHigh)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, maximumPixel / max(sourceWidth, sourceHeight))
        let width = Int(max(1, (sourceWidth * scale).rounded()))
        let height = Int(max(1, (sourceHeight * scale).rounded()))
        guard let target = NSBitmapImageRep(
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
        target.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()
        return target.representation(using: .png, properties: [:])
    }

    static func hex(fromArchivedColor data: Data) -> String? {
        guard let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data),
              let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return "#" + components.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - Capture

/// Turns raw pasteboard representations into a stored entry.
///
/// Takes already-extracted representations rather than an `NSPasteboard`, so the
/// classification, preview, and size rules can be exercised from tests without a
/// live pasteboard. It still reads `NSPasteboard.PasteboardType` constants and
/// calls into `ClipboardImage`, so tests do need AppKit.
enum ClipboardCaptureBuilder {
    struct Limits {
        /// Largest single stored representation, measured after image re-encoding.
        var maximumRepresentationBytes = 16 * 1_024 * 1_024
        /// Largest total stored size for one clipboard change.
        var maximumEntryBytes = 24 * 1_024 * 1_024
        /// Largest source image we are willing to decode in order to re-encode it.
        var maximumSourceImageBytes = 128 * 1_024 * 1_024

        static let `default` = Limits()
    }

    struct Capture {
        let entry: ClipboardHistoryEntry
        let payload: ClipboardPayload
    }

    struct Source {
        var bundleIdentifier: String?
        var applicationName: String?

        static let unknown = Source()
    }

    private static let linkSchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "sftp", "ssh", "mailto", "tel", "magnet", "file"
    ]

    static func make(
        rawItems: [ClipboardCapturedItem],
        source: Source = .unknown,
        now: Date = Date(),
        id: UUID = UUID(),
        limits: Limits = .default
    ) -> Capture? {
        var storedItems: [ClipboardCapturedItem] = []
        var totalBytes = 0

        for rawItem in rawItems {
            var representations: [ClipboardRepresentation] = []
            for representation in normalizeImages(in: rawItem.representations, limits: limits) {
                guard !representation.data.isEmpty,
                      representation.data.count <= limits.maximumRepresentationBytes,
                      totalBytes + representation.data.count <= limits.maximumEntryBytes else { continue }
                totalBytes += representation.data.count
                representations.append(representation)
            }
            if !representations.isEmpty {
                storedItems.append(ClipboardCapturedItem(representations: representations))
            }
        }
        guard !storedItems.isEmpty else { return nil }

        let kind = kind(for: storedItems)
        let entry = ClipboardHistoryEntry(
            id: id,
            capturedAt: now,
            sourceBundleIdentifier: source.bundleIdentifier,
            sourceApplicationName: source.applicationName,
            kind: kind,
            preview: preview(for: storedItems, kind: kind),
            contentFingerprint: fingerprint(for: storedItems),
            byteCount: totalBytes,
            thumbnail: kind == .image ? thumbnail(for: storedItems) : nil,
            colorHex: kind == .color ? colorHex(for: storedItems) : nil
        )
        return Capture(entry: entry, payload: ClipboardPayload(items: storedItems))
    }

    static func migrate(legacy: LegacyClipboardHistoryEntry) -> Capture {
        let items = legacy.items
        let kind = legacy.kind
        let entry = ClipboardHistoryEntry(
            id: legacy.id,
            capturedAt: legacy.capturedAt,
            lastUsedAt: legacy.lastUsedAt,
            sourceBundleIdentifier: legacy.sourceBundleIdentifier,
            sourceApplicationName: legacy.sourceApplicationName,
            kind: kind,
            preview: legacy.preview,
            contentFingerprint: legacy.contentFingerprint,
            isPinned: legacy.isPinned,
            byteCount: items.flatMap(\.representations).reduce(0) { $0 + $1.data.count },
            thumbnail: kind == .image ? thumbnail(for: items) : nil,
            colorHex: kind == .color ? colorHex(for: items) : nil
        )
        return Capture(entry: entry, payload: ClipboardPayload(items: items))
    }

    /// Replaces uncompressed TIFF with PNG, and drops TIFF outright when the
    /// pasteboard already offered a PNG of the same image.
    private static func normalizeImages(
        in representations: [ClipboardRepresentation],
        limits: Limits
    ) -> [ClipboardRepresentation] {
        let tiffType = NSPasteboard.PasteboardType.tiff.rawValue
        guard let tiff = representations.first(where: { $0.typeIdentifier == tiffType }) else {
            return representations
        }
        var result = representations.filter { $0.typeIdentifier != tiffType }
        guard !result.contains(where: { $0.typeIdentifier == ClipboardImage.pngType }) else { return result }
        guard tiff.data.count <= limits.maximumSourceImageBytes,
              let png = ClipboardImage.pngData(from: tiff.data) else {
            // Not re-encodable: keep the original and let the size caps decide.
            return representations
        }
        result.append(ClipboardRepresentation(typeIdentifier: ClipboardImage.pngType, data: png))
        return result
    }

    static func kind(for items: [ClipboardCapturedItem]) -> ClipboardContentKind {
        let types = Set(items.flatMap(\.representations).map(\.typeIdentifier))
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return .files }
        if types.contains(ClipboardImage.pngType)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) { return .image }
        if types.contains(NSPasteboard.PasteboardType.color.rawValue) { return .color }
        if types.contains(NSPasteboard.PasteboardType.URL.rawValue) { return .link }
        if let string = firstString(in: items), isLink(string) { return .link }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
            || types.contains(NSPasteboard.PasteboardType.html.rawValue) { return .richText }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue) { return .text }
        return .other
    }

    /// `URL(string:)` alone treats `TODO:ship` and `C:\Users` as URLs, so a
    /// recognized scheme is required before an entry is filed under Links.
    static func isLink(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return linkSchemes.contains(scheme)
    }

    static func preview(for items: [ClipboardCapturedItem], kind: ClipboardContentKind) -> String {
        switch kind {
        case .files:
            let names = fileNames(in: items)
            if !names.isEmpty { return flatten(names.joined(separator: ", ")) }
        case .image:
            if let data = imageData(in: items), let size = ClipboardImage.pixelSize(of: data) {
                return "Image \(Int(size.width)) × \(Int(size.height))"
            }
        case .color:
            if let hex = colorHex(for: items) { return hex }
        case .text, .richText, .link, .other:
            break
        }

        if let string = firstString(in: items) {
            let flattened = flatten(string)
            if !flattened.isEmpty { return flattened }
        }

        switch kind {
        case .image: return items.count == 1 ? "Image" : "\(items.count) images"
        case .files: return items.count == 1 ? "File" : "\(items.count) files"
        case .color: return "Color"
        case .richText: return "Formatted text"
        case .link: return "Link"
        case .text: return "Text"
        case .other: return items.count == 1 ? "Clipboard item" : "\(items.count) clipboard items"
        }
    }

    private static func flatten(_ string: String) -> String {
        String(string.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(320))
    }

    static func fileNames(in items: [ClipboardCapturedItem]) -> [String] {
        fileURLs(in: items).map { $0.lastPathComponent.removingPercentEncoding ?? $0.lastPathComponent }
    }

    static func fileURLs(in items: [ClipboardCapturedItem]) -> [URL] {
        items.flatMap(\.representations)
            .filter { $0.typeIdentifier == NSPasteboard.PasteboardType.fileURL.rawValue }
            .compactMap { representation in
                guard let string = String(data: representation.data, encoding: .utf8) else { return nil }
                return URL(string: string)
            }
    }

    /// Plain text for anything that carries characters, including RTF and HTML
    /// entries that arrived without a plain-string representation.
    static func displayText(in items: [ClipboardCapturedItem]) -> String? {
        if let string = firstString(in: items) { return string }
        let representations = items.flatMap(\.representations)
        let documentTypes: [(String, NSAttributedString.DocumentType)] = [
            (NSPasteboard.PasteboardType.rtf.rawValue, .rtf),
            (NSPasteboard.PasteboardType.html.rawValue, .html)
        ]
        for (typeIdentifier, documentType) in documentTypes {
            guard let representation = representations.first(where: { $0.typeIdentifier == typeIdentifier }),
                  let attributed = try? NSAttributedString(
                      data: representation.data,
                      options: [.documentType: documentType],
                      documentAttributes: nil
                  ) else { continue }
            return attributed.string
        }
        return nil
    }

    static func imageData(in items: [ClipboardCapturedItem]) -> Data? {
        let representations = items.flatMap(\.representations)
        return representations.first(where: { $0.typeIdentifier == ClipboardImage.pngType })?.data
            ?? representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.tiff.rawValue })?.data
    }

    private static func thumbnail(for items: [ClipboardCapturedItem]) -> Data? {
        guard let data = imageData(in: items) else { return nil }
        return ClipboardImage.thumbnailPNG(from: data)
    }

    private static func colorHex(for items: [ClipboardCapturedItem]) -> String? {
        guard let representation = items.flatMap(\.representations)
            .first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.color.rawValue }) else { return nil }
        return ClipboardImage.hex(fromArchivedColor: representation.data)
    }

    static func firstString(in items: [ClipboardCapturedItem]) -> String? {
        for representation in items.flatMap(\.representations)
        where representation.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue {
            if let value = String(data: representation.data, encoding: .utf8) {
                return value
            }
        }
        return nil
    }

    static func fingerprint(for items: [ClipboardCapturedItem]) -> String {
        var hasher = SHA256()
        for item in items {
            for representation in item.representations.sorted(by: { $0.typeIdentifier < $1.typeIdentifier }) {
                hasher.update(data: Data(representation.typeIdentifier.utf8))
                hasher.update(data: representation.data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Preview

/// What the picker's preview pane should draw for a selected entry. Built from the
/// encrypted payload, so it always shows the real contents rather than the
/// truncated preview string carried on the metadata record.
enum ClipboardPreviewContent: Equatable {
    case unavailable
    case text(String)
    case image(Data)
    case files([URL])
    case color(String)
}

/// Puts a stored payload back on a pasteboard.
enum ClipboardPasteboardWriter {
    @discardableResult
    static func write(_ payload: ClipboardPayload, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let pasteboardItems: [NSPasteboardItem] = payload.items.compactMap { capturedItem in
            let pasteboardItem = NSPasteboardItem()
            var wroteRepresentation = false
            for representation in capturedItem.representations {
                let type = NSPasteboard.PasteboardType(representation.typeIdentifier)
                if type == .string, let string = String(data: representation.data, encoding: .utf8) {
                    wroteRepresentation = pasteboardItem.setString(string, forType: type) || wroteRepresentation
                } else {
                    wroteRepresentation = pasteboardItem.setData(representation.data, forType: type) || wroteRepresentation
                }
            }
            // Images are stored as PNG; apps that only read TIFF still need a rep.
            let storedTypes = Set(capturedItem.representations.map(\.typeIdentifier))
            if !storedTypes.contains(NSPasteboard.PasteboardType.tiff.rawValue),
               let png = capturedItem.representations.first(where: { $0.typeIdentifier == ClipboardImage.pngType }),
               let tiff = ClipboardImage.tiffData(from: png.data) {
                wroteRepresentation = pasteboardItem.setData(tiff, forType: .tiff) || wroteRepresentation
            }
            return wroteRepresentation ? pasteboardItem : nil
        }
        guard !pasteboardItems.isEmpty else { return false }
        return pasteboard.writeObjects(pasteboardItems)
    }
}

// MARK: - Controller

@MainActor
final class ClipboardHistoryController: ObservableObject {
    static let enabledDefaultsKey = "clipboardHistoryEnabled"
    static let shortcutDefaultsKey = "clipboardHistoryShortcutEnabled"

    @Published private(set) var entries: [ClipboardHistoryEntry] = []
    @Published private(set) var lastError: String?
    @Published private(set) var notice: String?
    @Published private(set) var isLoaded = false
    @Published private(set) var pickerRequest = 0
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledDefaultsKey)
            if isEnabled { beginPolling() } else { endPolling() }
        }
    }
    @Published var shortcutEnabled: Bool {
        didSet { defaults.set(shortcutEnabled, forKey: Self.shortcutDefaultsKey) }
    }
    @Published var retention: ClipboardRetention {
        didSet {
            defaults.set(retention.rawValue, forKey: ClipboardRetention.defaultsKey)
            pruneExpiredEntries()
        }
    }

    var storedByteCount: Int {
        entries.reduce(0) { $0 + $1.byteCount }
    }

    private let defaults: UserDefaults
    private let store: ClipboardHistoryStore?
    private var timer: Timer?
    private var lastObservedChangeCount = NSPasteboard.general.changeCount
    private var loadTask: Task<Void, Never>?
    private var noticeExpiryTask: Task<Void, Never>?
    private let maximumEntryCount: Int

    init(
        defaults: UserDefaults = .standard,
        store: ClipboardHistoryStore? = nil,
        maximumEntryCount: Int = 2_000
    ) {
        self.defaults = defaults
        self.maximumEntryCount = maximumEntryCount
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            defaults.set(true, forKey: Self.enabledDefaultsKey)
        }
        if defaults.object(forKey: Self.shortcutDefaultsKey) == nil {
            defaults.set(true, forKey: Self.shortcutDefaultsKey)
        }
        isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        shortcutEnabled = defaults.bool(forKey: Self.shortcutDefaultsKey)
        let retentionRaw = defaults.string(forKey: ClipboardRetention.defaultsKey)
        retention = ClipboardRetention(rawValue: retentionRaw ?? "") ?? .defaultValue

        if let store {
            self.store = store
        } else {
            do {
                self.store = ClipboardHistoryStore(keyData: try ClipboardVaultKey.loadOrCreate())
            } catch {
                self.store = nil
                lastError = error.localizedDescription
            }
        }
    }

    func start() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadHistory()
        }
    }

    func stop() {
        endPolling()
        loadTask?.cancel()
        loadTask = nil
        noticeExpiryTask?.cancel()
        noticeExpiryTask = nil
    }

    func setNotice(_ message: String?) {
        notice = message
        scheduleNoticeExpiry()
    }

    func dismissError() {
        lastError = nil
    }

    func requestPicker() {
        pickerRequest &+= 1
    }

    func delete(_ entry: ClipboardHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        remove(ids: [entry.id])
    }

    func deleteAll() {
        entries.removeAll()
        withStore { try await $0.deleteAll() }
    }

    func togglePinned(_ entry: ClipboardHistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isPinned.toggle()
        let updated = entries[index]
        sortEntries()
        persist(updated)
    }

    /// Puts the entry back on the system pasteboard. Reads the encrypted payload
    /// from disk first, which is why it is async.
    @discardableResult
    func restore(_ entry: ClipboardHistoryEntry) async -> Bool {
        guard let store else {
            lastError = ClipboardHistoryError.unavailableStore(
                "Clipboard storage is unavailable, so that item cannot be restored."
            ).localizedDescription
            return false
        }

        let payload: ClipboardPayload
        do {
            payload = try await store.payload(for: entry.id)
        } catch {
            publish(error)
            return false
        }

        guard ClipboardPasteboardWriter.write(payload, to: NSPasteboard.general) else {
            lastError = ClipboardHistoryError.emptyPasteboardEntry.localizedDescription
            return false
        }
        lastObservedChangeCount = NSPasteboard.general.changeCount

        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].lastUsedAt = Date()
            let updated = entries[index]
            sortEntries()
            persist(updated)
        }
        setNotice("Restored \(entry.kind.label.lowercased()) to the clipboard.")
        return true
    }

    /// Reads the full contents of an entry for the picker's preview pane.
    func previewContent(for entry: ClipboardHistoryEntry) async -> ClipboardPreviewContent {
        guard let store, let payload = try? await store.payload(for: entry.id) else { return .unavailable }
        switch entry.kind {
        case .image:
            if let data = ClipboardCaptureBuilder.imageData(in: payload.items) { return .image(data) }
        case .files:
            let urls = ClipboardCaptureBuilder.fileURLs(in: payload.items)
            if !urls.isEmpty { return .files(urls) }
        case .color:
            if let hex = entry.colorHex { return .color(hex) }
        case .text, .richText, .link, .other:
            break
        }
        if let text = ClipboardCaptureBuilder.displayText(in: payload.items) { return .text(text) }
        return .unavailable
    }

    func matchingEntries(query: String, kind: ClipboardContentKind? = nil) -> [ClipboardHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesKind = kind == nil || entry.kind == kind
            guard matchesKind else { return false }
            guard !trimmed.isEmpty else { return true }
            return entry.preview.localizedCaseInsensitiveContains(trimmed)
                || entry.sourceApplicationName?.localizedCaseInsensitiveContains(trimmed) == true
        }
    }

    private func loadHistory() async {
        guard let store else {
            isLoaded = true
            if isEnabled { beginPolling() }
            return
        }
        do {
            let result = try await store.load()
            entries = result.entries
            sortEntries()
            isLoaded = true
            pruneExpiredEntries()
            if result.corruptFileCount > 0 {
                let plural = result.corruptFileCount == 1 ? "y was" : "ies were"
                lastError = "\(result.corruptFileCount) encrypted clipboard entr\(plural) unreadable and left untouched."
            }
            try? await store.removeOrphanedPayloads()
        } catch {
            isLoaded = true
            publish(error)
        }
        if isEnabled { beginPolling() }
    }

    private func beginPolling() {
        guard isLoaded, timer == nil, store != nil else { return }
        lastObservedChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureIfChanged() }
        }
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func endPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func captureIfChanged() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = changeCount
        guard isEnabled, let raw = readRawCapture(from: pasteboard) else { return }

        // Re-encoding a screenshot and hashing it is far too slow for the main
        // thread, so only the pasteboard read happens here.
        Task { [weak self] in
            let capture = await Task.detached(priority: .utility) {
                ClipboardCaptureBuilder.make(rawItems: raw.items, source: raw.source)
            }.value
            guard let capture else { return }
            self?.ingest(capture)
        }
    }

    private struct RawCapture {
        let items: [ClipboardCapturedItem]
        let source: ClipboardCaptureBuilder.Source
    }

    private func readRawCapture(from pasteboard: NSPasteboard) -> RawCapture? {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else { return nil }
        let allTypes = Set(pasteboardItems.flatMap(\.types).map(\.rawValue))
        guard Self.blockedMarkerTypes.isDisjoint(with: allTypes) else { return nil }

        let source = NSWorkspace.shared.frontmostApplication
        if let bundleIdentifier = source?.bundleIdentifier,
           Self.excludedBundleIdentifiers.contains(bundleIdentifier) {
            return nil
        }

        var items: [ClipboardCapturedItem] = []
        for item in pasteboardItems {
            var representations: [ClipboardRepresentation] = []
            for type in Self.capturedTypes where item.types.contains(type) {
                let data: Data?
                if type == .string, let string = item.string(forType: type) {
                    data = string.data(using: .utf8)
                } else {
                    data = item.data(forType: type)
                }
                guard let data, !data.isEmpty else { continue }
                representations.append(ClipboardRepresentation(typeIdentifier: type.rawValue, data: data))
            }
            if !representations.isEmpty {
                items.append(ClipboardCapturedItem(representations: representations))
            }
        }
        guard !items.isEmpty else { return nil }
        return RawCapture(
            items: items,
            source: ClipboardCaptureBuilder.Source(
                bundleIdentifier: source?.bundleIdentifier,
                applicationName: source?.localizedName
            )
        )
    }

    /// Files a freshly built capture into the list and the vault, folding it into
    /// an existing entry when the same content is copied again.
    func ingest(_ capture: ClipboardCaptureBuilder.Capture) {
        var entry = capture.entry
        if let duplicateIndex = entries.firstIndex(where: { $0.contentFingerprint == entry.contentFingerprint }) {
            // Re-copying an existing item promotes it instead of creating a twin.
            // Starting from the stored record keeps its id, pin, and last-used
            // stamp without having to restate every other field — and a field
            // added later keeps its old value rather than silently resetting.
            var merged = entries.remove(at: duplicateIndex)
            merged.capturedAt = entry.capturedAt
            merged.sourceBundleIdentifier = entry.sourceBundleIdentifier
            merged.sourceApplicationName = entry.sourceApplicationName
            merged.preview = entry.preview
            merged.byteCount = entry.byteCount
            merged.thumbnail = entry.thumbnail
            merged.colorHex = entry.colorHex
            entry = merged
        }
        entries.append(entry)
        sortEntries()
        persist(entry, payload: capture.payload)
        enforceMaximumCount()
        pruneExpiredEntries()
    }

    /// Persists an entry. Passing no payload rewrites only the metadata record,
    /// leaving the encrypted blob untouched.
    private func persist(_ entry: ClipboardHistoryEntry, payload: ClipboardPayload? = nil) {
        withStore { try await $0.save(entry, payload: payload) }
    }

    /// Runs store work off the main actor, surfacing any failure once.
    private func withStore(
        _ work: @escaping (ClipboardHistoryStore) async throws -> Void
    ) {
        guard let store else { return }
        Task {
            do {
                try await work(store)
            } catch {
                publish(error)
            }
        }
    }

    private func pruneExpiredEntries(now: Date = Date()) {
        let expired = entries.filter { !retention.keeps($0, now: now) }
        guard !expired.isEmpty else { return }
        let expiredIDs = Set(expired.map(\.id))
        entries.removeAll { expiredIDs.contains($0.id) }
        remove(ids: Array(expiredIDs))
    }

    private func enforceMaximumCount() {
        guard entries.count > maximumEntryCount else { return }
        let excessCount = entries.count - maximumEntryCount
        let evicted = entries
            .filter { !$0.isPinned }
            .sorted { $0.effectiveDate < $1.effectiveDate }
            .prefix(excessCount)
        let evictedIDs = Set(evicted.map(\.id))
        guard !evictedIDs.isEmpty else { return }
        entries.removeAll { evictedIDs.contains($0.id) }
        remove(ids: Array(evictedIDs))
    }

    private func remove(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        withStore { try await $0.delete(ids: ids) }
    }

    private func sortEntries() {
        entries.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.effectiveDate != $1.effectiveDate { return $0.effectiveDate > $1.effectiveDate }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func scheduleNoticeExpiry() {
        noticeExpiryTask?.cancel()
        guard notice != nil else { return }
        noticeExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func publish(_ error: Error) {
        lastError = error.localizedDescription
    }

    private static let capturedTypes: [NSPasteboard.PasteboardType] = [
        .string,
        .rtf,
        .html,
        .tiff,
        NSPasteboard.PasteboardType(ClipboardImage.pngType),
        .URL,
        .fileURL,
        .color
    ]

    /// Conventional markers apps use to say "do not record this".
    private static let blockedMarkerTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword4",
        "com.1password.1password",
        "com.1password.1password7",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephinger",
        "org.keepassxc.keepassxc",
        "com.kueppers.KeePassium",
        "com.mackieapps.strongbox",
        "com.enpass.Enpass",
        "in.sinew.Enpass-Desktop",
        "com.nordpass.macos",
        "ch.protonmail.protonpass",
        "ch.proton.pass",
        "com.roboform.RoboForm"
    ]
}
