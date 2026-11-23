import AppKit
import SwiftUI
import WardenCore

@MainActor
final class TraceNavigation: ObservableObject {
    @Published var selection: TraceSource.ID?
    private(set) var requestedSession: AgentSession?

    func show(_ session: AgentSession?) {
        requestedSession = session
        selection = session.map(TraceSource.ID.init)
    }
}

/// A pane in Live Output: a session or one of its subagents, with the session that hosts it.
struct TraceAgent: Identifiable {
    let source: TraceSource
    let root: AgentSession
    let parentName: String?

    var id: TraceSource.ID { source.id }
}

/// Balanced rows of panes. Seven agents make rows of 4 and 3 rather than a lone stretched pane, and the grid scrolls
/// only when the window is too small for readable terminals.
struct TraceGrid {
    static let margin: CGFloat = 12
    static let gutter: CGFloat = 10
    static let minimumHeight: CGFloat = 210
    /// About 120 characters per line.
    static let zoomedWidth: CGFloat = 840

    let frames: [CGRect]
    let height: CGFloat

    init(count: Int, size: CGSize) {
        guard count > 0, size.width > 0, size.height > 0 else {
            frames = []
            height = 0
            return
        }
        let width = max(0, size.width - Self.margin * 2)
        var best: (score: CGFloat, rows: [Int], height: CGFloat)?
        for rowCount in 1...count {
            let rows = Self.rows(count, in: rowCount)
            let fit = (size.height - Self.margin * 2 - Self.gutter * CGFloat(rowCount - 1)) / CGFloat(rowCount)
            let paneHeight = max(fit, Self.minimumHeight)
            let widest = CGFloat(rows.max() ?? 1)
            let paneWidth = (width - Self.gutter * (widest - 1)) / widest
            // Characters per line and lines per pane: lines narrower than prose and panes shorter than about 16
            // lines both count for much less.
            let columns = max(0, (paneWidth - 24) / TracePalette.column)
            let lines = max(0, (paneHeight - 66) / TracePalette.lineHeight)
            let readable = columns < 52 ? columns * columns / 52 : min(columns, 84)
            let visible = lines < 16 ? lines * lines / 16 : min(lines, 32)
            let score = readable * visible * (fit < Self.minimumHeight ? 0.75 : 1)
            if best.map({ score > $0.score }) ?? true { best = (score, rows, paneHeight) }
        }
        guard let best else {
            frames = []
            height = 0
            return
        }
        var frames: [CGRect] = []
        for (row, columns) in best.rows.enumerated() {
            let paneWidth = (width - Self.gutter * CGFloat(columns - 1)) / CGFloat(columns)
            let y = Self.margin + CGFloat(row) * (best.height + Self.gutter)
            for column in 0..<columns {
                let x = Self.margin + CGFloat(column) * (paneWidth + Self.gutter)
                frames.append(CGRect(x: x.rounded(), y: y.rounded(), width: paneWidth.rounded(.down), height: best.height.rounded(.down)))
            }
        }
        self.frames = frames
        height = Self.margin * 2 + CGFloat(best.rows.count) * best.height + Self.gutter * CGFloat(best.rows.count - 1)
    }

    /// Rows that differ by at most one pane, fuller rows first.
    static func rows(_ count: Int, in rows: Int) -> [Int] {
        (0..<rows).map { count / rows + ($0 < count % rows ? 1 : 0) }
    }
}

@MainActor
struct LiveTracesView: View {
    @ObservedObject var store: WardenStore
    @ObservedObject var navigation: TraceNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("liveOutputShowsCommands") private var showsCommands = false
    @AppStorage("liveOutputFollows") private var followOutput = true
    /// Panes whose commands differ from the window-wide choice.
    @State private var commandOverrides = Set<TraceSource.ID>()
    @State private var watched = Set<TraceSource.ID>()
    @State private var pendingStop: TraceSource.ID?
    @State private var reader = TraceReader()
    @State private var logs: [TraceFile: [TraceEvent]] = [:]
    @State private var lastRead: [TraceFile]?

