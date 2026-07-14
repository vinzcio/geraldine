import SwiftUI

struct LaunchItem: Identifiable, Hashable {
    let id: String
    /// The raw launchd Label — the technical identity, shown as the detail line.
    let label: String
    /// The human name — the owning app's display name when the program lives in
    /// an .app bundle, otherwise the launchd label prettified into words.
    let displayName: String
    let program: String
    /// The .app bundle that owns `program`, for showing its real icon.
    let appURL: URL?
    var plistURL: URL
    let scope: Scope
    var enabled: Bool

    enum Scope: String, CaseIterable {
        case user = "Starts When You Log In"
        case global = "Starts For All Users"
        case daemon = "System Services"
    }
    var editable: Bool { scope == .user }

    init(label: String, program: String, plistURL: URL, scope: Scope, enabled: Bool) {
        self.id = Self.stableID(for: plistURL, scope: scope)
        self.label = label
        self.program = program
        self.plistURL = plistURL
        self.scope = scope
        self.enabled = enabled
        let appURL = Self.owningApplication(forProgram: program)
        self.appURL = appURL
        self.displayName = Self.friendlyName(label: label, appURL: appURL)
    }

    private static func stableID(for plistURL: URL, scope: Scope) -> String {
        let resourceID = try? plistURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier
        let identity = resourceID.map(String.init(describing:))
            ?? plistURL.standardizedFileURL.path
        return "\(scope.rawValue)|\(identity)"
    }

    /// Walks the program path up to the first `.app` component, e.g.
    /// `/Applications/Dropbox.app/Contents/MacOS/Dropbox` → `/Applications/Dropbox.app`.
    private static func owningApplication(forProgram program: String) -> URL? {
        guard program.hasPrefix("/") else { return nil }
        let components = program.split(separator: "/")
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let path = "/" + components[...appIndex].joined(separator: "/")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// "com.dropbox.DropboxMacUpdate" → "Dropbox Mac Update" when no app bundle
    /// supplies a real display name. Generic tails keep their vendor segment so
    /// "com.google.keystone.agent" reads "Keystone Agent", not just "Agent".
    private static func friendlyName(label: String, appURL: URL?) -> String {
        if let appURL {
            let bundle = Bundle(url: appURL)
            if let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String),
               !name.isEmpty {
                return name
            }
            return appURL.deletingPathExtension().lastPathComponent
        }

        let segments = label.split(separator: ".").map(String.init)
        guard let last = segments.last else { return label }
        let genericTails: Set<String> = ["agent", "updater", "update", "wake", "service",
                                         "xpcservice", "helper", "daemon", "launcher",
                                         "monitor", "login", "sync"]
        let nameSegments = genericTails.contains(last.lowercased()) && segments.count >= 2
            ? Array(segments.suffix(2))
            : [last]

        var spaced = nameSegments.joined(separator: " ")
            .replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        spaced = spaced.replacingOccurrences(of: "(?<=[a-z0-9])(?=[A-Z])", with: " ",
                                             options: .regularExpression)
        spaced = spaced.replacingOccurrences(of: "(?<=[A-Z])(?=[A-Z][a-z])", with: " ",
                                             options: .regularExpression)
        let titled = spaced.split(separator: " ")
            .map { word -> String in
                if word.lowercased() == "xpcservice" { return "XPC Service" }
                if word.lowercased() == "xpc" { return "XPC" }
                return word.first.map { String($0).uppercased() + word.dropFirst() } ?? String(word)
            }
            .joined(separator: " ")
        return titled.isEmpty ? label : titled
    }
}

enum LoginItemActionState: Hashable {
    case working
    case success(String)
    case failure(String)
    case cancelled(String)
}

struct LoginItemOutcome: Identifiable, Equatable {
    enum Kind: Hashable { case success, failure, cancelled }

    let id = UUID()
    let itemID: String
    let message: String
    let kind: Kind
}

