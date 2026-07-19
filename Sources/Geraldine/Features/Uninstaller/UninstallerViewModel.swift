import Foundation
import SwiftUI
import Darwin

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let size: UInt64
    let protectedReason: String?

    var id: String { url.standardizedFileURL.path }
    var isProtected: Bool { protectedReason != nil }
}

@MainActor
final class UninstallerViewModel: ObservableObject {
    @Published var apps: [AppEntry] = []
    /// Starts true: the view loads on appear, so the first frame reads as
    /// loading rather than flashing the empty state.
    @Published var loading = true
    @Published var query = ""
    @Published var diagnostics: ScanDiagnostics = .empty

    var filtered: [AppEntry] {
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func load() {
        loading = true
        diagnostics = .empty
        Task {
            let report = await Task.detached(priority: .userInitiated) { Self.discover() }.value
            self.apps = report.apps
            self.diagnostics = report.diagnostics
            self.loading = false
        }
    }

    private nonisolated static func discover() -> UninstallerDiscovery {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications")
        ]
        var result: [AppEntry] = []
        var diagnostics = ScanDiagnostics()
        for dir in dirs {
            do {
                let entries = try fm.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])
                for url in entries where url.pathExtension == "app" {
                    diagnostics.noteScanned()
                    let bundle = Bundle(url: url)
                    let bundleID = bundle?.bundleIdentifier ?? ""
                    let version = (bundle?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
                    let name = url.deletingPathExtension().lastPathComponent
                    result.append(AppEntry(url: url, name: name, bundleID: bundleID,
                                           version: version,
                                           size: DiskScan.size(of: url, diagnostics: &diagnostics),
                                           protectedReason: protectionReason(url: url, bundleID: bundleID)))
                }
            } catch {
                diagnostics.noteSkipped(dir, error)
            }
        }
        diagnostics.finish()
        return UninstallerDiscovery(
            apps: result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            diagnostics: diagnostics
        )
    }

    private nonisolated static func protectionReason(url: URL, bundleID: String) -> String? {
        let path = url.standardizedFileURL.path
        if bundleID.hasPrefix("com.apple.") { return "Protected Apple App" }
        if path.hasPrefix("/System/Applications/") { return "Protected System App" }
        if path.hasPrefix("/Applications/Utilities/") { return "Protected macOS Utility" }
        return nil
    }
}

private struct UninstallerDiscovery {
    var apps: [AppEntry]
    var diagnostics: ScanDiagnostics
}

@MainActor
final class LeftoversModel: ObservableObject {
    enum Phase: Hashable { case scanning, results, uninstalling, done }
    @Published var phase: Phase = .scanning
    @Published var groups: [ScanGroup] = []
    @Published var selection: Set<String> = []
    @Published var result: TrashService.Result?
    @Published var diagnostics: ScanDiagnostics = .empty

    let app: AppEntry
    init(app: AppEntry) { self.app = app }

    func scan() {
        phase = .scanning
        let app = self.app
        Task {
            let report = await Task.detached(priority: .userInitiated) { Self.findLeftovers(for: app) }.value
            self.groups = report.groups
            self.selection = report.groups.defaultSelection
            self.diagnostics = report.diagnostics
            self.phase = .results
        }
    }

    func uninstall() {
        guard !app.isProtected else { return }
        let items = groups.items(in: selection)
        guard !items.isEmpty else { return }
        phase = .uninstalling
        Task {
            let r = await Task.detached { TrashService.clean(items) }.value
            self.result = r
            self.phase = .done
        }
    }

