import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications
import WardenCore

enum AlertMode: String {
    case all
    case attention
}

/// How an alert reaches you. Each agent has a general style in Settings, and a session can use its own.
/// The raw values keep the earlier sound settings.
enum AlertStyle: String, CaseIterable {
    case chime, off, voice, both, muted

    var title: String {
        switch self {
        case .chime: return "Notification"
        case .off: return "Silent Notification"
        case .voice: return "Voice"
        case .both: return "Notification and Voice"
        case .muted: return "No Alerts"
        }
    }

    var notifies: Bool { self == .chime || self == .off || self == .both }
    var speaks: Bool { self == .voice || self == .both }

    static func general(for provider: AgentProvider) -> AlertStyle {
        let key = provider == .codex ? "soundCodex" : "soundClaude"
        return AlertStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .chime
    }
}

/// A permission prompt or question waiting in Claude Code or Codex, which Warden can answer.
struct PendingApproval {
    var request: ApprovalRequest
    var receivedAt: Date
}

/// A Claude session's prompt cache, when letting it expire costs enough to mention, with that cost in points of its
/// account's 5-hour limit.
struct CacheNote {
    let cache: PromptCache
    /// Points of the 5-hour limit that writing the context to the cache again takes, estimated; nil without a rate.
    let points: Double?
    /// "Claude 5h", or "Claude (work) 5h".
    let window: String

    /// "about 3.8% of Claude 5h", or the context size when no rate converts it.
    var cost: String {
        points.map { "about \(MenuFormat.points($0)) of \(window)" } ?? "\(MenuFormat.tokens(cache.tokens)) tokens at the cache write price"
    }
}

enum ApprovalChoice {
    case allow, allowForSession, allowAlways, deny
    case option(Int)
}