    private var localSessions: [AgentSession] {
        var local = store.sessions.filter { $0.remote == nil && follows($0) }
        if let requested = navigation.requestedSession, follows(requested),
           !local.contains(where: { TraceSource.ID($0) == TraceSource.ID(requested) }) {
            local.append(requested)
        }
        return local
    }

    private func follows(_ session: AgentSession) -> Bool {
        Accounts.follows(session.provider, account: session.account, in: store.accounts)
    }

    private func active(_ session: AgentSession) -> Bool {
        session.phase == .working || session.phase == .needsAttention
    }

    private func roster(_ sessions: [AgentSession]) -> [TraceAgent] {
        let transcripts = store.traceTranscripts
        let children = Dictionary(grouping: transcripts.values.filter { $0.parentID != nil }, by: \.parentID)
        var agents: [TraceAgent] = []
        var seen = Set<TraceSource.ID>()
        func add(_ source: TraceSource, root: AgentSession, parentName: String?) {
            guard seen.insert(source.id).inserted else { return }
            agents.append(TraceAgent(source: source, root: root, parentName: parentName))
            for child in (children[source.id] ?? []).sorted(by: byName) {
                add(child, root: root, parentName: source.name)
            }
        }
        let roots = sessions.compactMap { session -> TraceSource? in
            let id = TraceSource.ID(session)
            guard active(session) || watched.contains(id) || navigation.selection == id else { return nil }
            return TraceSource(session: session, file: transcripts[id]?.file)
        }
        for source in roots.sorted(by: byName) { add(source, root: source.session, parentName: nil) }
        return agents
    }

    private func byName(_ left: TraceSource, _ right: TraceSource) -> Bool {
        let order = left.name.localizedStandardCompare(right.name)
        if order != .orderedSame { return order == .orderedAscending }
        return left.id.sessionID < right.id.sessionID
    }