    private nonisolated static func findLeftovers(for app: AppEntry) -> ScanReport {
        var diagnostics = ScanDiagnostics()
        guard !app.isProtected else {
            diagnostics.failure = app.protectedReason ?? "This app is protected."
            diagnostics.finish()
            return ScanReport(groups: [], diagnostics: diagnostics)
        }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")

        // The app bundle itself.
        let appItem = ScanItem(url: app.url, name: app.url.lastPathComponent,
                               detail: app.url.deletingLastPathComponent().path, size: app.size)

        let launchAgents = lib.appendingPathComponent("LaunchAgents")
        var launchAgentEntries: [LaunchAgentEntry] = []
        do {
            let agents = try fm.contentsOfDirectory(at: launchAgents, includingPropertiesForKeys: nil)
            launchAgentEntries = agents.compactMap { Self.launchAgentEntry(at: $0, within: launchAgents) }
        } catch {
            if fm.fileExists(atPath: launchAgents.path) {
                diagnostics.noteSkipped(launchAgents, error)
            }
        }

        let located = Self.locateLeftovers(
            identity: UninstallerAppIdentity(bundleID: app.bundleID, displayName: app.name),
            libraryRoot: lib,
            launchAgents: launchAgentEntries
        )
        let measured = located.compactMap { candidate -> MeasuredLeftover? in
            guard fm.fileExists(atPath: candidate.url.path) else { return nil }
            diagnostics.noteScanned()
            return MeasuredLeftover(
                item: ScanItem(url: candidate.url, name: candidate.url.lastPathComponent,
                               detail: candidate.url.deletingLastPathComponent().path,
                               size: DiskScan.size(of: candidate.url, diagnostics: &diagnostics)),
                confidence: candidate.confidence
            )
        }
        diagnostics.finish()
        return ScanReport(groups: Self.buildGroups(application: appItem, leftovers: measured),
                          diagnostics: diagnostics)
    }

    private nonisolated static let maximumLaunchAgentPlistBytes = 1_048_576

    nonisolated static func launchAgentEntry(at url: URL, within root: URL) -> LaunchAgentEntry? {
        guard url.pathExtension == "plist", isStrictlyContained(url, in: root) else { return nil }

        // LaunchAgents is user-writable. Open without following symlinks, and reject
        // pipes/devices plus oversized files before reading or parsing their contents.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0,
              info.st_size <= maximumLaunchAgentPlistBytes else { return nil }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maximumLaunchAgentPlistBytes + 1),
              data.count <= maximumLaunchAgentPlistBytes,
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ),
              let dictionary = propertyList as? [String: Any] else {
            return nil
        }
        return LaunchAgentEntry(url: url, label: dictionary["Label"] as? String)
    }
}

enum LeftoverMatchConfidence: Int, Equatable, Hashable {
    case displayName
    case bundleIdentifier
}

struct UninstallerAppIdentity: Equatable {
    let bundleID: String
    let displayName: String
}

struct LeftoverCandidate: Equatable, Hashable {
    let url: URL
    let confidence: LeftoverMatchConfidence
}

struct LaunchAgentEntry: Equatable, Hashable {
    let url: URL
    let label: String?
}

struct MeasuredLeftover {
    let item: ScanItem
    let confidence: LeftoverMatchConfidence
}

extension LeftoversModel {
    nonisolated static let supportedLeftoverRoots = [
        "Application Support", "Caches", "Containers", "HTTPStorages", "Logs",
        "Preferences", "Saved Application State", "WebKit", "Group Containers"
    ]

    nonisolated static func locateLeftovers(
        identity: UninstallerAppIdentity,
        libraryRoot: URL,
        launchAgents: [LaunchAgentEntry]
    ) -> [LeftoverCandidate] {
        let bundleID = Self.validatedBundleIdentifier(identity.bundleID)
        let displayName = Self.validatedDisplayName(identity.displayName)
        var candidates: [LeftoverCandidate] = []

        for relativeRoot in supportedLeftoverRoots {
            let root = libraryRoot.appendingPathComponent(relativeRoot, isDirectory: true)
            if let bundleID {
                appendCandidate(to: &candidates, root: root, leaf: bundleID,
                                pathExtension: fileExtension(for: relativeRoot),
                                confidence: .bundleIdentifier)
            }
            if let displayName {
                appendCandidate(to: &candidates, root: root, leaf: displayName,
                                pathExtension: fileExtension(for: relativeRoot),
                                confidence: .displayName)
            }
        }

        if let bundleID {
            let root = libraryRoot.appendingPathComponent("LaunchAgents", isDirectory: true)
            for entry in launchAgents {
                guard entry.url.pathExtension == "plist",
                      isStrictlyContained(entry.url, in: root) else { continue }
                let basename = entry.url.deletingPathExtension().lastPathComponent
                // Exact identity is deliberate: prefix/substring matches can select a
                // different app's helper agent for deletion.
                guard basename == bundleID || entry.label == bundleID else { continue }
                appendCandidate(to: &candidates, candidate: LeftoverCandidate(
                    url: entry.url, confidence: .bundleIdentifier
                ))
            }
        }

        return candidates
    }