@MainActor
final class WardenStore: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var windows: [UsageWindow] = []
    @Published private(set) var plans: [PlanDetails] = []
    /// The default Claude and Codex accounts, and any other account folders found or added.
    @Published private(set) var accounts: [AgentAccount] = WardenStore.discoverAccounts()
    /// The hook connection of each Claude account other than the default one, by account id.
    @Published private(set) var otherConnections: [String: ClaudeConnection] = [:]
    @Published private(set) var processes: [AgentProcess] = []
    @Published private(set) var nativeApps: [String] = []
    @Published private(set) var scannedAt: Date?
    @Published private(set) var claudeConnection: ClaudeConnection = .notConnected
    @Published var connectionMessage: String?
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginError: String?
    /// Token use and its cost at API prices, from the session logs. Nil until the first read finishes.
    @Published private(set) var history: UsageSummary?
    /// Each limit's rises split among the sessions and projects that caused them. Nil until the first read finishes.
    @Published private(set) var quota: QuotaSummary?
    /// Spans of work and of waiting for you that ended, for the activity report. Open spans are in `activity`.
    @Published private(set) var activitySpans: [ActivitySpan] = []
    @Published private(set) var activity = ActivityRecorder()
    @Published private(set) var paceTracker = UsagePaceTracker()
    /// Claude Code and Codex permission prompts and questions that can be answered from Warden, oldest first.
    @Published private(set) var approvals: [PendingApproval] = []

    private let scanner = TelemetryScanner()
    private let approvalServer = ApprovalServer()
    /// A connection to each Codex account's shared daemon while answering is on, by account id.
    private var codexClients: [String: CodexDaemonClient] = [:]
    /// What waiting Codex sessions wait for, which their logs never record, by account id and session id.
    private var codexWaits: [String: [String: CodexApprovals.Wait]] = [:]
    private let hotKeys = HotKeys()
    /// Shortcuts from Settings that another app already holds.
    @Published private(set) var takenShortcuts: Set<String> = []
    /// Opens the menu bar menu, set by the app.
    var openMenu: (() -> Void)?
    var openTutorial: (() -> Void)?
    private let usageHistory = UsageHistory()
    private let quotaLedger = QuotaLedger()
    private let activityLog = ActivityLog()
    /// Limit readings taken since the last history read, which the quota ledger splits once the logs cover them.
    private var quotaReadings: [UsageWindow] = []
    private let historyQueue = DispatchQueue(label: "Warden.history", qos: .utility)
    private var isReadingHistory = false
    private var historyReadAt = Date.distantPast
    private var accountsDiscoveredAt = Date.distantPast
    let sounds = SoundLibrary()
    let automations = Automations()
    /// Installs train-guard and tells agents to use it, from Settings.
    #if DEBUG
    let trainGuard = TrainGuardSetup(home: DebugSupport.trainGuardHome)
    #else
    let trainGuard = TrainGuardSetup()
    #endif
    /// The page a paired phone opens on the local network.
    let phone = PhoneCompanion()
    private let widgets = WidgetFeed()
    private lazy var alerts = AlertEngine(sounds: sounds)
    private var presence = PresenceTracker()
    /// Limit readings from when the current absence began, to say how the limits moved.
    private var windowsWhenAway: [UsageWindow] = []
    /// What happened during your latest absence, shown in the menu for half an hour after you return.
    @Published private(set) var awayDigest: AwayDigest?
    /// What each provider's status page said the last time a session failed in a way that may be the provider's.
    @Published private(set) var incidents: [AgentProvider: ProviderIncident] = [:]
    private var statusCheckedAt: [AgentProvider: Date] = [:]
    /// No cookies, cache, or credentials: status pages need none.
    private static let statusSession = URLSession(configuration: .ephemeral)
    let keepAwake = KeepAwake()
    private var timer: Timer?
    private var isScanning = false
    private var usageRequested = false
    private var hasBaseline = false
    private var previousSessions: [String: AgentSession] = [:]
    private var previousWindows: [String: UsageWindow] = [:]
    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "alertAttention": true,
            "alertFinish": true,
            "alertContext": true,
            "alertQuota": true,
            "contextThreshold": 85.0,
            "soundCodex": "chime",
            "soundClaude": "chime",
            "quietHours": false,
            "quietFrom": 22,
            "quietUntil": 8,
            "alertMode": AlertMode.all.rawValue,
            "menuBarUsage": false,
            "codexAccountUsage": true,
            "claudeAccountUsage": true,
            "answerFromWarden": true,
            "quietInFront": true,
            "historyEnabled": true,
            "showAPIEquivalent": false,
            "showWorkPlanner": true,
            "activityEnabled": true,
            "alertQuotaThreshold": 90.0,
            "alertPace": true,
            "alertHeavySession": true,
            "alertCache": true,
            "quietDuringCalls": true,
            "awaySummary": true,
            "awayMinutes": 15,
            "automationsEnabled": false,
            "checkProviderStatus": false,
            "keepAwake": false,
            "alertUnused": false,
            "dailyBudget": 0.0,
            "menuShowsUsage": true,
            "menuShowsRecent": true,
            "menuShowsAlerts": true
        ])
    }

    func start() {
        keepAwake.start()
        #if DEBUG
        if DebugSupport.usesFixture {
            let fixture = DebugSupport.sampleScan()
            sessions = fixture.sessions
            keepAwake.update(working: activeCount > 0)
            windows = fixture.windows
            scannedAt = fixture.scannedAt
            paceTracker = DebugSupport.samplePace(windows: windows)
            history = DebugSupport.sampleHistory()
            quota = DebugSupport.sampleQuota()
            awayDigest = DebugSupport.sampleAway()
            incidents[.claude] = ProviderIncident(provider: .claude, summary: "Elevated errors on Claude Opus 5.5", checkedAt: Date())
            approvals = DebugSupport.sampleApprovals()
            startPhone()
            updateWidgets()
            return
        }
        #endif
        alerts.onOpen = { [weak self] id in self?.open(sessionID: id) }
        alerts.onMute = { [weak self] id in self?.toggleMute(sessionID: id) }
        alerts.onAnswer = { [weak self] id, choice in self?.answer(id, choice) }
        alerts.isInFront = { [weak self] session in
            guard let self, self.defaults.bool(forKey: "quietInFront") else { return false }
            return SessionNavigator.isInFront(session, processes: self.processes)
        }
        alerts.cacheNote = { [weak self] session in self?.cacheNote(for: session) }
        alerts.onEvent = { [weak self] event in
            guard let self else { return }
            self.automations.post(event)
            if event.alerted, event.event == "needs-you", self.phone.enabled, self.phone.usesRelay {
                self.phone.remote.notify()
            }
        }
        alerts.onOpenMenu = { [weak self] in self?.openMenu?() }
        alerts.start()
        approvalServer.onRequest = { [weak self] request in
            MainActor.assumeIsolated { self?.receive(request) }
        }
        approvalServer.onGone = { [weak self] id in
            MainActor.assumeIsolated { self?.forget(id) }
        }
        setAnswersFromWarden(defaults.bool(forKey: "answerFromWarden"))
        startPhone()
        updateShortcuts()
        // Loaded before the first scan, so a relaunch continues saved spans rather than counting their time again.
        let log = activityLog
        activitySpans = historyQueue.sync { log.all }
        activity = ActivityRecorder(saved: activitySpans.filter { $0.end > Date().addingTimeInterval(-86_400) })
        refresh()
        refreshHistory()
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.refreshHistory()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Sessions that need you: approvals first, then questions, errors, and interrupted turns, oldest first.
    var attentionQueue: [AgentSession] {
        let rank: [AttentionKind: Int] = [.permission: 0, .question: 1, .choice: 1, .failure: 2, .interrupted: 3, .notification: 4]
        return sessions.filter { $0.phase == .needsAttention }.sorted {
            let left = rank[$0.attention ?? .notification] ?? 5
            let right = rank[$1.attention ?? .notification] ?? 5
            return left != right ? left < right : $0.updatedAt < $1.updatedAt
        }
    }

    /// Registers the shortcuts chosen in Settings.
    func updateShortcuts() {
        hotKeys.register([
            (Shortcut.find(defaults.string(forKey: "shortcutOpen")), { [weak self] in self?.openMenu?() }),
            (Shortcut.find(defaults.string(forKey: "shortcutJump")), { [weak self] in self?.showMostUrgent() })
        ])
        takenShortcuts = hotKeys.taken
    }

    /// Brings forward the session that has waited longest for the most pressing answer, or opens the menu.
    func showMostUrgent() {
        if let session = attentionQueue.first { open(sessionID: session.id) } else { openMenu?() }
    }

    var activeCount: Int { sessions.filter { $0.phase == .working }.count }
    var attentionCount: Int { sessions.filter { $0.phase == .needsAttention }.count }
    var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WardenBridge") }

    var alertMode: AlertMode {
        AlertMode(rawValue: defaults.string(forKey: "alertMode") ?? "") ?? .all
    }

    var snoozedUntil: Date? {
        let date = defaults.object(forKey: "snoozedUntil") as? Date
        return date.flatMap { $0 > Date() ? $0 : nil }
    }

    func setAlertMode(_ mode: AlertMode) {
        defaults.set(mode.rawValue, forKey: "alertMode")
        defaults.removeObject(forKey: "snoozedUntil")
        objectWillChange.send()
        publishToPhone()
    }

    func snooze(for interval: TimeInterval) {
        defaults.set(Date().addingTimeInterval(interval), forKey: "snoozedUntil")
        objectWillChange.send()
        publishToPhone()
    }

    func refresh(usage: Bool = false) {
        #if DEBUG
        if DebugSupport.usesFixture { return }
        #endif
        guard !isScanning else {
            usageRequested = usageRequested || usage
            return
        }
        isScanning = true
        if Date().timeIntervalSince(accountsDiscoveredAt) >= 60 {
            let discovered = Self.discoverAccounts()
            if discovered != accounts { accounts = discovered }
            accountsDiscoveredAt = Date()
        }
        connectCodex()
        let scanner = self.scanner
        let helper = helperURL
        let accounts = self.accounts
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scanner.scan(accounts: accounts, refreshUsage: usage)
            let events = Self.claudeEvents()
            var connections: [String: ClaudeConnection] = [:]
            for account in accounts where account.provider == .claude {
                connections[account.id] = ClaudeInstaller.status(helper: helper, settingsURL: Self.settings(of: account), events: events)
            }
            DispatchQueue.main.async {
                self?.apply(result, connections: connections)
            }
        }
    }

    private var writtenState: WardenState?

    /// Saves the session counts for `WardenBridge status`: when they change, and once a minute so a reader can
    /// tell that Warden still runs.
    private func writeState() {
        let state = WardenState(needsYou: attentionCount, working: activeCount, updatedAt: Date())
        if let old = writtenState, old.needsYou == state.needsYou, old.working == state.working,
           state.updatedAt.timeIntervalSince(old.updatedAt) < 60 { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: WardenPaths.support, withIntermediateDirectories: true)
        try? data.write(to: WardenPaths.stateFile, options: .atomic)
        writtenState = state
    }

    // MARK: Accounts

    /// Accounts in folders beside `~/.claude` and `~/.codex`, such as `~/.claude-work`, and folders added in Settings.
    nonisolated static func discoverAccounts() -> [AgentAccount] {
        let defaults = UserDefaults.standard
        let added = (defaults.stringArray(forKey: "accountFolders") ?? []).map { URL(fileURLWithPath: $0) }
        let removed = Set(defaults.stringArray(forKey: "removedAccountFolders") ?? [])
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        return Accounts.discover(home: FileManager.default.homeDirectoryForCurrentUser, codexHome: codexHome,
                                 added: added, removed: removed)
    }

    nonisolated static func settings(of account: AgentAccount) -> URL {
        account.folder.appendingPathComponent("settings.json")
    }

    /// Adds an account folder, such as the one `CLAUDE_CONFIG_DIR` names. Returns false for a folder with no sessions.
    func addAccount(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let defaults = UserDefaults.standard
        defaults.set(Array(Set((defaults.stringArray(forKey: "accountFolders") ?? []) + [path])), forKey: "accountFolders")
        defaults.set((defaults.stringArray(forKey: "removedAccountFolders") ?? []).filter { $0 != path }, forKey: "removedAccountFolders")
        reloadAccounts()
        guard accounts.contains(where: { $0.folder.path == path }) else {
            defaults.set((defaults.stringArray(forKey: "accountFolders") ?? []).filter { $0 != path }, forKey: "accountFolders")
            return false
        }
        return true
    }

    /// Stops following an account's folder. Its logs and settings stay as they are.
    func removeAccount(_ account: AgentAccount) {
        let defaults = UserDefaults.standard
        defaults.set((defaults.stringArray(forKey: "accountFolders") ?? []).filter { $0 != account.folder.path }, forKey: "accountFolders")
        defaults.set((defaults.stringArray(forKey: "removedAccountFolders") ?? []) + [account.folder.path], forKey: "removedAccountFolders")
        reloadAccounts()
    }

    func reloadAccounts() {
        accounts = Self.discoverAccounts()
        releaseUnfollowedApprovals()
        // Queue a new scan even if the scan of the previous account list is still running.
        refresh(usage: true)
    }

    /// Adds what the session logs gained since the last read: once a minute, or sooner when the menu opens.
    /// The first read covers five weeks of logs and takes a few seconds on a background queue.
    func refreshHistory(soon: Bool = false) {
        #if DEBUG
        if DebugSupport.usesFixture {
            if defaults.bool(forKey: "historyEnabled") { history = DebugSupport.sampleHistory() }
            return
        }
        #endif
        guard defaults.bool(forKey: "historyEnabled"), !isReadingHistory,
              Date().timeIntervalSince(historyReadAt) >= (soon ? 5 : 60) else { return }
        isReadingHistory = true
        let history = usageHistory
        let ledger = quotaLedger
        let accounts = self.accounts
        let readings = quotaReadings
        quotaReadings = []
        historyQueue.async { [weak self] in
            let now = Date()
            // The first run also reads the times of use that earlier reads counted, so the current windows can be split.
            let backfill = ledger.needsBackfill ? now.addingTimeInterval(-8 * 86_400) : nil
            let update = history.update(accounts: accounts, now: now, events: true, eventsSince: backfill)
            let summary = UsageSummary(records: update.records, sessions: update.sessions)
            let quota = ledger.update(events: update.events, readings: readings, readAt: now, coverage: backfill)
            DispatchQueue.main.async {
                if let self, self.defaults.bool(forKey: "historyEnabled") {
                    self.history = summary
                    self.quota = quota
                    self.alerts.heavySessions(quota, sessions: self.sessions, styles: self.sessionStyles,
                                              mode: self.alertMode, snoozed: self.snoozedUntil != nil)
                    self.alerts.drain(quota, mode: self.alertMode, snoozed: self.snoozedUntil != nil)
                    self.alerts.dailyBudget(quota, mode: self.alertMode, snoozed: self.snoozedUntil != nil)
                }
                self?.historyReadAt = Date()
                self?.isReadingHistory = false
            }
        }
    }

    /// Pausing history stops future reads and hides totals, while retaining the local archive for later.
    func setHistoryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "historyEnabled")
        history = nil
        quota = nil
        quotaReadings = []
        historyReadAt = .distantPast
        if enabled { refreshHistory(soon: true) }
    }

    // MARK: Approvals

    /// Starts or stops taking permission prompts from Claude Code and Codex. When stopped, the bridge finds no socket
    /// and leaves every prompt to the terminal at once, and Warden leaves Codex's daemon.
    func setAnswersFromWarden(_ enabled: Bool) {
        defaults.set(enabled, forKey: "answerFromWarden")
        if enabled {
            approvalServer.start()
            connectCodex()
        } else {
            approvalServer.stop()
            codexClients.values.forEach { $0.disconnect() }
            codexClients = [:]
            codexWaits = [:]
            for approval in approvals { alerts.withdraw(approval.request.id) }
            approvals = []
        }
    }

    /// Joins the shared daemon of each Codex account whose daemon runs, and again after it restarts.
    private func connectCodex() {
        guard defaults.bool(forKey: "answerFromWarden") else { return }
        #if DEBUG
        if DebugSupport.usesFixture { return }
        #endif
        let current = Set(accounts.filter { $0.provider == .codex }.map(\.id))
        for (id, client) in codexClients where !current.contains(id) {
            client.disconnect()
            codexClients[id] = nil
            codexWaits[id] = nil
        }
        for account in accounts where account.provider == .codex {
            if codexClients[account.id] == nil {
                let client = CodexDaemonClient(account: account)
                client.onRequest = { [weak self] request in MainActor.assumeIsolated { self?.receive(request) } }
                client.onGone = { [weak self] id in MainActor.assumeIsolated { self?.forget(id) } }
                client.onWaits = { [weak self] waits in
                    MainActor.assumeIsolated {
                        self?.codexWaits[account.id] = waits
                        self?.refresh()
                    }
                }
                codexClients[account.id] = client
            }
            codexClients[account.id]?.connectIfNeeded()
        }
    }

    func approval(for session: AgentSession) -> PendingApproval? {
        approvals.last { $0.request.sessionID == session.id }
    }

    /// Sends an answer to Claude Code or Codex. A choice picks an option of the first question.
    /// Returns whether the prompt still waited for an answer.
    @discardableResult
    func answer(_ id: String, _ choice: ApprovalChoice) -> Bool {
        guard let approval = approvals.first(where: { $0.request.id == id }),
              let reply = Self.reply(choice, to: approval.request) else { return false }
        if approval.request.provider == .codex {
            guard codexClients.values.contains(where: { $0.answer(id, with: reply) }) else { return false }
        } else {
            approvalServer.answer(id, with: reply)
        }
        activity.answeredInWarden(session: approval.request.sessionID)
        forget(id)
        return true
    }

    /// The answer a choice gives to a prompt: an option of its first question, or allow and deny.
    nonisolated static func reply(_ choice: ApprovalChoice, to request: ApprovalRequest) -> ApprovalAnswer? {
        switch choice {
        case .allow: return .allow
        case .allowForSession: return .allowForSession
        case .allowAlways: return .allowAlways
        case .deny: return .deny
        case .option(let index):
            guard let question = request.questions.first, question.options.indices.contains(index) else { return nil }
            return ApprovalAnswer(behavior: "allow", answers: [question.text: question.options[index]])
        }
    }

    private func receive(_ request: ApprovalRequest) {
        guard Accounts.follows(request.provider, account: request.account, in: accounts) else {
            if request.provider == .claude { approvalServer.answer(request.id, with: .undecided) }
            return
        }
        guard !approvals.contains(where: { $0.request.id == request.id }) else { return }
        approvals.append(PendingApproval(request: request, receivedAt: Date()))
        publishToPhone()
        // The bridge recorded the prompt before asking, and Codex's daemon says the thread waits, so a scan now lists
        // the session under Needs You.
        refresh()
        let session = sessions.first { $0.id == request.sessionID }
        alerts.approval(request, session: session, style: sessionStyles[request.sessionID] ?? .general(for: request.provider),
                        mode: alertMode, snoozed: snoozedUntil != nil)
    }

    private func forget(_ id: String) {
        approvals.removeAll { $0.request.id == id }
        alerts.withdraw(id)
        publishToPhone()
    }

    private func releaseUnfollowedApprovals() {
        for approval in approvals where !Accounts.follows(approval.request.provider, account: approval.request.account, in: accounts) {
            if approval.request.provider == .claude { approvalServer.answer(approval.request.id, with: .undecided) }
            forget(approval.request.id)
        }
    }

    // MARK: Phone and widgets

    private func updateWidgets() {
        widgets.update(WidgetFeed.snapshot(attention: attentionQueue, working: sessions.filter { $0.phase == .working },
                                           windows: windows, tool: { [weak self] session in
            self?.approval(for: session)?.request.tool ?? session.detail
        }))
    }

    private func startPhone() {
        phone.answer = { [weak self] id, choice in self?.answer(fromPhone: id, choice: choice) ?? false }
        phone.currentState = { [weak self] in self.map { PhoneState.make(store: $0, mac: PhoneCompanion.macName) } }
        // A script that tells the phone can link to the page, once a phone is paired.
        automations.environment = { [weak self] in
            guard let phone = self?.phone, phone.enabled, phone.pairedCount > 0, let url = phone.url else { return [:] }
            return ["WARDEN_PHONE_URL": url.absoluteString]
        }
        phone.onAvailabilityChange = { [weak self] in self?.publishToPhone() }
        phone.start()
        publishToPhone()
    }

    /// Sends what the menu shows to paired phones, when the companion runs.
    private func publishToPhone() {
        let state = phone.enabled ? PhoneState.make(store: self, mac: PhoneCompanion.macName) : nil
        let waiting = phone.pairedCount > 0 && (state?.needsYou.contains { !($0.prompt?.choices.isEmpty ?? true) } ?? false)
        keepAwake.update(working: activeCount > 0,
                         guardedJobs: !TrainGuard(home: trainGuard.home).workingJobs().isEmpty,
                         phoneAwaitingReply: waiting, observedAt: scannedAt ?? .distantPast)
        if phone.isServing, let state { phone.publish(state) }
    }

    /// An answer tapped on a paired phone, by the page's name for it. False when the prompt no longer waits.
    private func answer(fromPhone id: String, choice: String) -> Bool {
        let parsed: ApprovalChoice
        switch choice {
        case "allow": parsed = .allow
        case "allowForSession": parsed = .allowForSession
        case "allowAlways": parsed = .allowAlways
        case "deny": parsed = .deny
        default:
            guard choice.hasPrefix("option:"), let index = Int(choice.dropFirst("option:".count)) else { return false }
            parsed = .option(index)
        }
        return answer(id, parsed)
    }

    /// Releases prompts answered in the terminal: the session's log moved past the prompt, or the session ended.
    /// Codex's daemon says itself when a prompt was answered.
    private func releaseAnsweredApprovals() {
        for approval in approvals where approval.request.provider == .claude {
            guard let session = sessions.first(where: { $0.id == approval.request.sessionID }) else { continue }
            let waiting = session.phase == .needsAttention && (session.attention == .permission || session.attention == .choice)
            if session.ended || (!waiting && session.updatedAt > approval.receivedAt.addingTimeInterval(1)) {
                approvalServer.answer(approval.request.id, with: .undecided)
                forget(approval.request.id)
            }
        }
    }

    /// Saves the history's read positions and closes the prompt socket before Warden quits.
    func shutdown() {
        keepAwake.shutdown()
        #if DEBUG
        if DebugSupport.usesFixture { return }
        #endif
        let history = usageHistory
        let ledger = quotaLedger
        let log = activityLog
        let open = activity.closeAll(now: Date())
        historyQueue.sync {
            history.flush()
            ledger.flush()
            log.add(open)
            log.flush()
        }
        approvalServer.stop()
        codexClients.values.forEach { $0.disconnect() }
    }

    /// The hook events the installed Claude Code knows.
    nonisolated static func claudeEvents() -> [String] {
        ClaudeInstaller.hookEvents(forVersion: AccountUsage.claudeVersion())
    }

    /// Asks before changing Claude Code's settings, and says exactly what changes. Returns true when connected.
    /// Without an account, the default one in `~/.claude`.
    @discardableResult
    func confirmAndConnectClaude(_ account: AgentAccount? = nil) -> Bool {
        let events = Self.claudeEvents()
        let state = account.map { otherConnections[$0.id] ?? .notConnected } ?? claudeConnection
        let settings = account.map { (Self.settings(of: $0).path as NSString).abbreviatingWithTildeInPath } ?? "~/.claude/settings.json"
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = state == .needsRepair ? "Repair Warden's Claude Code connection?" : "Connect Claude Code to Warden?"
        alert.informativeText = """
        Warden adds these to \(settings):
        • a status line command, which keeps running your current status line and prints what it prints;
        • hooks for \(ListFormatter.localizedString(byJoining: events)).

        Everything else in the file stays as it is. The original file is saved once as settings.warden-backup.json, \
        and the state before each change as settings.warden-previous.json. Disconnect in Settings removes the hooks \
        and restores your status line.
        """
        alert.addButton(withTitle: state == .needsRepair ? "Repair" : "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let connected = connectClaude(account)
        if !connected, let message = connectionMessage {
            let failure = NSAlert()
            failure.messageText = "Warden could not connect Claude Code"
            failure.informativeText = message
            failure.runModal()
        }
        return connected
    }

    /// Connects an account's Claude Code, or the default one, and returns whether it is now connected.
    @discardableResult
    func connectClaude(_ account: AgentAccount? = nil) -> Bool {
        let settings = account.map(Self.settings) ?? ClaudeInstaller.defaultSettingsURL
        do {
            let events = Self.claudeEvents()
            try ClaudeInstaller.install(helper: helperURL, settingsURL: settings, events: events)
            let state = ClaudeInstaller.status(helper: helperURL, settingsURL: settings, events: events)
            if let account { otherConnections[account.id] = state } else { claudeConnection = state }
            connectionMessage = "Claude Code is connected. Open sessions report on their next event."
            refresh()
            return state == .connected
        } catch {
            connectionMessage = error.localizedDescription
            return false
        }
    }

    func disconnectClaude(_ account: AgentAccount? = nil) {
        let settings = account.map(Self.settings) ?? ClaudeInstaller.defaultSettingsURL
        do {
            try ClaudeInstaller.uninstall(settingsURL: settings)
            let state = ClaudeInstaller.status(helper: helperURL, settingsURL: settings, events: Self.claudeEvents())
            if let account { otherConnections[account.id] = state } else { claudeConnection = state }
            connectionMessage = "Warden's hooks were removed. Your previous status line is back."
        } catch {
            connectionMessage = error.localizedDescription
        }
    }

    func open(sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        SessionNavigator.open(session, processes: processes, accounts: accounts)
    }

    /// The session's prompt cache, when a reply after it expires would cost a point or more of the 5-hour limit, or,
    /// before the limit has a rate, when its context is large.
    func cacheNote(for session: AgentSession) -> CacheNote? {
        guard let cache = PromptCache(session) else { return nil }
        let id = UsageWindow.id(.claude, "five_hour", account: session.account)
        let points = cache.penalty.flatMap { quota?.points(forAPIValue: $0, window: id) }
        guard PromptCache.matters(tokens: cache.tokens, points: points) else { return nil }
        let name = windows.first { $0.id == id }?.name ?? "Claude\(session.account.map { " (\($0))" } ?? "") 5h"
        return CacheNote(cache: cache, points: points, window: name)
    }

    /// Styles chosen for single sessions. A session without one follows its agent's general style.
    var sessionStyles: [String: AlertStyle] {
        (defaults.dictionary(forKey: "sessionAlertStyles") as? [String: String] ?? [:]).compactMapValues(AlertStyle.init)
    }

    func setStyle(_ style: AlertStyle?, forSession id: String) {
        var styles = defaults.dictionary(forKey: "sessionAlertStyles") as? [String: String] ?? [:]
        styles[id] = style?.rawValue
        defaults.set(styles, forKey: "sessionAlertStyles")
        objectWillChange.send()
    }

    func isMuted(_ session: AgentSession) -> Bool { sessionStyles[session.id] == .muted }

    func toggleMute(sessionID: String) {
        setStyle(sessionStyles[sessionID] == .muted ? nil : .muted, forSession: sessionID)
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        defer { refreshLoginStatus() }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            throw error
        }
    }

    func refreshLoginStatus() { loginStatus = SMAppService.mainApp.status }

    // Registration awaiting approval is still enabled by the user and must be removable with the toggle.
    var launchesAtLogin: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    /// Turns session states into spans of work and waiting. Only the spans that ended reach the disk.
    private func recordActivity(now: Date) {
        guard defaults.bool(forKey: "activityEnabled") else {
            if !activity.open.isEmpty { activity = ActivityRecorder() }
            return
        }
        let closed = activity.record(sessions, now: now)
        guard !closed.isEmpty else { return }
        let log = activityLog
        historyQueue.async { [weak self] in
            log.add(closed, now: now)
            let spans = log.all
            DispatchQueue.main.async { self?.activitySpans = spans }
        }
    }

    /// Notices when you step away and come back, and then says what happened in between.
    private func checkPresence(now: Date) {
        guard hasBaseline, defaults.bool(forKey: "awaySummary") else {
            presence = PresenceTracker()
            return
        }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0) ?? .keyDown)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let wasHere = presence.awaySince == nil
        let back = presence.update(idle: idle, locked: locked, now: now)
        if wasHere, presence.awaySince != nil { windowsWhenAway = windows }
        guard let back, back.duration >= max(5, defaults.double(forKey: "awayMinutes")) * 60 else { return }
        let digest = AwayDigest(away: back, sessions: sessions, spans: activitySpans + activity.open.values,
                                before: windowsWhenAway, windows: windows, now: now)
        guard !digest.isEmpty else { return }
        awayDigest = digest
        alerts.away(digest, mode: alertMode, snoozed: snoozedUntil != nil)
    }

    func dismissAwayDigest() { awayDigest = nil }

    /// Asks a provider's public status page, at most every five minutes, while one of its sessions has stopped on an
    /// error that may be the provider's, when Settings allow it. Nothing about you or your sessions is sent.
    private func checkProviderStatus(now: Date) {
        guard defaults.bool(forKey: "checkProviderStatus") else {
            if !incidents.isEmpty { incidents = [:] }
            return
        }
        for provider in AgentProvider.allCases {
            let failing = sessions.contains {
                $0.provider == provider && $0.attention == .failure && ProviderStatus.mayBeProvider($0.detail)
            }
            guard failing else {
                if incidents[provider] != nil { incidents[provider] = nil }
                continue
            }
            guard now.timeIntervalSince(statusCheckedAt[provider] ?? .distantPast) >= 300 else { continue }
            statusCheckedAt[provider] = now
            var request = URLRequest(url: ProviderStatus.summaryURL(provider), cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 10)
            request.httpShouldHandleCookies = false
            Self.statusSession.dataTask(with: request) { [weak self] data, _, _ in
                let incident = data.flatMap { ProviderStatus.incident(from: $0, provider: provider, checkedAt: Date()) }
                DispatchQueue.main.async { self?.incidents[provider] = incident }
            }.resume()
        }
    }

    private func apply(_ result: ScanResult, connections: [String: ClaudeConnection]) {
        #if DEBUG
        let result = DebugSupport.fixture(result)
        #endif
        isScanning = false
        let waits = codexWaits.values.reduce(into: [String: CodexApprovals.Wait]()) { $0.merge($1) { first, _ in first } }
        let followed = result.sessions.filter { Accounts.follows($0.provider, account: $0.account, in: accounts) }
        sessions = CodexApprovals.applying(waits, to: followed)
        windows = result.windows.filter { Accounts.follows($0.provider, account: $0.account, in: accounts) }
        releaseUnfollowedApprovals()
        paceTracker.record(windows, now: result.scannedAt)
        if defaults.bool(forKey: "historyEnabled") {
            quotaReadings += windows.filter { previousWindows[$0.id]?.observedAt != $0.observedAt }
            // The first readings reach the quota ledger without waiting for the minute's history read.
            if !quotaReadings.isEmpty, quota?.windows.isEmpty ?? true { refreshHistory(soon: true) }
        }
        recordActivity(now: result.scannedAt)
        checkPresence(now: result.scannedAt)
        checkProviderStatus(now: result.scannedAt)
        plans = result.plans.filter { Accounts.follows($0.provider, account: $0.account, in: accounts) }
        processes = result.processes
        nativeApps = result.nativeApps
        scannedAt = result.scannedAt
        let primary = accounts.first { $0.provider == .claude && $0.name == nil }
        let connection = primary.flatMap { connections[$0.id] } ?? .notConnected
        if claudeConnection != connection { claudeConnection = connection }
        let others = connections.filter { $0.key != primary?.id }
        if otherConnections != others { otherConnections = others }
        if hasBaseline {
            alerts.process(sessions: sessions, previous: previousSessions,
                           windows: windows, previousWindows: previousWindows,
                           styles: sessionStyles, mode: alertMode, snoozed: snoozedUntil != nil)
        }
        releaseAnsweredApprovals()
        writeState()
        publishToPhone()
        updateWidgets()
        previousSessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        previousWindows = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        hasBaseline = true
        if usageRequested {
            usageRequested = false
            refresh(usage: true)
        }
    }
}