@MainActor
final class LoginItemsViewModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    /// Starts true: the view scans on appear, so the first frame should read
    /// as "scanning" rather than flashing the empty state for a beat.
    @Published var loading = true
    @Published var diagnostics: ScanDiagnostics = .empty
    @Published var lastError: String?
    @Published private(set) var actionStates: [String: LoginItemActionState] = [:]
    @Published private(set) var latestOutcome: LoginItemOutcome?
    /// Bumped on every load; a scan only lands if it is still the newest one,
    /// so a toggle mid-rescan can't flash rows back to their previous state.
    private var scanGeneration = 0

    private var disabledDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Geraldine/DisabledLaunchAgents")
    }
    private var userAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    func items(in scope: LaunchItem.Scope) -> [LaunchItem] {
        items.filter { $0.scope == scope }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func load() {
        loading = true
        diagnostics = .empty
        try? FileManager.default.createDirectory(at: disabledDir, withIntermediateDirectories: true)
        scanGeneration += 1
        let generation = scanGeneration
        let userDir = userAgentsDir, disDir = disabledDir
        Task {
            let report = await Task.detached(priority: .userInitiated) { Self.scan(userDir: userDir, disabledDir: disDir) }.value
            guard generation == self.scanGeneration else { return }
            self.items = report.items
            self.diagnostics = report.diagnostics
            self.loading = false
        }
    }

    func toggle(_ item: LaunchItem) {
        guard item.editable, actionStates[item.id] != .working else { return }
        actionStates[item.id] = .working
        Task { @MainActor in
            await Task.yield()
            performToggle(item)
        }
    }

    func remove(_ item: LaunchItem) {
        guard item.editable, actionStates[item.id] != .working else { return }
        actionStates[item.id] = .working
        Task { @MainActor in
            await Task.yield()
            performRemoval(item)
        }
    }

    func noteRemovalCancelled(_ item: LaunchItem) {
        let message = "Kept \(item.displayName) unchanged."
        let state = LoginItemActionState.cancelled(message)
        actionStates[item.id] = state
        publishOutcome(itemID: item.id, message: message, kind: .cancelled)
        clearStateLater(state, for: item.id)
    }

    func actionState(for item: LaunchItem) -> LoginItemActionState? {
        actionStates[item.id]
    }

    private func performToggle(_ item: LaunchItem) {
        let fm = FileManager.default
        let dest = item.enabled
            ? disabledDir.appendingPathComponent(item.plistURL.lastPathComponent)
            : userAgentsDir.appendingPathComponent(item.plistURL.lastPathComponent)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: item.plistURL, to: dest)
            lastError = nil
            let verb = item.enabled ? "Disabled" : "Enabled"
            let message = "\(verb) \(item.displayName)."
            let state = LoginItemActionState.success(message)
            actionStates[item.id] = state
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].plistURL = dest
                items[index].enabled.toggle()
            }
            publishOutcome(itemID: item.id, message: message, kind: .success)
            clearStateLater(state, for: item.id)
            load()
        } catch {
            let message = "Could not \(item.enabled ? "disable" : "enable") \(item.displayName): \((error as NSError).localizedDescription)"
            let state = LoginItemActionState.failure(message)
            lastError = message
            actionStates[item.id] = state
            publishOutcome(itemID: item.id, message: message, kind: .failure)
        }
    }

    private func performRemoval(_ item: LaunchItem) {
        let result = TrashService.clean([ScanItem(url: item.plistURL, size: 0)])
        if let failure = result.failures.first {
            let message = "Could not remove \(item.displayName): \(failure.message)"
            lastError = message
            actionStates[item.id] = .failure(message)
            publishOutcome(itemID: item.id, message: message, kind: .failure)
        } else {
            lastError = nil
            let message = "Moved \(item.displayName) to the Trash."
            let state = LoginItemActionState.success(message)
            actionStates[item.id] = state
            items.removeAll { $0.id == item.id }
            publishOutcome(itemID: item.id, message: message, kind: .success)
            clearStateLater(state, for: item.id)
        }
        load()
    }

    private func publishOutcome(itemID: String, message: String, kind: LoginItemOutcome.Kind) {
        let outcome = LoginItemOutcome(itemID: itemID, message: message, kind: kind)
        latestOutcome = outcome
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if latestOutcome == outcome { latestOutcome = nil }
        }
    }

    private func clearStateLater(_ state: LoginItemActionState, for id: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if actionStates[id] == state { actionStates[id] = nil }
        }
    }

    private nonisolated static func scan(userDir: URL, disabledDir: URL) -> LoginItemsScanResult {
        var out: [LaunchItem] = []
        var diagnostics = ScanDiagnostics()
        let fm = FileManager.default
        func read(_ dir: URL, scope: LaunchItem.Scope, enabled: Bool) {
            guard fm.fileExists(atPath: dir.path) else { return }
            do {
                let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                for url in files where url.pathExtension == "plist" {
                    diagnostics.noteScanned()
                    let dict = NSDictionary(contentsOf: url)
                    let label = (dict?["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
                    let program = (dict?["Program"] as? String)
                        ?? (dict?["ProgramArguments"] as? [String])?.first
                        ?? ""
                    out.append(LaunchItem(label: label, program: program, plistURL: url,
                                          scope: scope, enabled: enabled))
                }
            } catch {
                diagnostics.noteSkipped(dir, error)
            }
        }
        read(userDir, scope: .user, enabled: true)
        read(disabledDir, scope: .user, enabled: false)
        read(URL(fileURLWithPath: "/Library/LaunchAgents"), scope: .global, enabled: true)
        read(URL(fileURLWithPath: "/Library/LaunchDaemons"), scope: .daemon, enabled: true)
        diagnostics.finish()
        return LoginItemsScanResult(items: out, diagnostics: diagnostics)
    }
}

private struct LoginItemsScanResult {
    var items: [LaunchItem]
    var diagnostics: ScanDiagnostics
}