    nonisolated static func buildGroups(application: ScanItem, leftovers: [MeasuredLeftover]) -> [ScanGroup] {
        var strongestByPath: [String: MeasuredLeftover] = [:]
        for leftover in leftovers {
            let key = leftover.item.id
            guard let existing = strongestByPath[key] else {
                strongestByPath[key] = leftover
                continue
            }
            if leftover.confidence.rawValue > existing.confidence.rawValue {
                strongestByPath[key] = leftover
            }
        }

        let sorted = strongestByPath.values.sorted { $0.item.size > $1.item.size }
        let exact = sorted.filter { $0.confidence == .bundleIdentifier }.map(\.item)
        let possible = sorted.filter { $0.confidence == .displayName }.map(\.item)
        var groups = [ScanGroup(title: "Application", icon: "app.fill", tint: Module.uninstaller.tint,
                                items: [application], safeByDefault: true)]
        if !exact.isEmpty {
            groups.append(ScanGroup(title: "Leftover Files", icon: "doc.on.doc.fill",
                                    tint: Theme.warn, items: exact, safeByDefault: true))
        }
        if !possible.isEmpty {
            groups.append(ScanGroup(title: "Possible Leftovers", icon: "questionmark.folder.fill",
                                    tint: Theme.warn, items: possible, safeByDefault: false))
        }
        return groups
    }

    private nonisolated static func appendCandidate(
        to candidates: inout [LeftoverCandidate],
        root: URL,
        leaf: String,
        pathExtension: String?,
        confidence: LeftoverMatchConfidence
    ) {
        var url = root.appendingPathComponent(leaf, isDirectory: pathExtension == nil)
        if let pathExtension {
            url.appendPathExtension(pathExtension)
        }
        guard isStrictlyContained(url, in: root) else { return }
        appendCandidate(to: &candidates, candidate: LeftoverCandidate(url: url, confidence: confidence))
    }

    private nonisolated static func appendCandidate(to candidates: inout [LeftoverCandidate], candidate: LeftoverCandidate) {
        let key = candidate.url.standardizedFileURL.path
        guard let index = candidates.firstIndex(where: { $0.url.standardizedFileURL.path == key }) else {
            candidates.append(candidate)
            return
        }
        if candidate.confidence.rawValue > candidates[index].confidence.rawValue {
            candidates[index] = candidate
        }
    }

    private nonisolated static func fileExtension(for relativeRoot: String) -> String? {
        switch relativeRoot {
        case "Preferences": return "plist"
        case "Saved Application State": return "savedState"
        default: return nil
        }
    }

    private nonisolated static func validatedBundleIdentifier(_ value: String) -> String? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !value.hasPrefix("."), !value.hasSuffix("."),
              value.unicodeScalars.allSatisfy(Self.isAllowedBundleScalar) else {
            return nil
        }
        return value
    }

    private nonisolated static func isAllowedBundleScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 45, 46, 48...57, 65...90, 97...122: return true
        default: return false
        }
    }

    private nonisolated static func validatedDisplayName(_ value: String) -> String? {
        guard !value.isEmpty, value != ".", value != "..",
              !value.unicodeScalars.contains(where: { scalar in
                  scalar == "/" || scalar == ":" || scalar.value == 0
              }) else { return nil }
        return value
    }

    private nonisolated static func isStrictlyContained(_ candidate: URL, in root: URL) -> Bool {
        let lexicalCandidate = candidate.standardizedFileURL.pathComponents
        let lexicalRoot = root.standardizedFileURL.pathComponents
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return isStrictDescendant(lexicalCandidate, of: lexicalRoot)
            && isStrictDescendant(resolvedCandidate, of: resolvedRoot)
    }

    private nonisolated static func isStrictDescendant(_ candidate: [String], of root: [String]) -> Bool {
        candidate.count > root.count && candidate.prefix(root.count).elementsEqual(root)
    }
}
