import AppKit
import SwiftUI
import WardenCore

/// One agent in Live Output, drawn as a macOS Terminal window: a title bar with the session's state light, the
/// agent's transcript, and the status line its command-line interface would show.
@MainActor
struct TracePane: View {
    struct Status: Equatable {
        enum Tone: Equatable { case working, attention, failure, waiting, done, idle }

        var tone: Tone
        var headline: String
        var detail: String?
        /// When the turn started for a working agent, nil when its start left the part of the log Warden reads, or
        /// when the session last changed otherwise.
        var since: Date?
        /// When the log last changed, for "no new output" on a long quiet turn.
        var lastActivity: Date
        /// The latest command or tool call, such as "$ swift build".
        var action: String?
    }

    struct Actions {
        var toggleCommands: () -> Void
        var toggleZoom: () -> Void
        var open: (() -> Void)?
        var forceQuit: (() -> Void)?
        var dismiss: (() -> Void)?
    }

    let agent: TraceAgent
    let events: [TraceEvent]?
    let unavailable: Bool
    let status: Status
    let showsCommands: Bool
    let follows: Bool
    let zoomed: Bool
    let busy: Bool
    let actions: Actions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinned = true
    @State private var cover: CGFloat = 0
    @State private var jump = 0

    private var session: AgentSession { agent.source.session }
    private var provider: String { session.provider.rawValue + (session.account.map { " (\($0))" } ?? "") }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        let visible = events.map { TranscriptRenderer.visible($0, showsCommands: showsCommands) }
        VStack(spacing: 0) {
            titleBar
            ZStack(alignment: .topLeading) {
                TraceTerminal(events: visible,
                              style: .init(provider: session.provider, showsCommands: showsCommands, cwd: session.cwd),
                              follows: follows, types: follows && !reduceMotion, jump: jump,
                              label: "\(agent.source.name) output", pinned: $pinned, cover: $cover)
                    .overlay(alignment: .top) {
                        // Terminal never shows half a row while it follows output.
                        canvas.frame(height: cover).allowsHitTesting(false)
                    }
                if unavailable || visible?.isEmpty == true {
                    placeholder(hasCommands: events?.contains { $0.kind == .tool } ?? false)
                }
            }
            .padding(.top, 4)
            .overlay(alignment: .bottomTrailing) {
                if !pinned { latestButton }
            }
            PaneStatusLine(status: status, provider: session.provider, animates: !reduceMotion, open: actions.open)
        }
        .background(canvas)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(borderColor, lineWidth: status.tone == .attention ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .background {
            shape.fill(canvas)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: colorScheme == .dark ? 10 : 7, y: 3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(agent.source.name), \(provider), \(status.headline)")
    }

    private var canvas: Color { Color(nsColor: TracePalette.canvas) }

    private var borderColor: Color {
        switch status.tone {
        case .attention: Color(nsColor: TracePalette.orange)
        case .failure: Color(nsColor: TracePalette.red).opacity(0.7)
        default: Color(nsColor: TracePalette.rim)
        }
    }

    // MARK: Title bar

    private var titleBar: some View {
        ZStack {
            // Clear of the light on the left and the three buttons on the right.
            title
                .padding(.horizontal, 88)
            HStack(spacing: 2) {
                StatusLight(tone: status.tone)
                    .padding(.leading, 12)
                Spacer(minLength: 0)
                PaneIconButton(symbol: "chevron.left.forwardslash.chevron.right", active: showsCommands,
                               label: showsCommands ? "Hide commands" : "Show commands",
                               help: showsCommands ? "Hide commands and tool output" : "Show commands and tool output between messages",
                               action: actions.toggleCommands)
                if hasSessionActions {
                    Menu {
                        sessionActions
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 22, height: 20)
                    .disabled(busy)
                    .accessibilityLabel("Session actions for \(agent.source.name)")
                    .help("Session actions")
                }
                PaneIconButton(symbol: zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               active: false,
                               label: zoomed ? "Show all agents" : "Zoom \(agent.source.name)",
                               help: zoomed ? "Return to all agents (Esc)" : "Give this agent the whole window",
                               action: actions.toggleZoom)
            }
            .padding(.trailing, 6)
        }
        .frame(height: 28)
        .background(titleBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: TracePalette.titleRule)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: actions.toggleZoom)
        .contextMenu {
            Button(zoomed ? "Show All Agents" : "Zoom", action: actions.toggleZoom)
            Button(showsCommands ? "Hide Commands" : "Show Commands", action: actions.toggleCommands)
            if hasSessionActions {
                Divider()
                sessionActions
            }
        }
    }