    var body: some View {
        let sessions = localSessions
        let agents = roster(sessions)
        let focused = agents.first { $0.id == navigation.selection }
        // Every pane keeps reading while one is zoomed, so returning to the grid shows current output at once.
        let files = agents.compactMap(\.source.log).sorted { $0.url.path < $1.url.path }

        content(agents, focused: focused)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: TracePalette.backdrop))
            .navigationTitle("Warden Live Output")
            .navigationSubtitle(subtitle(agents, focused: focused))
            .toolbar { toolbar(focused) }
            .background { shortcuts(agents, focused: focused) }
            .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: navigation.selection)
            .onChange(of: sessions, initial: true) { _, current in
                // Keep an agent's output visible as it finishes while the window is open.
                watched.formIntersection(current.map { TraceSource.ID($0) })
                watched.formUnion(current.filter(active).map { TraceSource.ID($0) })
            }
            .onChange(of: agents.map(\.id)) { _, ids in
                if let selection = navigation.selection, !ids.contains(selection) { navigation.selection = nil }
                commandOverrides.formIntersection(ids)
            }
            .task(id: files) {
                while !Task.isCancelled {
                    let snapshot = await reader.read(files)
                    guard !Task.isCancelled else { break }
                    if logs != snapshot { logs = snapshot }
                    if lastRead != files { lastRead = files }
                    if files.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(1_500))
                }
            }
    }

    @ViewBuilder
    private func content(_ agents: [TraceAgent], focused: TraceAgent?) -> some View {
        if agents.isEmpty {
            ContentUnavailableView("No active local agents", systemImage: "terminal",
                                   description: Text("Start a Codex or Claude Code run to follow its output here."))
        } else {
            GeometryReader { proxy in
                let layout = TraceGrid(count: agents.count, size: proxy.size)
                ZStack(alignment: .topLeading) {
                    grid(agents, layout: layout, size: proxy.size)
                        .opacity(focused == nil ? 1 : 0)
                        .allowsHitTesting(focused == nil)
                        .accessibilityHidden(focused != nil)
                    if let focused {
                        pane(focused, zoomed: true)
                            .frame(maxWidth: TraceGrid.zoomedWidth)
                            .padding(TraceGrid.margin)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .transition(zoom(from: agents.firstIndex { $0.id == focused.id }.map { layout.frames[$0] }, in: proxy.size))
                            .zIndex(1)
                    }
                }
            }
        }
    }

    private func grid(_ agents: [TraceAgent], layout: TraceGrid, size: CGSize) -> some View {
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: size.width, height: max(layout.height, size.height))
                ForEach(Array(zip(agents, layout.frames)), id: \.0.id) { agent, frame in
                    pane(agent, zoomed: false)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: agents.map(\.id))
        }
        .scrollDisabled(layout.height <= size.height + 1)
    }

    /// A zoomed pane grows out of its place in the grid and shrinks back into it.
    private func zoom(from frame: CGRect?, in size: CGSize) -> AnyTransition {
        guard let frame, size.width > 0, size.height > 0, !reduceMotion else { return .opacity }
        let anchor = UnitPoint(x: frame.midX / size.width, y: min(1, frame.midY / size.height))
        let width = min(TraceGrid.zoomedWidth, size.width - TraceGrid.margin * 2)
        return .scale(scale: min(1, max(0.25, frame.width / width)), anchor: anchor).combined(with: .opacity)
    }

    private func pane(_ agent: TraceAgent, zoomed: Bool) -> some View {
        let session = agent.source.session
        let file = agent.source.log
        let events = file.flatMap { logs[$0] }
        let unavailable = file == nil || (file.map { lastRead?.contains($0) == true && logs[$0] == nil } ?? false)
        let stoppable = session.provider == .codex && session.remote == nil && !session.ended && active(session)
        return TracePane(
            agent: agent, events: events, unavailable: unavailable, status: status(agent, events: events),
            showsCommands: showsCommands(agent.id), follows: followOutput, zoomed: zoomed, busy: pendingStop != nil,
            actions: .init(
                toggleCommands: { toggleCommands(agent.id) },
                toggleZoom: { navigation.selection = navigation.selection == agent.id ? nil : agent.id },
                open: agent.root.isHeadless ? nil : {
                    SessionNavigator.open(agent.root, processes: store.processes, accounts: store.accounts)
                },
                forceQuit: stoppable ? { stop(agent.source) } : nil,
                dismiss: stoppable && !session.isSubagent && session.attention == .interrupted ? {
                    if store.dismissInterruptedCodex(agent.source) { removePane(agent.id) }
                } : nil))
    }

    // MARK: Status

    private func status(_ agent: TraceAgent, events: [TraceEvent]?) -> TracePane.Status {
        let session = agent.source.session
        let updated = session.updatedAt
        switch session.phase {
        case .needsAttention:
            if session.attention == .failure {
                return .init(tone: .failure, headline: MenuFormat.failure(session.detail), since: updated, lastActivity: updated)
            }
            return .init(tone: .attention, headline: "Needs you", detail: request(session), since: updated, lastActivity: updated)
        case .working:
            if let resumes = session.resumesAt {
                return .init(tone: .waiting, headline: "Usage limit", detail: "resumes \(MenuFormat.resetPhrase(resumes))",
                             since: updated, lastActivity: updated)
            }
            var notes: [String] = []
            if let retry = session.retry, Date().timeIntervalSince(retry.at) < 600 {
                notes.append("\(retry.networkDown ? "offline, retrying" : "retrying after an error") \(retry.attempt) of \(retry.maxAttempts)")
            } else if session.activeSubagents > 0 {
                notes.append(session.activeSubagents == 1 ? "1 agent working" : "\(session.activeSubagents) agents working")
            } else if session.busyInBackground {
                notes.append("background task running")
            }
            if session.attention == .choice { notes.append("question pending") }
            let action = events?.last { $0.kind == .tool }
                .map { ToolLines.phrase($0, provider: session.provider, cwd: session.cwd) }
            // Without the turn's start, the time since the last event would pass for the turn's length.
            return .init(tone: .working, headline: "Working", detail: notes.isEmpty ? nil : notes.joined(separator: " · "),
                         since: session.turnStartedAt, lastActivity: updated, action: action)
        case .finished, .idle, .unknown:
            if session.phase == .idle, session.attention == nil, session.detail != nil {
                // A run that stopped on an error and then exited.
                return .init(tone: .failure, headline: MenuFormat.failure(session.detail), since: updated, lastActivity: updated)
            }
            let headline = session.phase == .finished ? "Done" : session.ended ? "Ended" : session.phase == .idle ? "Paused" : "Quiet"
            return .init(tone: session.phase == .finished ? .done : .idle, headline: headline, since: updated, lastActivity: updated)
        }
    }

    /// What the session waits for, worded as in the menu.
    private func request(_ session: AgentSession) -> String {
        switch session.attention {
        case .question: return session.detail ?? "Asked you a question"
        case .choice: return session.detail ?? "Waiting for your answer"
        case .permission:
            if let request = store.approval(for: session)?.request {
                return [request.tool, request.summary].compactMap { $0 }.joined(separator: ": ")
            }
            return session.detail.map { "Approve \($0)" } ?? "Waiting for approval"
        case .interrupted: return "Interrupted"
        default: return session.detail ?? "Needs your input"
        }
    }

    private func subtitle(_ agents: [TraceAgent], focused: TraceAgent?) -> String {
        if let focused {
            let session = focused.source.session
            return "\(focused.source.name) — \(session.provider.rawValue)" + (session.account.map { " (\($0))" } ?? "")
        }
        guard !agents.isEmpty else { return "" }
        var parts = [agents.count == 1 ? "1 agent" : "\(agents.count) agents"]
        let waiting = agents.filter { $0.source.session.phase == .needsAttention }.count
        let working = agents.filter { $0.source.session.phase == .working }.count
        if waiting > 0 { parts.append(waiting == 1 ? "1 needs you" : "\(waiting) need you") }
        if working > 0 { parts.append("\(working) working") }
        return parts.joined(separator: " · ")
    }

    // MARK: Controls

    @ToolbarContentBuilder
    private func toolbar(_ focused: TraceAgent?) -> some ToolbarContent {
        if focused != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    navigation.selection = nil
                } label: {
                    Label("All Agents", systemImage: "chevron.backward")
                }
                .help("Return to all agents (Esc)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let focused, !focused.root.isHeadless {
                Button {
                    SessionNavigator.open(focused.root, processes: store.processes, accounts: store.accounts)
                } label: {
                    Label("Open Conversation", systemImage: "arrow.up.forward.app")
                }
                .help("Open the interactive session that hosts this agent")
            }
            Toggle(isOn: Binding(get: { showsCommands }, set: { setCommands($0) })) {
                Label("Commands", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .help("Show commands and tool output between messages (⌃O)")
            Toggle(isOn: $followOutput) {
                Label("Follow Output", systemImage: "arrow.down.to.line")
            }
            .help("Keep each terminal on its newest output, and type new replies in")
        }
    }

    /// ⌃O shows commands as Claude Code's ctrl+o does, ⌘1 to ⌘9 zoom a pane, and Esc returns to the grid.
    private func shortcuts(_ agents: [TraceAgent], focused: TraceAgent?) -> some View {
        ZStack {
            Button(showsCommands ? "Hide Commands" : "Show Commands") { setCommands(!showsCommands) }
                .keyboardShortcut("o", modifiers: .control)
            ForEach(Array(agents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                Button("Zoom \(agent.source.name)") { navigation.selection = agent.id }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            if focused != nil {
                Button("Show All Agents") { navigation.selection = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func showsCommands(_ id: TraceSource.ID) -> Bool {
        showsCommands != commandOverrides.contains(id)
    }

    private func toggleCommands(_ id: TraceSource.ID) {
        if commandOverrides.contains(id) { commandOverrides.remove(id) } else { commandOverrides.insert(id) }
    }

    private func setCommands(_ shown: Bool) {
        showsCommands = shown
        commandOverrides.removeAll()
    }

    private func stop(_ source: TraceSource) {
        guard pendingStop == nil else { return }
        pendingStop = source.id
        Task {
            defer { pendingStop = nil }
            if await store.stopCodex(source) { removePane(source.id) }
        }
    }

    private func removePane(_ id: TraceSource.ID) {
        watched.remove(id)
        commandOverrides.remove(id)
        if navigation.selection == id { navigation.selection = nil }
    }
}