@MainActor
private final class AlertEngine: NSObject, UNUserNotificationCenterDelegate {
    private enum Kind { case attention, finish, context, quota }

    private let center = UNUserNotificationCenter.current()
    private let sounds: SoundLibrary
    private var alertedKeys = Set<String>()
    /// Alerts already given to automation scripts, which get them even while alerts stay silent.
    private var postedKeys = Set<String>()
    /// Whether alerts are snoozed, as of the latest call that checks for new ones.
    private var snoozed = false
    /// Receives each alert for the automation scripts.
    var onEvent: ((AutomationEvent) -> Void)?
    /// Opens the menu, for a notification that concerns no single session.
    var onOpenMenu: (() -> Void)?
    /// Interrupted sessions not alerted yet, with the time of the interruption.
    private var interruptions: [String: Date] = [:]
    /// Sessions alerted from a prompt Warden can answer, so the scan that sees the same prompt stays quiet.
    private var promptedAt: [String: Date] = [:]
    private var categories: [UNNotificationCategory] = []
    var onOpen: ((String) -> Void)?
    var onMute: ((String) -> Void)?
    var onAnswer: ((String, ApprovalChoice) -> Void)?
    /// Whether you already look at a session, whose alerts then stay quiet.
    var isInFront: ((AgentSession) -> Bool)?
    /// A session's prompt cache, when letting it expire costs enough to mention.
    var cacheNote: ((AgentSession) -> CacheNote?)?

