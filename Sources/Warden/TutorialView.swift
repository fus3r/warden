import AppKit
import SwiftUI
import UserNotifications
import WardenCore

/// A replayable guide. Practice state belongs only to this view; real actions use the app's existing controls.
struct TutorialView: View {
    enum Chapter: String, CaseIterable, Identifiable {
        case menu, connect, decisions, limits, history, jobs, away, personalize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .menu: return "Find your agents"
            case .connect: return "Connect your sessions"
            case .decisions: return "Answer and get alerted"
            case .limits: return "Plan with your limits"
            case .history: return "Understand your usage"
            case .jobs: return "Protect long jobs"
            case .away: return "Step away from the Mac"
            case .personalize: return "Make Warden yours"
            }
        }
        var symbol: String {
            switch self {
            case .menu: return "menubar.rectangle"
            case .connect: return "link"
            case .decisions: return "bell.badge"
            case .limits: return "gauge.with.dots.needle.50percent"
            case .history: return "chart.bar.xaxis"
            case .jobs: return "terminal"
            case .away: return "iphone"
            case .personalize: return "slider.horizontal.3"
            }
        }
    }

    @ObservedObject var store: WardenStore
    @ObservedObject var trainGuard: TrainGuardSetup
    @ObservedObject var phone: PhoneCompanion
    @ObservedObject var power: KeepAwake
    let openSettings: (String) -> Void
    let openHistory: () -> Void
    let openPlanner: () -> Void
    let close: () -> Void
    @AppStorage("tutorialChapter") private var selected = Chapter.menu.rawValue
    @AppStorage("tutorialExplored") private var explored = ""
    @AppStorage("tutorialFinished") private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var practice = 0
    @State private var practiceAnswer = ""
    @State private var demoContext = 72.0
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var notificationResult: String?
    @State private var openedMenu = false
    @State private var requestingNotifications = false

    init(store: WardenStore, openSettings: @escaping (String) -> Void,
         openHistory: @escaping () -> Void, openPlanner: @escaping () -> Void, close: @escaping () -> Void) {
        self.store = store; self.trainGuard = store.trainGuard; self.phone = store.phone; self.power = store.keepAwake
        self.openSettings = openSettings; self.openHistory = openHistory; self.openPlanner = openPlanner; self.close = close
    }

    private var chapter: Chapter { Chapter(rawValue: selected) ?? .menu }
    private var index: Int { Chapter.allCases.firstIndex(of: chapter) ?? 0 }
    private var visited: Set<String> { Set(explored.split(separator: ",").map(String.init)) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Warden").font(.title2.weight(.semibold))
                Text("Interactive guide").font(.subheadline).foregroundStyle(.secondary)
                VStack(spacing: 3) {
                    ForEach(Chapter.allCases) { item in
                        Button { selected = item.rawValue } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.title).frame(maxWidth: .infinity, alignment: .leading)
                                if visited.contains(item.rawValue) {
                                    Image(systemName: "checkmark").font(.caption).accessibilityLabel("Explored")
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 10)
                            .background(chapter == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.title + (chapter == item ? ", selected" : ""))
                    }
                }
                Spacer()
                Text("Pick any chapter. Your place is saved on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Continue later", action: close).buttonStyle(.link)
            }
            .padding(20).frame(width: 230).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chapter.title).font(.title2.weight(.semibold))
                    Spacer()
                    Text("\(index + 1) of \(Chapter.allCases.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(24)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { content }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                Divider()
                HStack {
                    Button("Back") { selected = Chapter.allCases[index - 1].rawValue }.disabled(index == 0)
                    Text("\(visited.count) of \(Chapter.allCases.count) chapters explored")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(index == Chapter.allCases.count - 1 ? "Finish guide" : "Next") {
                        markExplored()
                        if index == Chapter.allCases.count - 1 { finished = true; close() }
                        else { selected = Chapter.allCases[index + 1].rawValue }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(20)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 840, minHeight: 600)
        .task {
            trainGuard.refresh(accounts: store.accounts)
            refreshNotifications()
            if Chapter(rawValue: selected) == nil { selected = Chapter.menu.rawValue }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trainGuard.refresh(accounts: store.accounts); refreshNotifications()
        }
    }

    @ViewBuilder private var content: some View {
        switch chapter {
        case .menu: menuLesson
        case .connect: connectionLesson
        case .decisions: decisionLesson
        case .limits: limitsLesson
        case .history: historyLesson
        case .jobs: jobsLesson
        case .away: awayLesson
        case .personalize: personalizeLesson
        }
    }

    private var menuLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The lantern in your menu bar is your starting point. Its count follows open coding sessions; an exclamation mark means an agent needs you.")
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Live on this Mac", systemImage: "desktopcomputer").font(.headline)
                    HStack(spacing: 26) {
                        Label("\(store.attentionCount) need you", systemImage: "exclamationmark.bubble")
                        Label("\(store.activeCount) working", systemImage: "gearshape.2")
                    }
                    if store.sessions.isEmpty {
                        Text("No coding sessions yet. Start Claude Code or Codex; this panel will update when Warden sees it.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(store.sessions.prefix(3))) { session in
                            Button { store.open(sessionID: session.id); markExplored() } label: {
                                HStack { Text(session.title ?? session.project); Spacer(); Image(systemName: "arrow.up.forward") }
                            }.help("Return to this existing session")
                        }
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Open the Warden menu") { store.openMenu?(); openedMenu = true; markExplored() }
                .buttonStyle(.borderedProminent)
            if openedMenu { feedback("You can reopen it from the lantern at any time.") }
            lesson("Needs You comes first", "Questions and approvals sit above running work. Click a session to return to its terminal or editor; Warden keeps the account and project together.")
            lesson("Recent Sessions keeps the rest", "Finished and quiet sessions move out of the way. Background agents are grouped with the session that started them.")
        }
    }

    private var connectionLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Warden discovers local sessions automatically. Connect Claude Code for exact context readings and approval buttons.")
            ForEach(store.accounts) { account in
                let count = store.sessions.filter { $0.provider == account.provider && $0.account == account.name }.count
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.provider.rawValue + (account.name.map { " (\($0))" } ?? "")).font(.headline)
                        Text("\(count) sessions observed").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.provider == .claude {
                        let connection = account.name == nil ? store.claudeConnection : store.otherConnections[account.id] ?? .notConnected
                        if connection == .connected { Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        else { Button(connection == .needsRepair ? "Repair…" : "Connect…") { store.confirmAndConnectClaude(account) } }
                    } else { Label("Automatic", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                }
                Divider()
            }
            if let message = store.connectionMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
            Button("Check for sessions") { store.refresh(usage: false) }
            lesson("Several accounts", "Work and personal account folders stay separate. Warden finds folders beside the defaults; use General to add an account elsewhere.")
            Button("Manage accounts…") { openSettings("general") }
            Text("Connecting shows the exact changes first and backs up the provider's settings. Ordinary ChatGPT and Claude chats do not supply the coding-session events used here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var decisionLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Try answering a practice prompt, then choose how real sessions should alert you.")
            GroupBox("Practice session · no command is executed") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(practice == 0 ? "Ready to try" : practice == 1 ? "Working" : practice == 2 ? "Needs You" : "Answer received",
                          systemImage: practice == 2 ? "exclamationmark.bubble.fill" : "terminal")
                        .font(.headline)
                    if practice == 0 {
                        Button("Start practice") {
                            practice = 1
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 800))
                                if practice == 1 { practice = 2 }
                            }
                        }
                    } else if practice == 1 {
                        ProgressView("The sample agent is preparing a command…").controlSize(.small)
                    } else if practice == 2 {
                        Text("The agent wants to run:")
                        Text("printf 'Hello from Warden\\n'").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        HStack {
                            Button("Allow once") { answerPractice("Allowed once. The sample agent can continue.") }.buttonStyle(.borderedProminent)
                            Button("Deny") { answerPractice("Denied. The sample agent waits for new instructions.") }
                        }
                    } else {
                        feedback(practiceAnswer)
                        Button("Try again") { practice = 0 }
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Real prompts can also offer a session-wide or permanent rule. Warden sends exactly the option you choose; answering in the terminal closes the prompt here too.")
                .font(.callout)
            Divider()
            HStack {
                Label(notificationLabel, systemImage: "bell")
                Spacer()
                if notificationStatus == .notDetermined {
                    Button(requestingNotifications ? "Requesting…" : "Allow notifications…") { requestNotifications() }.disabled(requestingNotifications)
                } else if notificationStatus == .authorized || notificationStatus == .provisional {
                    Button("Send test notification") { sendTestNotification() }
                } else { Button("Notification settings…") { openSettings("setup") } }
            }
            if let notificationResult { Text(notificationResult).font(.caption).foregroundStyle(.secondary) }
            lesson("Choose your level of interruption", "All Alerts includes completions. Only When Needed keeps questions, approvals and failures. Snooze pauses alerts for an hour. Option-click a session to mute it.")
            Button("Choose sounds and alert rules…") { openSettings("general") }
        }
    }

    private var limitsLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Context is the conversation a model can hold. Usage limits are shared across sessions on the same account. They answer different questions.")
            GroupBox("Try a context reading · sample") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Session context"); Spacer(); Text("\(Int(demoContext))%").monospacedDigit() }
                    ProgressView(value: demoContext, total: 100).tint(demoContext >= 85 ? .orange : .accentColor)
                    Slider(value: $demoContext, in: 10...100).accessibilityLabel("Sample context percentage")
                    Text(demoContext >= 85 ? "Compact or start a new session before a large prompt." : "There is room for more context. The quota may still constrain the next task.")
                        .font(.callout)
                }.padding(10)
            }
            if store.windows.isEmpty {
                Text("Your account limits will appear when the provider reports them.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.windows.prefix(3))) { window in
                    LabeledContent(window.name, value: "\(Int(window.usedPercent))% used")
                }
            }
            lesson("Check before starting more work", "Work Planner compares 30, 60 and 120 minutes at different paces and margins. Each route includes its shared account quota. Read the evidence beside estimates.")
            Button("Open Work Planner…") { openPlanner(); markExplored() }.buttonStyle(.borderedProminent)
            lesson("Catch costly waits", "The menu shows approaching resets and Claude prompt-cache deadlines. Context, pace and heavy-session alerts help you act before work stalls.")
        }
    }

    private var historyLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("History turns local activity into a report you can inspect by period, account and project.")
            lesson("Tokens and requests", "Compare projects and models over 7, 30 or 90 days. Select a day for its breakdown and export the current selection to CSV.")
            lesson("Where the quota went", "Limits attributes observed quota changes to local work and keeps unexplained usage visible. API price equivalents are optional estimates, separate from your subscription bill.")
            lesson("Where your time went", "Activity shows when agents worked and when they waited for you. The away summary brings you up to date after you return to the Mac.")
            Button("Explore History…") { openHistory(); markExplored() }.buttonStyle(.borderedProminent)
            Button("Choose what to record…") { openSettings("usage") }
            Text("Reports stay on this Mac. Conversation contents are not saved in the history; exported reports can include project paths.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var jobsLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("train-guard supervises long local jobs. It pauses on battery and lowers priority when warm, then resumes the same process when conditions improve.")
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(trainGuard.install == .none ? "Ready to install" : "train-guard detected", systemImage: "terminal").font(.headline)
                    Text("The app includes the runtime. No Python setup or package download is needed on your Mac.").font(.callout)
                    Button("Set up train-guard…") { openSettings("general") }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
            lesson("Start a job under supervision", "In a terminal, prefix the command with train-guard run. Warden can add this instruction to your agents so they use it for long jobs.")
            command("train-guard run --name demo -- /bin/sleep 30")
            lesson("Already running? Attach it", "Use train-guard attach --pid <pid> --name <name>. Attaching does not restart the process. Only name an owning agent when you know which session launched it.")
            command("train-guard status")
            lesson("Control one session", "Ignore train-guard in the Warden menu lets one session run at full speed. Turn it back on to restore the policy. Stop supervision with train-guard stop <name>; add --kill only to end the job too.")
            Text("Running supervised jobs also count toward Keep Awake, even when their agent has finished its turn.")
                .font(.callout)
        }
    }

    private var awayLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keep work available when you leave the keyboard, and answer from a paired phone.")
            HStack {
                Label(power.status, systemImage: power.isAwake ? "cup.and.saucer.fill" : "moon")
                Spacer(); Button("Power settings…") { openSettings("power") }
            }
            Text("Keep Awake covers running agents, train-guard jobs and answerable prompts for a paired phone. Battery reserve and thermal protection still apply. Closed-lid work uses the macOS power service.").font(.callout)
            Divider()
            HStack {
                Label(phone.pairedCount == 0 ? "No phone paired yet" : "\(phone.pairedCount) phone(s) paired", systemImage: "iphone")
                Spacer(); Button("Connect a phone…") { openSettings("phone") }
            }
            lesson("Keep decisions in your hands", "Your phone shows the same questions and approvals as the Mac. An answer closes the prompt on both screens. Unpair a device in Phone settings to revoke its access.")
            lesson("Review before an absence", "Work Planner's departure review gathers pending decisions, context pressure, cache deadlines and power protection in one place.")
            Button("Open departure review…") { openPlanner(); markExplored() }
        }
    }

    private var personalizeLesson: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose the options that fit how you work. You can return to any chapter whenever you need it.")
            destination("Alert styles and shortcuts", detail: "Per-agent and per-session styles, quiet hours, call-aware silence, menu visibility, global shortcuts and login startup.", tab: "general")
            destination("Sounds", detail: "Preview the sound bank, choose a voice or import your own audio for each event.", tab: "sounds")
            destination("Automations", detail: "Run your own scripts on selected events. Inspect each script before enabling it; the test button really runs the scripts.", tab: "automations")
            lesson("Desktop widgets", "Edit Widgets on the desktop and search for Warden. Choose sessions or usage; clicking a session returns to its work.")
            lesson("Use Warden in your own tools", "WardenBridge status or status --json exposes counts and limits for scripts and status bars.")
            feedback("Replay or resume this guide from the Warden menu or Settings → Setup.")
            Button("Restart guide") { explored = ""; selected = Chapter.menu.rawValue; finished = false; practice = 0 }
        }
    }

    private func lesson(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).foregroundStyle(.secondary) }
    }
    private func destination(_ title: String, detail: String, tab: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(title + "…") { openSettings(tab) }.font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
    }
    private func feedback(_ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
    }
    private func command(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                .help("Copy command; nothing is executed")
        }.padding(12).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
    private func markExplored() { explored = visited.union([chapter.rawValue]).sorted().joined(separator: ",") }
    private func answerPractice(_ answer: String) { practiceAnswer = answer; practice = 3; markExplored() }
    private var notificationLabel: String {
        switch notificationStatus {
        case .authorized, .provisional: return "Notifications allowed by macOS"
        case .denied: return "Notifications blocked in macOS"
        case .notDetermined: return "Notifications not requested"
        default: return "Checking notification permission…"
        }
    }
    private func refreshNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { value in
            Task { @MainActor in notificationStatus = value.authorizationStatus }
        }
    }
    private func requestNotifications() {
        requestingNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            Task { @MainActor in requestingNotifications = false; notificationResult = error?.localizedDescription; refreshNotifications() }
        }
    }
    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Warden is ready"; content.body = "A test notification from the interactive guide."; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "warden-tutorial-test", content: content, trigger: nil)) { error in
            Task { @MainActor in notificationResult = error?.localizedDescription ?? "Test submitted. Focus and macOS banner settings can affect delivery." }
        }
    }
}