    private var title: some View {
        HStack(spacing: 0) {
            if agent.parentName != nil {
                Text("↳ ").foregroundStyle(.secondary)
            }
            Text(agent.source.name)
                .fontWeight(.semibold)
                .truncationMode(.middle)
            Text("  —  \(provider)")
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .help(agent.parentName.map { "\(agent.source.name), subagent of \($0)" } ?? "\(agent.source.name)\n\(session.cwd)")
    }

    private var titleBackground: some View {
        Color(nsColor: TracePalette.titleBar)
            .overlay {
                switch status.tone {
                case .attention: Color(nsColor: TracePalette.orange).opacity(colorScheme == .dark ? 0.2 : 0.16)
                case .failure: Color(nsColor: TracePalette.red).opacity(0.14)
                default: Color.clear
                }
            }
    }

    private var hasSessionActions: Bool {
        actions.open != nil || actions.forceQuit != nil || actions.dismiss != nil
    }

    @ViewBuilder private var sessionActions: some View {
        if let open = actions.open {
            Button("Open Conversation", action: open)
        }
        if let forceQuit = actions.forceQuit {
            Button("Force Quit…", role: .destructive, action: forceQuit)
                .disabled(busy)
        }
        if let dismiss = actions.dismiss {
            Button("Dismiss Interrupted Session", action: dismiss)
                .disabled(busy)
        }
    }

    // MARK: Transcript states

    private func placeholder(hasCommands: Bool) -> some View {
        let text = unavailable ? "Local transcript unavailable."
            : hasCommands && !showsCommands ? "No written update in the recent log. Press Control-O to see its commands."
            : "Waiting for a written update…"
        return Text(text)
            .font(.system(size: TracePalette.pointSize, design: .monospaced))
            .foregroundStyle(Color(nsColor: TracePalette.dim))
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .allowsHitTesting(false)
    }

    private var latestButton: some View {
        Button {
            jump += 1
        } label: {
            Label("Latest", systemImage: "arrow.down")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color(nsColor: TracePalette.titleBar)))
                .overlay(Capsule().strokeBorder(Color(nsColor: TracePalette.rim)))
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .padding(10)
        .help("Scroll to the newest output")
    }
}

/// The light where Terminal draws its traffic lights: one colour per state, a ring when the session rests.
private struct StatusLight: View {
    let tone: TracePane.Status.Tone

    var body: some View {
        Group {
            if tone == .idle {
                Circle().strokeBorder(Color(nsColor: TracePalette.dim), lineWidth: 1.5)
            } else {
                Circle().fill(color)
                    .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .working: Color(nsColor: .systemGreen)
        case .attention: Color(nsColor: .systemOrange)
        case .failure: Color(nsColor: .systemRed)
        case .waiting: Color(nsColor: .systemYellow)
        case .done, .idle: Color(nsColor: .systemGray)
        }
    }
}

private struct PaneIconButton: View {
    let symbol: String
    let active: Bool
    let label: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : hovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.08) : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(help)
    }
}

/// The line a command-line agent keeps under its transcript: a spinner while it works, with the turn's time and its
/// latest command, or the state the session rests in.
private struct PaneStatusLine: View {
    let status: TracePane.Status
    let provider: AgentProvider
    let animates: Bool
    let open: (() -> Void)?