    init(sounds: SoundLibrary) {
        self.sounds = sounds
        super.init()
    }

    private let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
    private let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
    private let allowSession = UNNotificationAction(identifier: "allowSession", title: "Allow for This Session", options: [])

    func start() {
        center.delegate = self
        let (allow, deny, session) = (self.allow, self.deny, self.allowSession)
        categories = [
            UNNotificationCategory(identifier: "session", actions: [
                UNNotificationAction(identifier: "show", title: "Show", options: [.foreground]),
                UNNotificationAction(identifier: "mute", title: "Mute Session", options: [])
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "approval", actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: "approval-session", actions: [allow, session, deny], intentIdentifiers: [])
        ]
        center.setNotificationCategories(Set(categories))
        // Setup requests permission after explaining what the alerts are for.
        // Existing macOS grants continue to work without asking again.
    }

    /// Alerts at once for a prompt Warden can answer, with its answers as notification actions.
    func approval(_ request: ApprovalRequest, session: AgentSession?, style: AlertStyle, mode: AlertMode, snoozed: Bool) {
        self.snoozed = snoozed
        guard UserDefaults.standard.bool(forKey: "alertAttention") else { return }
        promptedAt[request.sessionID] = Date()
        // The prompt is on screen in the terminal you look at; the menu still offers the answers.
        if let session, isInFront?(session) == true { return }
        // A session's first prompt can arrive before any scan has listed it; its folder names it then.
        let folder = request.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let name = session.map { session in session.title.map { "\(session.project): \($0)" } ?? session.project }
            ?? folder ?? (request.provider == .codex ? "Codex" : "Claude Code")
        let category: String
        let body: String
        var script: String?
        let line: VoiceLine
        if request.isQuestion {
            line = .question
            body = request.questions.first?.text ?? "Waiting for your answer"
            // A single choice from a few options can be answered from the notification.
            if let question = request.questions.first, request.questions.count == 1, !question.multiSelect,
               (1...4).contains(question.options.count) {
                category = "question-\(request.id)"
                let actions = question.options.enumerated().map { index, label in
                    UNNotificationAction(identifier: "option-\(index)", title: label, options: [])
                }
                categories.append(UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: []))
                center.setNotificationCategories(Set(categories))
            } else {
                category = "session"
            }
        } else {
            line = .approval
            body = ["Allow \(request.tool)?", request.summary].compactMap { $0 }.joined(separator: " ")
            // Scripts get the tool, never the command or file, which can hold secrets and may leave the Mac.
            script = Approval.wants(tool: request.tool, provider: request.provider)
            if let rule = request.alwaysRule {
                // The button names the rule Claude Code keeps, which can be broader than this one command.
                category = "approval-always-\(request.id)"
                let always = UNNotificationAction(identifier: "allowAlways", title: "Always Allow \(String(rule.prefix(48)))", options: [])
                categories.append(UNNotificationCategory(identifier: category, actions: [allow] + (request.canAllowForSession ? [allowSession] : []) + [always, deny],
                                                         intentIdentifiers: []))
                center.setNotificationCategories(Set(categories))
            } else {
                category = request.canAllowForSession ? "approval-session" : "approval"
            }
        }
        send(style: style, kind: .attention, mode: mode, line: line, title: "\(request.provider.rawValue) · \(name)", body: body, script: script,
             session: request.sessionID, key: "approval-\(request.id)", category: category, approval: request.id, about: session)
    }

