import AppKit
import ServiceManagement
import SwiftUI
import WardenCore

struct WardenSettings: View {
    @ObservedObject var store: WardenStore
    @AppStorage("alertAttention") private var alertAttention = true
    @AppStorage("alertFinish") private var alertFinish = true
    @AppStorage("alertContext") private var alertContext = true
    @AppStorage("alertQuota") private var alertQuota = true
    @AppStorage("alertResetExpiry") private var alertResetExpiry = true
    @AppStorage("alertResetExpiryLeadHours") private var resetExpiryLead = 24.0
    @AppStorage("contextThreshold") private var contextThreshold = 85.0
    @AppStorage("soundCodex") private var soundCodex = "chime"
    @AppStorage("soundClaude") private var soundClaude = "chime"
    @AppStorage("quietHours") private var quietHours = false
    @AppStorage("quietInFront") private var quietInFront = true
    @AppStorage("shortcutOpen") private var shortcutOpen = "off"
    @AppStorage("shortcutJump") private var shortcutJump = "off"
    @AppStorage("quietFrom") private var quietFrom = 22
    @AppStorage("quietUntil") private var quietUntil = 8
    @AppStorage("menuBarUsage") private var menuBarUsage = false
    @AppStorage("menuBarWindow") private var menuBarWindow = "highest"
    @AppStorage("menuBarRemaining") private var menuBarRemaining = false
    @AppStorage("codexAccountUsage") private var codexAccountUsage = true
    @AppStorage("claudeAccountUsage") private var claudeAccountUsage = true
    @AppStorage("answerFromWarden") private var answerFromWarden = true
    @AppStorage("settingsTab") private var tab = "setup"
    @AppStorage("historyEnabled") private var historyEnabled = true
    @AppStorage("showAPIEquivalent") private var showAPIEquivalent = false
    @AppStorage("showWorkPlanner") private var showWorkPlanner = true
    @AppStorage("activityEnabled") private var activityEnabled = true
    @AppStorage("alertQuotaThreshold") private var alertQuotaThreshold = 90.0
    @AppStorage("alertPace") private var alertPace = true
    @AppStorage("alertHeavySession") private var alertHeavySession = true
    @AppStorage("alertCache") private var alertCache = true
    @AppStorage("quietDuringCalls") private var quietDuringCalls = true
    @AppStorage("awaySummary") private var awaySummary = true
    @AppStorage("awayMinutes") private var awayMinutes = 15
    @AppStorage("menuShowsUsage") private var menuShowsUsage = true
    @AppStorage("menuShowsRecent") private var menuShowsRecent = true
    @AppStorage("menuShowsAlerts") private var menuShowsAlerts = true
    @AppStorage("checkProviderStatus") private var checkProviderStatus = false
    @AppStorage("alertUnused") private var alertUnused = false
    @AppStorage("dailyBudget") private var dailyBudget = 0.0
    @State private var accountError: String?

    var body: some View {
        TabView(selection: $tab) {
            AccessSettings(store: store, keepAwake: store.keepAwake)
                .tabItem { Label("Setup", systemImage: "checklist") }
                .tag("setup")
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            SoundSettings(sounds: store.sounds)
                .tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
                .tag("sounds")
            usage
                .tabItem { Label("Usage", systemImage: "chart.bar.xaxis") }
                .tag("usage")
            KeepAwakeSettings(keepAwake: store.keepAwake)
                .tabItem { Label("Power", systemImage: "battery.100percent") }
                .tag("power")
            AutomationSettings(automations: store.automations)
                .tabItem { Label("Automations", systemImage: "bolt") }
                .tag("automations")
            PhoneSettings(phone: store.phone)
                .tabItem { Label("Phone", systemImage: "iphone") }
                .tag("phone")
        }
        .frame(width: 540, height: Self.height)
        .onAppear { store.refreshLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshLoginStatus()
        }
    }