    /// Panes that rest refresh their age together, so one window update serves all of them.
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    var body: some View {
        Group {
            if status.tone == .working {
                WorkingStatusLine(status: status, provider: provider, animates: animates)
            } else {
                TimelineView(.periodic(from: Self.epoch, by: 30)) { context in
                    line(now: context.date)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(now: Date) -> some View {
        let detail = StatusText.restingDetail(status, now: now)
        return HStack(spacing: 0) {
            (symbol + Text(" ") + headline)
                .layoutPriority(1)
            Text(detail)
                .foregroundColor(Color(nsColor: TracePalette.dim))
            Spacer(minLength: 8)
            if status.tone == .attention, let open {
                Button("Open", action: open)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Open the conversation to answer")
            }
        }
        .font(.system(size: TracePalette.pointSize, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.headline + detail)
    }

    private var symbol: Text {
        let color = Color(nsColor: StatusText.tint(status.tone))
        let name = switch status.tone {
        case .attention: "exclamationmark.circle.fill"
        case .failure: "xmark.octagon.fill"
        case .waiting: "hourglass"
        case .done: "checkmark.circle"
        case .working, .idle: "pause.circle"
        }
        return Text(Image(systemName: name)).foregroundColor(color)
    }

    private var headline: Text {
        let quiet = status.tone == .done || status.tone == .idle
        let text = Text(status.headline).foregroundColor(Color(nsColor: quiet ? TracePalette.dim : StatusText.tint(status.tone)))
        return status.tone == .attention || status.tone == .failure ? text.fontWeight(.semibold) : text
    }
}

enum StatusText {
    static let frame: TimeInterval = 0.2
    private static let claudeSpinner = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]

    static func tint(_ tone: TracePane.Status.Tone) -> NSColor {
        switch tone {
        case .working: TracePalette.green
        case .attention: TracePalette.orange
        case .failure: TracePalette.red
        case .waiting: TracePalette.yellow
        case .done, .idle: TracePalette.dim
        }
    }

    /// "✻ Working… (4m 05s · $ swift build)" for Claude Code, "• Working (4m 05s · $ swift build)" for Codex. The
    /// command is shortened first when the line is wider than `columns`.
    static func working(_ status: TracePane.Status, provider: AgentProvider, frame: Int?, now: Date,
                        columns: Int? = nil) -> NSAttributedString {
        let line = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            line.append(NSAttributedString(string: text, attributes: [.font: TracePalette.font, .foregroundColor: color]))
        }
        let glyph = provider == .claude ? claudeSpinner[(frame ?? 4) % claudeSpinner.count] : "•"
        add(glyph + " ", TracePalette.green)
        let word = status.headline + (provider == .claude ? "…" : "")
        if let frame {
            // A bright band sweeps across the verb, as both command-line agents animate their working state.
            let center = frame % (word.count + 10) - 5
            for (index, character) in word.enumerated() {
                let distance = abs(index - center)
                add(String(character), distance == 0 ? TracePalette.strong : distance == 1 ? TracePalette.text : TracePalette.dim)
            }
        } else {
            add(word, TracePalette.text)
        }
        var parts = status.since.map { [elapsed(now.timeIntervalSince($0))] } ?? []
        if let detail = status.detail {
            parts.append(detail)
        } else if now.timeIntervalSince(status.lastActivity) >= 600 {
            parts.append("no new output for \(MenuFormat.remaining(now.timeIntervalSince(status.lastActivity)))")
        }
        if var action = status.action {
            if let columns {
                let used = line.length + 4 + parts.reduce(0) { $0 + $1.count + 3 }
                action = TranscriptText.clip(action, max(8, columns - used))
            }
            parts.append(action)
        }
        if !parts.isEmpty { add(" (" + parts.joined(separator: " · ") + ")", TracePalette.dim) }
        line.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    static func restingDetail(_ status: TracePane.Status, now: Date) -> String {
        var parts = status.detail.map { [$0] } ?? []
        if status.tone != .waiting, let since = status.since {
            let seconds = now.timeIntervalSince(since)
            parts.append(seconds < 60 ? "just now" : MenuFormat.age(since: since, now: now) + " ago")
        }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    /// A turn's running time as command-line agents print it: "48s", "4m 05s", "1h 02m".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return String(format: "%dm %02ds", total / 60, total % 60) }
        return String(format: "%dh %02dm", total / 3600, total % 3600 / 60)
    }
}

/// The working status line is drawn by AppKit. Its spinner ticks five times a second, and redrawing one line costs far
/// less than a SwiftUI update of the whole window for every frame.
private struct WorkingStatusLine: NSViewRepresentable {
    let status: TracePane.Status
    let provider: AgentProvider
    let animates: Bool

    func makeNSView(context: Context) -> WorkingStatusView { WorkingStatusView() }

    func updateNSView(_ view: WorkingStatusView, context: Context) {
        view.show(status, provider: provider, animates: animates)
    }
}

@MainActor
final class WorkingStatusView: NSView {
    private var status: TracePane.Status?
    private var provider = AgentProvider.claude
    private var animates = true
    private var line = NSAttributedString()
    private var spokenSecond = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }

    func show(_ status: TracePane.Status, provider: AgentProvider, animates: Bool) {
        self.status = status
        self.provider = provider
        self.animates = animates
        StatusClock.shared.add(self)
        refresh(Date())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { StatusClock.shared.remove(self) } else if status != nil { StatusClock.shared.add(self) }
    }

    func tick(_ now: Date) {
        guard let window, window.occlusionState.contains(.visible) else { return }
        refresh(now)
    }

    override func setFrameSize(_ size: NSSize) {
        let widthChanged = size.width != frame.width
        super.setFrameSize(size)
        if widthChanged { refresh(Date()) }
    }

    private func refresh(_ now: Date) {
        guard let status else { return }
        let frame = animates ? Int(now.timeIntervalSinceReferenceDate / StatusText.frame) : nil
        let columns = bounds.width > 0 ? Int(bounds.width / TracePalette.column) - 1 : nil
        let next = StatusText.working(status, provider: provider, frame: frame, now: now, columns: columns)
        guard next != line else { return }
        line = next
        needsDisplay = true
        // The words change at most once a second; only the spinner and the shimmer change between frames.
        let second = Int(now.timeIntervalSinceReferenceDate)
        guard second != spokenSecond else { return }
        spokenSecond = second
        setAccessibilityLabel(String(StatusText.working(status, provider: provider, frame: nil, now: now).string.dropFirst(2)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let height = ceil(TracePalette.font.ascender - TracePalette.font.descender)
        line.draw(with: NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}

/// One timer for every working status line, running only while one is on screen.
@MainActor
private final class StatusClock {
    static let shared = StatusClock()
    private let views = NSHashTable<WorkingStatusView>.weakObjects()
    private var timer: Timer?

    func add(_ view: WorkingStatusView) {
        views.add(view)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: StatusText.frame, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = StatusText.frame / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func remove(_ view: WorkingStatusView) {
        views.remove(view)
    }

    private func tick() {
        let live = views.allObjects
        guard !live.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        let now = Date()
        for view in live { view.tick(now) }
    }
}