    /// Removes the notification of a prompt that was answered or went away, so no stale card stays behind.
    func withdraw(_ approval: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(approval)"])
        let own: Set = ["question-\(approval)", "approval-always-\(approval)"]
        if categories.contains(where: { own.contains($0.identifier) }) {
            categories.removeAll { own.contains($0.identifier) }
            center.setNotificationCategories(Set(categories))
        }
    }

    /// `styles` holds the sessions that do not follow their agent's general style.
    func process(sessions: [AgentSession], previous: [String: AgentSession],
                 windows: [UsageWindow], previousWindows: [String: UsageWindow],
                 styles: [String: AlertStyle], mode: AlertMode, snoozed: Bool) {
        self.snoozed = snoozed
        let defaults = UserDefaults.standard
        let threshold = defaults.double(forKey: "contextThreshold")
        let now = Date()
        func style(_ session: AgentSession) -> AlertStyle { styles[session.id] ?? .general(for: session.provider) }
        for session in sessions where style(session) != .muted {
            guard let old = previous[session.id] else { continue }
            if session.phase == .needsAttention && old.phase != .needsAttention && defaults.bool(forKey: "alertAttention") {
                if session.attention == .permission || session.attention == .choice,
                   let prompted = promptedAt[session.id], now.timeIntervalSince(prompted) < 120 {
                    // Already alerted when the prompt reached Warden.
                } else if session.attention == .interrupted {
                    interruptions[session.id] = session.updatedAt
                } else {
                    alert(session, style: style(session), kind: .attention, mode: mode,
                          key: "attention-\(session.id)-\(Int(session.updatedAt.timeIntervalSince1970))")
                }
            } else if session.phase == .finished && old.phase == .working && defaults.bool(forKey: "alertFinish") {
                alert(session, style: style(session), kind: .finish, mode: mode,
                      key: "finish-\(session.id)-\(Int(session.updatedAt.timeIntervalSince1970))")
            }
            if let resumes = session.resumesAt, old.resumesAt == nil, defaults.bool(forKey: "alertQuota") {
                // Claude waits for the limit and continues by itself, so nothing is asked of you.
                send(style: style(session), kind: .quota, mode: mode, line: .limitReached,
                     title: "\(session.provider.rawValue) · \(session.title.map { "\(session.project): \($0)" } ?? session.project)",
                     body: "Reached a usage limit. It continues by itself \(MenuFormat.resetPhrase(resumes)).",
                     session: session.id, key: "resume-\(session.id)-\(UsageWindow.resetKey(resumes))", about: session)
            }
            if defaults.bool(forKey: "alertContext"),
               let value = session.contextPercent, value >= threshold,
               (old.contextPercent ?? 0) < threshold {
                alert(session, style: style(session), kind: .context, mode: mode,
                      body: "\(session.contextEvidence == .inferred ? "About " : "")\(Int(value.rounded()))% of the context window is used. Compact or start a new session before a large prompt.",
                      key: "context-\(session.id)-\(Int(threshold))")
            }
            // An hour-long cache that a waiting session is about to lose: five minutes' notice. A five-minute cache
            // would warn as soon as the session asks, so it shows in the menu only.
            if defaults.bool(forKey: "alertCache"), session.phase == .needsAttention,
               let note = cacheNote?(session), note.cache.minutes >= 60 {
                let left = note.cache.remaining(now: now)
                if left > 0, left <= 300 {
                    alert(session, style: style(session), kind: .context, mode: mode,
                          body: "Reply within \(MenuFormat.remaining(left)) to keep its prompt cache. After that, its \(MenuFormat.tokens(note.cache.tokens))-token context is written to the cache again: \(note.cost).",
                          key: "cache-\(session.id)-\(UsageWindow.resetKey(note.cache.expiresAt))")
                }
            }
        }
        // Esc usually comes right before you redirect the agent, so an interruption alerts only
        // when the session still waits half a minute later.
        for (id, at) in interruptions {
            guard let session = sessions.first(where: { $0.id == id }), session.attention == .interrupted,
                  style(session) != .muted else {
                interruptions[id] = nil
                continue
            }
            guard now.timeIntervalSince(at) >= 30 else { continue }
            interruptions[id] = nil
            alert(session, style: style(session), kind: .attention, mode: mode,
                  key: "attention-\(id)-\(Int(at.timeIntervalSince1970))")
        }
        guard defaults.bool(forKey: "alertQuota") else { return }
        let limitThreshold = defaults.double(forKey: "alertQuotaThreshold")
        for window in windows where window.isCurrent() {
            let name = window.name
            let reset = window.resetsAt.map { " Resets \(MenuFormat.resetPhrase($0))." } ?? ""
            let style = AlertStyle.general(for: window.provider)
            if let old = previousWindows[window.id], old.usedPercent < limitThreshold, window.usedPercent >= limitThreshold {
                let advice = window.usedPercent >= 90 ? "Prefer short tasks for now." : "Keep an eye on long tasks."
                send(style: style, kind: .quota, mode: mode, line: .warning,
                     title: "\(name) limit at \(Int(window.usedPercent.rounded()))%",
                     body: "\(advice)\(reset)\(window.usedPercent >= 90 ? Self.roomElsewhere(than: window, in: windows, now: now) : "")",
                     session: nil, key: "high-\(window.id)-\(UsageWindow.resetKey(window.resetsAt))")
            }
            // The pace since the window opened would use it up before its reset: say so once per window.
            if defaults.bool(forKey: "alertPace"), window.usedPercent < 100, let reset = window.resetsAt,
               let runsOut = window.forecast(now: now)?.exhaustsAt, runsOut > now, runsOut < reset {
                send(style: style, kind: .quota, mode: mode, line: .warning,
                     title: "\(name) on pace to run out",
                     body: "At its pace since the window opened, it runs out \(MenuFormat.moment(runsOut, now: now)), before its reset \(MenuFormat.resetPhrase(reset, now: now)). An estimate from \(Int(window.usedPercent.rounded()))% used so far.",
                     session: nil, key: "pace-\(window.id)-\(UsageWindow.resetKey(reset))")
            }
            if let resetDate = window.resetsAt, resetDate.timeIntervalSinceNow > 0, resetDate.timeIntervalSinceNow < 1800,
               window.usedPercent >= 80 {
                send(style: style, kind: .quota, mode: mode, line: .warning, title: "\(name) window resets soon",
                     body: "\(Int(window.usedPercent.rounded()))% used. Resets \(MenuFormat.resetPhrase(resetDate)).", session: nil,
                     key: "upcoming-\(window.id)-\(UsageWindow.resetKey(resetDate))")
            }
            // A reset moved within the same window, as when a provider resets everyone's limits and the week starts
            // over, changes how the rest of the window can be used. A jump in the percentage is another account's
            // window instead.
            if let old = previousWindows[window.id], window.observedAt > old.observedAt,
               let oldReset = old.resetsAt, let newReset = window.resetsAt, oldReset > now, newReset > now,
               abs(newReset.timeIntervalSince(oldReset)) >= 3600, abs(window.usedPercent - old.usedPercent) <= 5 {
                send(style: style, kind: .quota, mode: mode, line: .warning, title: "\(name) reset moved",
                     body: "It now resets \(MenuFormat.resetPhrase(newReset, now: now)), not \(MenuFormat.resetPhrase(oldReset, now: now)). \(Int(window.usedPercent.rounded()))% is used.",
                     session: nil, key: "moved-\(window.id)-\(UsageWindow.resetKey(newReset))")
            }
            // A week's limit does not carry over: a day before it resets with half or more left, say so once.
            if defaults.bool(forKey: "alertUnused"), PlanPrice.applies(to: window), window.usedPercent <= 50,
               let reset = window.resetsAt, reset > now, reset.timeIntervalSince(now) <= 86_400 {
                let unused = 100 - window.usedPercent
                let money = PlanPrice.perPoint(window, prices: MenuFormat.planPrices).map { ", about \(MenuFormat.cost(unused * $0)) of your plan" } ?? ""
                send(style: style, kind: .quota, mode: mode, line: .warning,
                     title: "\(name): \(Int(unused.rounded()))% unused",
                     body: "The week resets \(MenuFormat.resetPhrase(reset, now: now)) and unused quota does not carry over\(money). A good moment for work you have put off.",
                     session: nil, key: "unused-\(window.id)-\(UsageWindow.resetKey(reset))")
            }
            // Extra usage is billed beyond the plan; the first use of it this month is worth knowing at once.
            if window.provider == .claude, window.id.hasSuffix("-extra_usage"), window.usedPercent > 0,
               (previousWindows[window.id]?.usedPercent ?? 0) == 0 {
                send(style: style, kind: .quota, mode: mode, line: .warning, title: "\(name): extra usage recorded",
                     body: "\(Int(window.usedPercent.rounded()))% of your extra usage limit is used. This use is billed beyond your plan.",
                     session: nil, key: "extra-\(window.id)-\(Int(window.observedAt.timeIntervalSince1970 / 86_400))")
            }
            if let old = previousWindows[window.id], window.confirmsRecovery(from: old, now: now) {
                // Sessions this limit stopped can go on. Claude continues by itself; a Codex turn waits for you.
                let stopped = sessions.filter {
                    $0.provider == window.provider && $0.account == window.account && !$0.ended
                        && ($0.attention == .failure || ($0.phase == .idle && $0.attention == nil)) && MenuFormat.isLimit($0.detail)
                }
                let names = stopped.prefix(3).map { $0.title.map { "“\(String($0.prefix(40)))”" } ?? $0.project }
                let waiting = stopped.isEmpty ? "" : " \(stopped.count == 1 ? "A session it stopped can continue" : "\(stopped.count) sessions it stopped can continue"): \(ListFormatter.localizedString(byJoining: names))."
                send(style: style, kind: .quota, mode: mode, line: .warning,
                     title: "\(name): quota available again",
                     body: "A new reading after the reported reset shows \(Int(window.usedPercent.rounded()))% used in this window.\(waiting) Other account limits may still apply.",
                     session: stopped.first?.id, key: "restored-\(window.id)-\(UsageWindow.resetKey(old.resetsAt))",
                     about: stopped.first)
            } else if let old = previousWindows[window.id], window.observedAt > old.observedAt,
                      old.usedPercent - window.usedPercent >= 30, !old.hasReset(now: window.observedAt) {
                // A drop before the reported reset is unannounced, unlike the reset itself.
                send(style: style, kind: .quota, mode: mode, line: .warning, title: "\(name) usage dropped",
                     body: "\(Int(old.usedPercent.rounded()))% → \(Int(window.usedPercent.rounded()))% used. This is an observed change, not an announced reset.",
                     session: nil, key: "reset-\(window.id)-\(Int(window.observedAt.timeIntervalSince1970))")
            }
        }
    }