    #if DEBUG
    /// `WARDEN_RENDER_HEIGHT` lets an offscreen render show the whole form, which scrolls in the window.
    static var height: CGFloat { ProcessInfo.processInfo.environment["WARDEN_RENDER_HEIGHT"].flatMap(Double.init).map { CGFloat($0) } ?? 660 }
    #else
    static let height: CGFloat = 660
    #endif

    private var usage: some View {
        Form {
            Section("Reset Reminders") {
                ResetRemindersSettings(reminders: store.resetReminders, accounts: store.accounts, plans: store.plans)
            }
            Section("History") {
                Toggle(isOn: Binding(get: { historyEnabled }, set: { value in
                    historyEnabled = value
                    store.setHistoryEnabled(value)
                })) {
                    SettingLabel("Keep local usage history",
                                 detail: "Read token counts from local logs in the background. Turning this off pauses history collection and hides the report. Previously collected totals stay on this Mac.")
                }
                Toggle(isOn: $showAPIEquivalent) {
                    SettingLabel("Show API price equivalents",
                                 detail: "Optional estimates of the same tokens at standard public API prices. These are not subscription charges or an invoice. Unknown prices stay unavailable.")
                }
                .onChange(of: showAPIEquivalent) { store.objectWillChange.send() }
                Text("Tokens are shown by default, including cached input and models without known prices. History covers this Mac only; it cannot measure the value of your subscription or usage on other devices.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Choose a period, account and project in History, then select a day for its token breakdown. CSV export follows the selection and includes project paths, without prompts or replies. The first scan covers logs changed in 35 days; totals are kept for 90 days.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("History's Limits report splits each rise of a usage limit among the projects whose sessions used tokens before it, so a subscription shows what each project cost in its own currency: points of the 5-hour and weekly limits. It keeps times, percentages, project folders, and session ids.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Plan Prices") {
                ForEach(store.accounts) { account in PlanPriceRow(store: store, account: account) }
                Text("Enter what you pay each month to see History's Limits report in your plan's own money: each point of a weekly limit stands for a hundredth of a week's share of the price, and the points you do not use are value you paid for and left. Claude Pro is listed at $20 a month, and Max plans cost more; check your own bill. Leave a price empty to hide it. Prices stay on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent Activity") {
                Toggle(isOn: $activityEnabled) {
                    SettingLabel("Record agent activity",
                                 detail: "Keep when each session worked and when it waited for you, for History's Activity report: a timeline of the day, how long agents waited, and what for. Only times, states, project folders, and tool names are kept, for 30 days.")
                }
            }
            Section("Work Planner") {
                Toggle(isOn: $showWorkPlanner) {
                    SettingLabel("Show Work Planner in the menu",
                                 detail: "Check a 30, 60, or 120 minute work session against shared and model-specific quotas. Compare different work paces, leave a margin, and inspect the readings behind each estimate. Margins are scenarios, not enforced reservations.")
                }
                .onChange(of: showWorkPlanner) { store.objectWillChange.send() }
                Text("Learning takes at least three readings over ten minutes with a measurable change. Resets and long gaps restart it. Warden uses the readings it already receives and never switches accounts or starts work for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        ScrollViewReader { reader in
            generalForm.onReceive(store.trainGuard.$choosingOverrideEnd) { choosing in
                if choosing { DispatchQueue.main.async { reader.scrollTo("long-jobs", anchor: .top) } }
            }
        }
    }

    private var generalForm: some View {
        Form {
            Section("Sources") {
                LabeledContent {
                    switch store.claudeConnection {
                    case .connected:
                        Button("Disconnect") { store.disconnectClaude() }
                    case .needsRepair:
                        Button("Repair") { store.confirmAndConnectClaude() }
                    case .notConnected:
                        Button("Connect") { store.confirmAndConnectClaude() }
                    }
                } label: {
                    Label {
                        SettingLabel("Claude Code", detail: claudeDescription)
                    } icon: {
                        Image(systemName: store.claudeConnection == .connected ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(store.claudeConnection == .connected ? Color.green : Color.secondary)
                    }
                }
                if let message = store.connectionMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { answerFromWarden }, set: { value in
                    answerFromWarden = value
                    store.setAnswersFromWarden(value)
                })) {
                    SettingLabel("Answer prompts from Warden",
                                 detail: "Allow or deny a tool, or pick an answer to a question, from the menu or the notification. The terminal keeps its prompt, and whichever you answer first counts. Warden never answers on its own.")
                }
                Text("Claude Code needs its connection above. Codex needs approvals on, such as approval_policy = \"on-request\" in its config.toml, and a codex session started in a terminal without -c or --profile, which runs in Codex's shared background server. The VS Code extension and the ChatGPT app run their own server and are not covered, and codex exec never asks.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $claudeAccountUsage) {
                    SettingLabel("Keep Claude limits current",
                                 detail: "Every ten minutes, and when the menu opens, Warden asks Claude Code for your plan's limits, as its /usage command does. Claude Code uses its own sign-in; Warden never reads it.")
                }
                Toggle(isOn: $checkProviderStatus) {
                    SettingLabel("Check the provider's status page when a session fails",
                                 detail: "When a session stops on an error that may come from Anthropic or OpenAI, such as an overloaded service, Warden reads status.claude.com or status.openai.com, at most every five minutes, and names the incident under the session. This check sends nothing about you or your sessions.")
                }
                Label {
                    SettingLabel("Codex", detail: store.sessions.contains(where: { $0.provider == .codex })
                                 ? "Local sessions observed. Reads bounded log tails; context is an estimate."
                                 : "No local sessions observed yet. Start a Codex coding session to check coverage.")
                } icon: {
                    Image(systemName: store.sessions.contains(where: { $0.provider == .codex }) ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $codexAccountUsage) {
                    SettingLabel("Keep Codex limits current",
                                 detail: "Every ten minutes, and when the menu opens, Warden asks the Codex CLI for your account's limits, as its /status command does. Codex uses its own sign-in; Warden never reads it.")
                }
                ForEach(store.accounts.filter { $0.name != nil }) { account in otherAccount(account) }
                Button("Add Account Folder…", action: addAccountFolder)
                if let accountError { Text(accountError).font(.caption).foregroundStyle(.red) }
                Text("Other accounts show up by themselves in folders beside ~/.claude and ~/.codex, such as ~/.claude-work. Add a folder that CLAUDE_CONFIG_DIR or CODEX_HOME names elsewhere. Each account keeps its own sessions, limits, and history.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(store.nativeApps.isEmpty
                     ? "Conversations in the ChatGPT and Claude apps have no local event source, so Warden does not monitor them."
                     : "\(store.nativeApps.joined(separator: " and ")) \(store.nativeApps.count == 1 ? "is" : "are") open. Conversations there have no local event source, so Warden does not monitor them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Long Jobs") {
                TrainGuardSettings(setup: store.trainGuard, accounts: store.accounts)
            }
            .id("long-jobs")
            .onAppear { store.trainGuard.refresh(accounts: store.accounts) }
            Section("Alerts") {
                Toggle(isOn: $alertAttention) {
                    SettingLabel("Questions, approvals, errors, and interruptions",
                                 detail: "An agent asks you a question, needs approval to run a tool, stops on an error, or still waits 30 seconds after you interrupt it.")
                }
                Toggle(isOn: $alertFinish) {
                    SettingLabel("Finished tasks", detail: "An agent finishes working and is ready for your next prompt.")
                }
                Toggle(isOn: $alertContext) {
                    SettingLabel("High context use",
                                 detail: "A session's context window, the conversation its model can hold, fills past the threshold below. Compact or start a new session before a large prompt.")
                }
                HStack {
                    SettingLabel("Context threshold", detail: "Working sessions above it also show “compact soon” in the menu.")
                    Spacer()
                    Slider(value: $contextThreshold, in: 70...95, step: 5).frame(width: 160)
                    Text("\(Int(contextThreshold))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                Toggle(isOn: $alertCache) {
                    SettingLabel("Prompt cache about to expire",
                                 detail: "A Claude session waiting for you keeps its context in Claude's prompt cache for an hour after its last request. Five minutes before that, Warden reminds you when replying later would cost about a point or more of the 5-hour limit, since the whole context is then written to the cache again. The menu shows the time left.")
                }
                Toggle(isOn: $alertQuota) {
                    SettingLabel("Usage limits and observed resets",
                                 detail: "A limit passes the level below, resets within 30 minutes while above 80%, or shows available capacity in a fresh reading after its reset, naming the sessions it stopped. Separate alerts report an observed drop of 30 points or more, without assuming a reset, and a reset that moved by an hour or more.")
                }
                Toggle(isOn: $alertResetExpiry) {
                    SettingLabel("Unused reset about to expire",
                                 detail: "Remind me to activate a banked reset before it expires, with a final reminder in the last hour. Codex uses CLI readings; Claude uses expiry dates entered from Usage. Includes a notification with Open Usage, even with the Voice style.")
                }
                if alertResetExpiry {
                    Picker("Remind before expiry", selection: $resetExpiryLead) {
                        Text("1 day").tag(24.0)
                        Text("3 days").tag(72.0)
                        Text("1 week").tag(168.0)
                    }
                }
                if alertQuota {
                    Picker("Warn when a limit passes", selection: $alertQuotaThreshold) {
                        ForEach([50.0, 75, 80, 90, 95], id: \.self) { Text("\(Int($0))%").tag($0) }
                    }
                    Toggle(isOn: $alertPace) {
                        SettingLabel("Warn when a limit is on pace to run out or drains faster than usual",
                                     detail: "Once per window, when its pace since it opened would use it up before its reset, or when it fills about twice as fast as your past windows did for use of the same API value. Estimates; History's Limits report shows the evidence.")
                    }
                    Picker(selection: $dailyBudget) {
                        Text("Off").tag(0.0)
                        Text("An even share, 14%").tag(100.0 / 7)
                        ForEach([20.0, 25, 33], id: \.self) { Text("\(Int($0))%").tag($0) }
                    } label: {
                        SettingLabel("Daily budget of a weekly limit",
                                     detail: "Once a day, when the day has taken more of a weekly limit than this share, as estimated in History's Limits report. A warning only: nothing is stopped.")
                    }
                    Toggle(isOn: $alertUnused) {
                        SettingLabel("Remind me of a week's unused quota",
                                     detail: "Once per week, a day before a weekly limit resets with half or more of it left, since unused quota does not carry over.")
                    }
                    Toggle(isOn: $alertHeavySession) {
                        SettingLabel("Warn when one session takes a large share",
                                     detail: "Once per window, when a session's share of a limit passes a third of a 5-hour window or a tenth of a week, as estimated in History's Limits report.")
                    }
                }
                Toggle(isOn: $awaySummary) {
                    SettingLabel("Summary when you come back",
                                 detail: "After a while with no keyboard or mouse input, or with the screen locked, a silent notification and the menu say what happened meanwhile: sessions that finished or wait for you, how long agents worked, and how the limits moved.")
                }
                if awaySummary {
                    Picker("After an absence of", selection: $awayMinutes) {
                        ForEach([10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                }
                Toggle(isOn: $quietDuringCalls) {
                    SettingLabel("Stay silent during calls",
                                 detail: "No voice line or alert sound while an app uses a microphone, as during a call or a recording. Notifications still appear. Warden reads only whether a microphone is in use, which needs no permission.")
                }
                Toggle(isOn: $quietInFront) {
                    SettingLabel("Stay quiet for the session in front",
                                 detail: "No alert for a session whose Terminal or iTerm tab you are looking at. Warden checks only a terminal it may already control, which it asks for when you first click a session.")
                }
                Toggle(isOn: $quietHours) {
                    SettingLabel("Quiet hours",
                                 detail: "No notifications or sounds between the hours you choose, every day. Missed alerts are not sent later; the menu still shows sessions that need you.")
                }
                if quietHours {
                    HStack {
                        Picker("From", selection: $quietFrom) { hourOptions }
                        Picker("Until", selection: $quietUntil) { hourOptions }
                    }
                }
                Text("In the menu, Only When Needed keeps only questions, approvals, errors, and interruptions. Snooze pauses all alerts for an hour.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Alert Style") {
                Picker("Claude", selection: $soundClaude) { styleOptions }
                    .onChange(of: soundClaude) { _, value in previewIfSpoken(value) }
                Picker("Codex", selection: $soundCodex) { styleOptions }
                    .onChange(of: soundCodex) { _, value in previewIfSpoken(value) }
                Text("Notification shows a banner with the system sound. Voice plays the alert's sound from the Sounds tab, usually a spoken line such as “I have a question for you.” A session can have its own style: in the menu, choose Alerts by Session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Menu Bar") {
                Toggle(isOn: $menuBarUsage) {
                    SettingLabel("Show a usage limit next to the icon",
                                 detail: "The lantern counts sessions that are working or waiting for you, and turns solid when one needs you. This adds a percentage from the menu's Usage section.")
                }
                .onChange(of: menuBarUsage) { store.objectWillChange.send() }
                if menuBarUsage {
                    Picker("Limit", selection: $menuBarWindow) {
                        Text("The fullest one").tag("highest")
                        ForEach(store.windows) { window in Text(window.name).tag(window.id) }
                    }
                    .onChange(of: menuBarWindow) { store.objectWillChange.send() }
                    Picker("Show", selection: $menuBarRemaining) {
                        Text("Used").tag(false)
                        Text("Remaining").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: menuBarRemaining) { store.objectWillChange.send() }
                }
                Toggle(isOn: $menuShowsUsage) {
                    SettingLabel("Show limits in the menu", detail: "The Usage section, with each limit window, its even-pace tick, and its reset.")
                }
                Toggle(isOn: $menuShowsRecent) {
                    SettingLabel("Show recent sessions in the menu", detail: "Finished, paused, and ended sessions, with their prompt cache.")
                }
                Toggle(isOn: $menuShowsAlerts) {
                    SettingLabel("Show alert choices in the menu", detail: "All Alerts, Only When Needed, Snooze, and Alerts by Session. The alert settings above still apply.")
                }
                Toggle("Open Warden at login", isOn: Binding(
                    get: { store.launchesAtLogin },
                    set: { value in
                        try? store.setLaunchAtLogin(value) // The store exposes failures beside this control.
                    }
                ))
                if store.loginStatus == .requiresApproval {
                    Text("Registered, but macOS approval is still needed before Warden can open at login.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Allow in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError = store.loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Keyboard") {
                shortcutPicker("Open Warden", selection: $shortcutOpen, choices: Shortcut.openChoices)
                shortcutPicker("Show the session that needs you", selection: $shortcutJump, choices: Shortcut.jumpChoices)
                Text("Shows the oldest approval or question first, then errors and interrupted turns. With nothing waiting, it opens the menu. These shortcuts work in any app and need no extra permission.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Monitoring and history stay on this Mac. Warden does not read API keys or save prompt content. Optional phone access sends encrypted session details to your paired devices; status checks read the provider's public status page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var claudeDescription: String {
        switch store.claudeConnection {
        case .connected: return "Hooks and status line report exact context, limits, and approvals."
        case .needsRepair: return "Warden's hooks point to another copy of the app."
        case .notConnected: return "Connect for exact context, limits, and approval alerts. Your Claude Code settings are backed up first."
        }
    }

    private var styleOptions: some View {
        ForEach(AlertStyle.allCases, id: \.self) { style in Text(style.title).tag(style.rawValue) }
    }

    /// Plays the voice once when you choose a style that speaks, as sound pickers do.
    private func previewIfSpoken(_ value: String) {
        if AlertStyle(rawValue: value)?.speaks == true { store.sounds.preview(store.sounds.choice(for: .question)) }
    }

    /// An account other than the default one, with its connection for Claude and a way to stop following it.
    private func otherAccount(_ account: AgentAccount) -> some View {
        let connection = store.otherConnections[account.id] ?? .notConnected
        let path = (account.folder.path as NSString).abbreviatingWithTildeInPath
        let agent = account.provider == .claude ? "Claude Code" : "Codex"
        return LabeledContent {
            HStack {
                if account.provider == .claude {
                    switch connection {
                    case .connected: Button("Disconnect") { store.disconnectClaude(account) }
                    case .needsRepair: Button("Repair") { store.confirmAndConnectClaude(account) }
                    case .notConnected: Button("Connect") { store.confirmAndConnectClaude(account) }
                    }
                }
                Button { store.removeAccount(account) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Stop following this account. Its folder stays as it is.")
            }
        } label: {
            Label {
                SettingLabel("\(agent) (\(account.name ?? ""))", detail: account.provider == .claude && connection != .connected
                             ? "\(path). Connect for exact context, limits, and approvals." : path)
            } icon: {
                Image(systemName: account.provider == .codex || connection == .connected ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(account.provider == .codex || connection == .connected ? Color.green : Color.secondary)
            }
        }
    }

    private func addAccountFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Add"
        panel.message = "Choose the folder that CLAUDE_CONFIG_DIR or CODEX_HOME names for another account."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        accountError = store.addAccount(folder) ? nil : "This folder holds no Claude Code or Codex sessions."
    }

    private func shortcutPicker(_ title: String, selection: Binding<String>, choices: [Shortcut]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Picker(title, selection: selection) {
                Text("Off").tag("off")
                ForEach(choices) { Text($0.title).tag($0.id) }
            }
            .onChange(of: selection.wrappedValue) { store.updateShortcuts() }
            if store.takenShortcuts.contains(selection.wrappedValue) {
                Text("Another app already uses this shortcut. Choose another.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var hourOptions: some View {
        ForEach(0..<24, id: \.self) { hour in
            Text(String(format: "%02d:00", hour)).tag(hour)
        }
    }
}

/// An account's monthly plan price, with the plan its CLI reports.
private struct PlanPriceRow: View {
    @ObservedObject var store: WardenStore
    let account: AgentAccount
    @State private var price: Double?

    private var key: String { PlanPrice.key(provider: account.provider, account: account.name) }

    var body: some View {
        let plan = store.plans.first { $0.provider == account.provider && $0.account == account.name }?.planName
        LabeledContent {
            TextField("Monthly price", value: $price, format: .currency(code: "USD"), prompt: Text("Not set"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
                .onSubmit(save)
                .onChange(of: price) { save() }
        } label: {
            SettingLabel("\(account.provider.rawValue)\(account.name.map { " (\($0))" } ?? "")",
                         detail: plan.map { "\($0) plan, as its CLI reports" } ?? "Plan not reported yet")
        }
        .onAppear { price = MenuFormat.planPrices[key] }
    }

    private func save() {
        var prices = UserDefaults.standard.dictionary(forKey: "planPrices") ?? [:]
        if let price, price > 0 { prices[key] = price } else { prices.removeValue(forKey: key) }
        UserDefaults.standard.set(prices, forKey: "planPrices")
        store.objectWillChange.send()
    }
}

/// A title with a short description under it, as rows in System Settings show them.
struct SettingLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
