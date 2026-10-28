import SwiftUI

struct GeraldineCommand: Identifiable, Equatable {
    enum Action: Equatable {
        case module(Module)
        case activity(ActivitySection)
        case refreshCodingUsage
        case checkForUpdates
    }

    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let keywords: String
    let action: Action

    static var all: [Self] {
        Module.allCases.map { module in
            Self(id: module.rawValue, title: module.title, detail: module.subtitle,
                 systemImage: module.systemImage, keywords: "open show \(module.rawValue)", action: .module(module))
        } + ActivitySection.allCases.map { section in
            Self(id: "activity.\(section.rawValue)", title: "Show \(section.title)",
                 detail: "Inspect \(section.title.lowercased()) in Activity", systemImage: "waveform.path.ecg",
                 keywords: "usage chart history apps helpers \(section.rawValue)", action: .activity(section))
        } + [Self(id: "refreshCodingUsage", title: "Refresh Coding Usage",
                  detail: "Refresh accounts whose usage is already enabled", systemImage: "arrow.clockwise",
                  keywords: "quota allowance claude codex cursor grok antigravity", action: .refreshCodingUsage),
             Self(id: "checkForUpdates", title: "Check For Geraldine Updates",
                  detail: "See whether a newer Geraldine is published", systemImage: "arrow.down.circle",
                  keywords: "update upgrade version release new geraldine", action: .checkForUpdates)]
    }

    static func matching(_ query: String) -> [Self] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return all }
        let phrase = terms.joined(separator: " ")
        func relevance(_ command: Self) -> Int {
            if command.title.localizedStandardCompare(phrase) == .orderedSame { return 3 }
            if terms.allSatisfy({ command.title.localizedStandardContains($0) }) { return 2 }
            return terms.contains(where: { command.title.localizedStandardContains($0) }) ? 1 : 0
        }
        return all.enumerated().filter { _, command in
            let text = "\(command.title) \(command.detail) \(command.keywords)"
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { lhs, rhs in
            let left = relevance(lhs.element), right = relevance(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    @MainActor
    func perform(in state: AppState) {
        switch action {
        case .module(let module): state.selection = module
        case .activity(let section): state.navigateToActivity(section)
        case .refreshCodingUsage:
            state.selection = .codingUsage
            state.aiUsage.refreshConnected()
        case .checkForUpdates:
            state.selection = .settings
            state.updates.checkForUpdates()
        }
    }
}

struct CommandSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var selection: String?
    let perform: (GeraldineCommand) -> Void

    private var results: [GeraldineCommand] { GeraldineCommand.matching(query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search pages and actions", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { command in
                            Button { run(command) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: command.systemImage)
                                        .frame(width: 24).foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(command.title).font(.callout.weight(.medium))
                                        Text(command.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selection == command.id {
                                        Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selection == command.id ? Theme.accent.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == command.id ? .isSelected : [])
                            .id(command.id)
                        }
                        if results.isEmpty {
                            Text("No matching pages or actions.").foregroundStyle(.secondary).padding(24)
                        }
                    }.padding(10)
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            Divider()
            Text("↑ ↓ to choose · Return to open · Escape to close")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(width: 600, height: 460)
        .onAppear { selection = results.first?.id; searchFocused = true }
        .onChange(of: query) { _, _ in selection = results.first?.id }
    }

    private func move(_ offset: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selection } ?? 0
        selection = results[min(max(current + offset, 0), results.count - 1)].id
    }

    private func runSelected() {
        if let command = results.first(where: { $0.id == selection }) ?? results.first { run(command) }
    }

    private func run(_ command: GeraldineCommand) {
        dismiss()
        perform(command)
    }
}