    /// Room left on another agent's limits, for a hint when one runs low: " Codex has 47% of its 7d limit left."
    static func roomElsewhere(than window: UsageWindow, in windows: [UsageWindow], now: Date) -> String {
        let others = windows.filter {
            $0.provider != window.provider && $0.scope == nil && $0.isCurrent(now: now) && QuotaLedger.isQuota($0)
        }
        // Each other account is as free as its fullest shared limit.
        let accounts = Dictionary(grouping: others) { (window: UsageWindow) in "\(window.provider.rawValue)/\(window.account ?? "")" }
        let tightest = accounts.values.compactMap { group in group.max { $0.usedPercent < $1.usedPercent } }
        guard let best = tightest.min(by: { $0.usedPercent < $1.usedPercent }), best.usedPercent <= 80 else { return "" }
        let owner = best.provider.rawValue + (best.account.map { " (\($0))" } ?? "")
        return " \(owner) has \(Int((100 - best.usedPercent).rounded()))% of its \(best.shortLabel) limit left."
    }

    /// A silent notification when you come back: what finished, what waits for you, and how the limits moved.
    func away(_ digest: AwayDigest, mode: AlertMode, snoozed: Bool) {
        self.snoozed = snoozed
        send(style: .off, kind: digest.firstWaiting == nil ? .finish : .attention, mode: mode, line: .needsYou,
             title: "While you were away · \(AwayDigest.duration(digest.away.duration))",
             body: digest.lines.prefix(4).joined(separator: "\n"), session: digest.firstWaiting,
             key: "away-\(Int(digest.away.end.timeIntervalSince1970))")
    }

    /// Alerts once per window when a limit drains much faster than past windows did for use of the same API value,
    /// once enough of this window and several past ones were split among priced use.
    func drain(_ quota: QuotaSummary, mode: AlertMode, snoozed: Bool) {
        let defaults = UserDefaults.standard
        self.snoozed = snoozed
        guard defaults.bool(forKey: "alertQuota"), defaults.bool(forKey: "alertPace") else { return }
        for (id, period) in quota.current where period.pricedPoints >= 10 {
            let past = quota.finished.filter { $0.window == id }.compactMap(\.dollarsPerPoint)
            guard past.count >= 3, let window = quota.windows[id], window.isCurrent(),
                  let rate = quota.exchange(window: id).current, let typical = quota.exchange(window: id).typical,
                  rate > 0, typical / rate >= 1.8 else { continue }
            send(style: AlertStyle.general(for: window.provider), kind: .quota, mode: mode, line: .warning,
                 title: "\(window.name) drains faster than usual",
                 body: "For use of the same value at API prices, this window fills about \((typical / rate).formatted(.number.precision(.fractionLength(1))))× faster than your past \(past.count) windows. An estimate from the rises Warden split; see History → Limits.",
                 session: nil, key: "drain-\(id)-\(UsageWindow.resetKey(period.resetsAt))")
        }
    }

    /// Alerts once a day when the day has taken more of a weekly limit than the share you set, from its split rises.
    func dailyBudget(_ quota: QuotaSummary, mode: AlertMode, snoozed: Bool) {
        self.snoozed = snoozed
        let defaults = UserDefaults.standard
        let budget = defaults.double(forKey: "dailyBudget")
        guard budget > 0, defaults.bool(forKey: "alertQuota") else { return }
        let day = UsageLedger.dayString(Date())
        for window in quota.windows.values where PlanPrice.applies(to: window) {
            let today = quota.charges.filter { $0.window == window.id && $0.day == day }.reduce(0) { $0 + $1.points }
            guard today >= budget else { continue }
            let left = window.isCurrent() ? " \(Int(max(0, 100 - window.usedPercent).rounded()))% of the week is left\(window.resetsAt.map { ", until \(MenuFormat.resetPhrase($0))" } ?? "")." : ""
            send(style: AlertStyle.general(for: window.provider), kind: .quota, mode: mode, line: .warning,
                 title: "\(window.name): today's share passed \(MenuFormat.points(budget))",
                 body: "Today took about \(MenuFormat.points(today)) of the week, more than the daily share you set.\(left) Estimated from the limit's rises.",
                 session: nil, key: "budget-\(window.id)-\(day)")
        }
    }

    /// Alerts once when one session takes a large share of a limit: a third of a short window, a tenth of a week.
    func heavySessions(_ quota: QuotaSummary, sessions: [AgentSession], styles: [String: AlertStyle], mode: AlertMode, snoozed: Bool) {
        self.snoozed = snoozed
        guard UserDefaults.standard.bool(forKey: "alertQuota"), UserDefaults.standard.bool(forKey: "alertHeavySession") else { return }
        for (id, period) in quota.current {
            guard let window = quota.windows[id], let minutes = window.durationMinutes else { continue }
            let threshold: Double = minutes <= 1440 ? 30 : 10
            for (sessionID, points) in period.sessions where points >= threshold {
                guard let session = sessions.first(where: { $0.id == sessionID }),
                      (styles[sessionID] ?? .general(for: session.provider)) != .muted else { continue }
                let share = Int(points.rounded())
                // Claude Code counts the requests that had to write the context to the cache again, a common cause.
                var cause = ""
                if let report = session.statusCache, let misses = report.misses, misses > 0, let tokens = report.missTokens, tokens >= 100_000 {
                    cause = " Claude Code counted \(misses == 1 ? "1 cache miss" : "\(misses) cache misses") that wrote \(MenuFormat.tokens(tokens)) tokens again"
                    cause += report.lastMissCauses.map { " (last: \(ListFormatter.localizedString(byJoining: $0.map(PromptCache.cause))))." } ?? "."
                }
                alert(session, style: styles[sessionID] ?? .general(for: session.provider), kind: .quota, mode: mode,
                      body: "Used about \(share)% of \(window.name) in this window, estimated from limit rises while it worked.\(cause)",
                      key: "heavy-\(id)-\(UsageWindow.resetKey(period.resetsAt))-\(sessionID)")
            }
        }
    }

    /// A session alert. The notification names the agent, folder, and task; the recorded line says what happened.
    private func alert(_ session: AgentSession, style: AlertStyle, kind: Kind, mode: AlertMode,
                       body: String? = nil, key: String) {
        if isInFront?(session) == true { return }
        let line: VoiceLine
        let text: String
        switch (kind, session.attention) {
        case (.finish, _): (line, text) = (.done, "Finished its task")
        case (.context, _), (.quota, _): (line, text) = (.warning, "")
        case (_, .permission): (line, text) = (.approval, session.detail.map { "Waiting for approval to use \($0)" } ?? "Waiting for your approval")
        case (_, .failure):
            // After a reset slept through, Claude Code only waits for Enter: nothing went wrong.
            line = session.detail == "quota_auto_resume_stale" ? .needsYou : MenuFormat.isLimit(session.detail) ? .limitReached : .error
            text = MenuFormat.failure(session.detail)
        case (_, .interrupted): (line, text) = (.waiting, "Interrupted, waiting for you")
        case (_, .choice): (line, text) = (.question, "Waiting for your answer")
        case (_, .question): (line, text) = (.question, "Asked you a question")
        default: (line, text) = (.needsYou, "Needs your attention")
        }
        let title = "\(session.provider.rawValue) · \(session.title.map { "\(session.project): \($0)" } ?? session.project)"
        send(style: style, kind: kind, mode: mode, line: line, title: title, body: body ?? text, session: session.id, key: key,
             about: session)
    }

    /// Delivers an alert once per key. Automation scripts get every alert, including those that snooze, quiet hours,
    /// or Only When Needed keep silent; a muted session gets none.
    private func send(style: AlertStyle, kind: Kind, mode: AlertMode, line: VoiceLine, title: String, body: String, script: String? = nil,
                      session: String?, key: String, category: String = "session", approval: String? = nil,
                      about: AgentSession? = nil) {
        guard style != .muted, !alertedKeys.contains(key) else { return }
        // Alerts about a lasting state, such as a pace or a session's share of a window, would come again after a
        // relaunch while the state lasts; their keys are kept.
        let lasting = ["pace-", "heavy-", "upcoming-", "drain-", "unused-", "budget-", "moved-"].contains(where: key.hasPrefix)
        let defaults = UserDefaults.standard
        let kept = defaults.stringArray(forKey: "alertedOnce") ?? []
        if lasting, kept.contains(key) {
            alertedKeys.insert(key)
            return
        }
        let deliver = !snoozed && !isQuietHours && (mode == .all || kind == .attention)
        if postedKeys.count > 500 { postedKeys.removeAll(keepingCapacity: true) }
        if postedKeys.insert(key).inserted {
            onEvent?(AutomationEvent(event: AutomationEvent.name(forAlert: key), at: Date(), title: title, message: script ?? body,
                                     session: session, agent: about?.provider.rawValue, account: about?.account,
                                     project: about?.cwd, alerted: deliver))
        }
        guard deliver else { return }
        alertedKeys.insert(key)
        if lasting { defaults.set(Array((kept + [key]).suffix(200)), forKey: "alertedOnce") }
        // A microphone in use means a call or a recording, where a spoken line or a chime would be heard by others.
        let onCall = UserDefaults.standard.bool(forKey: "quietDuringCalls") && (style.speaks || style == .chime) && Microphone.isInUse
        if style.notifies {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // With a voice, the recorded line is the sound.
            content.sound = style == .chime && !onCall ? .default : nil
            if let session {
                content.categoryIdentifier = category
                content.threadIdentifier = session
                content.userInfo = ["session": session, "approval": approval ?? ""]
            } else {
                content.userInfo = ["open": "menu"]
            }
            center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
        if style.speaks && !onCall { sounds.play(line) }
        if alertedKeys.count > 500 { alertedKeys.removeAll(keepingCapacity: true) }
    }

    private var isQuietHours: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "quietHours") else { return false }
        let hour = Calendar.current.component(.hour, from: Date())
        let from = defaults.integer(forKey: "quietFrom")
        let until = defaults.integer(forKey: "quietUntil")
        return from <= until ? (hour >= from && hour < until) : (hour >= from || hour < until)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let session = response.notification.request.content.userInfo["session"] as? String
        let approval = response.notification.request.content.userInfo["approval"] as? String ?? ""
        let opensMenu = response.notification.request.content.userInfo["open"] as? String == "menu"
        let action = response.actionIdentifier
        Task { @MainActor in
            if session == nil, opensMenu, action == UNNotificationDefaultActionIdentifier { self.onOpenMenu?() }
            if let session {
                switch action {
                case "mute": self.onMute?(session)
                case "allow": self.onAnswer?(approval, .allow)
                case "allowSession": self.onAnswer?(approval, .allowForSession)
                case "allowAlways": self.onAnswer?(approval, .allowAlways)
                case "deny": self.onAnswer?(approval, .deny)
                case _ where action.hasPrefix("option-"):
                    if let index = Int(action.dropFirst("option-".count)) { self.onAnswer?(approval, .option(index)) }
                case "show", UNNotificationDefaultActionIdentifier: self.onOpen?(session)
                default: break
                }
            }
            completionHandler()
        }
    }
}
