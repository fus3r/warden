import AppKit
import Combine
import SwiftUI
import WardenCore

private final class ViewAction {
    let run: () -> Void
    init(run: @escaping () -> Void) { self.run = run }
}

/// The menu bar item and its native menu, laid out like the system Battery and Weather menus.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private enum Section { case attention, working, recent }

    private let store: WardenStore
    private let openSettings: () -> Void
    private let openHistory: () -> Void
    private let openPlanner: () -> Void
    private let openTutorial: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var subscription: AnyCancellable?
    private let titleFont = NSFont.menuFont(ofSize: 0)
    private let subtitleFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    init(store: WardenStore, openSettings: @escaping () -> Void,
         openHistory: @escaping () -> Void, openPlanner: @escaping () -> Void, openTutorial: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.openPlanner = openPlanner
        self.openTutorial = openTutorial
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        // Digits of equal width keep the item from shifting as the count changes.
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)
        // Only the menu bar item follows the store. AppKit can crash when a native row with a subtitle changes
        // while its menu is on screen, so rows are built as the menu opens. The SwiftUI rows update themselves.
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
        updateButton()
    }

    // MARK: Menu delegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        store.refresh(usage: true)
        store.refreshHistory(soon: true)
        #if DEBUG
        DebugSupport.captureMenu()
        #endif
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for entry in menu.items {
            (entry.view as? MenuHostView)?.state.highlighted = entry === item
        }
    }

    // MARK: Updates

    private var attention: [AgentSession] { store.attentionQueue }

    /// Opens the menu, as a click on the menu bar item does.
    func open() {
        statusItem.button?.performClick(nil)
    }

    private var working: [AgentSession] { store.sessions.filter { $0.phase == .working } }
    private var recent: [AgentSession] {
        Array(store.sessions.filter { $0.phase != .working && $0.phase != .needsAttention }.prefix(8))
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let attention = store.attentionCount
        // Like a task count: sessions still in progress, whether working or waiting for you.
        let open = attention + store.activeCount
        button.image = Lantern.image(attention > 0 ? .attention : open > 0 ? .working : .idle)
        var parts: [String] = []
        if open > 0 { parts.append("\(open)") }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "menuBarUsage") {
            // The chosen limit, or the fullest one. A value not reported for half an hour is left out.
            let fresh = store.windows.filter { $0.isCurrent() }
            let chosen = fresh.first { $0.id == defaults.string(forKey: "menuBarWindow") }
            if let window = chosen ?? fresh.max(by: { $0.usedPercent < $1.usedPercent }) {
                let used = Int(window.usedPercent.rounded())
                parts.append(defaults.bool(forKey: "menuBarRemaining") ? "\(max(0, 100 - used))% left" : "\(used)%")
            }
        }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        button.imagePosition = parts.isEmpty ? .imageOnly : .imageLeading
        // Snoozed alerts dim the item, as the system dims a menu bar item that is switched off.
        let snoozedUntil = store.snoozedUntil
        button.appearsDisabled = snoozedUntil != nil
        var summary = MenuFormat.summary(attention: attention, working: store.activeCount)
        if let snoozedUntil { summary += ". Alerts snoozed until \(MenuFormat.time(snoozedUntil))" }
        button.toolTip = summary
        button.setAccessibilityLabel("Warden, \(summary)")
    }

    private func rebuild() {
        let now = Date()
        menu.removeAllItems()
        menu.addItem(viewItem(height: 40, MenuHeaderView(store: store)))
        if let digest = store.awayDigest, now.timeIntervalSince(digest.away.end) < 1800 { menu.addItem(awayItem(digest)) }

        for (section, title, sessions) in [(Section.attention, "Needs You", attention), (.working, "Working", working)]
        where !sessions.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: title))
            for session in sessions { addSession(session, section: section, to: menu, now: now) }
        }

        let defaults = UserDefaults.standard
        if !store.windows.isEmpty, defaults.bool(forKey: "menuShowsUsage") {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Usage"))
            let hasNote = UsageNote.text(windows: store.windows, now: now) != nil
            let usage = viewItem(height: UsageSectionView.height(windowCount: store.windows.count, hasNote: hasNote,
                                                                 hasBanked: UsageSectionView.banked(store.plans) != nil),
                                 UsageSectionView(store: store))
            usage.toolTip = usageTooltip()
            usage.view?.toolTip = usage.toolTip
            menu.addItem(usage)
        }

        let usageShown = !store.windows.isEmpty && defaults.bool(forKey: "menuShowsUsage")
        if defaults.bool(forKey: "showWorkPlanner") {
            if !usageShown { menu.addItem(.separator()) }
            let planner = NSMenuItem(title: "Work Planner…", action: #selector(showPlanner), keyEquivalent: "")
            planner.target = self
            planner.image = symbol("clock.badge.checkmark")
            menu.addItem(planner)
        }

        if defaults.bool(forKey: "historyEnabled") {
            if !usageShown && !defaults.bool(forKey: "showWorkPlanner") { menu.addItem(.separator()) }
            menu.addItem(historyItem(store.history))
        }

        let showsRecent = !recent.isEmpty && defaults.bool(forKey: "menuShowsRecent")
        if showsRecent {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for session in recent { addSession(session, section: .recent, to: submenu, now: now) }
            item.submenu = submenu
            menu.addItem(item)
        }

        let listed = attention + working + recent
        if let item = trainGuardItem(for: listed) {
            if !showsRecent { menu.addItem(.separator()) }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let showsAlerts = defaults.bool(forKey: "menuShowsAlerts")
        if showsAlerts {
            menu.addItem(.sectionHeader(title: "Alerts"))
            for choice in AlertChoice.allCases {
                let item = viewItem(height: 32, closesMenu: false, action: { [weak self] in self?.choose(choice) },
                                    AlertChoiceRow(store: store, choice: choice))
                item.toolTip = choice.help
                item.view?.toolTip = choice.help
                menu.addItem(item)
            }
        }
        if !listed.isEmpty, showsAlerts {
            let item = NSMenuItem(title: "Alerts by Session", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for session in listed { submenu.addItem(styleItem(for: session)) }
            item.submenu = submenu
            menu.addItem(item)
        }

        if showsAlerts { menu.addItem(.separator()) }
        if let item = connectionItem() { menu.addItem(item) }
        menu.addItem(keepAwakeItem())
        let settings = NSMenuItem(title: "Warden Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let guide = NSMenuItem(title: "Interactive Guide…", action: #selector(showTutorial), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        let quit = NSMenuItem(title: "Quit Warden", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Items

    private func keepAwakeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Keep Awake", action: nil, keyEquivalent: "")
        item.image = symbol(store.keepAwake.isAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
        item.toolTip = store.keepAwake.status + ". " + store.keepAwake.detail
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let state = NSMenuItem(title: store.keepAwake.status, action: nil, keyEquivalent: "")
        state.isEnabled = false
        submenu.addItem(state)
        let toggle = NSMenuItem(title: "While Agents Work", action: #selector(runViewAction(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = UserDefaults.standard.bool(forKey: "keepAwake") ? .on : .off
        toggle.representedObject = ViewAction { [weak self] in
            let defaults = UserDefaults.standard
            defaults.set(!defaults.bool(forKey: "keepAwake"), forKey: "keepAwake")
            self?.store.keepAwake.refresh()
        }
        submenu.addItem(toggle)
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: "Power Settings…", action: #selector(runViewAction(_:)), keyEquivalent: "")
        settings.target = self
        settings.representedObject = ViewAction { [weak self] in
            UserDefaults.standard.set("power", forKey: "settingsTab")
            self?.openSettings()
        }
        submenu.addItem(settings)
        item.submenu = submenu
        return item
    }

    private func viewItem(height: CGFloat, closesMenu: Bool = true, action: (() -> Void)? = nil, _ content: some View) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuHostView(height: height, closesMenu: closesMenu, action: action, content: content)
        item.isEnabled = action != nil
        if let action {
            // Return and accessibility presses go through the item action; clicks go to the view.
            item.target = self
            item.action = #selector(runViewAction(_:))
            item.representedObject = ViewAction(run: action)
        }
        return item
    }

    private func addSession(_ session: AgentSession, section: Section, to menu: NSMenu, now: Date) {
        let item = NSMenuItem(title: name(of: session), action: #selector(openSession(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session.id
        item.keyEquivalentModifierMask = []
        item.image = icon(for: session)
        setSubtitle(item, MenuFormat.fit(subtitle(for: session), width: 222, font: subtitleFont))
        let start = section == .working ? (session.turnStartedAt ?? session.updatedAt) : session.updatedAt
        item.badge = NSMenuItemBadge(string: MenuFormat.age(since: start, now: now))
        item.toolTip = tooltip(for: session)

        let muted = store.isMuted(session)
        let alternate = NSMenuItem(title: name(of: session, prefix: muted ? "Unmute " : "Mute "),
                                   action: #selector(toggleMute(_:)), keyEquivalent: "")
        alternate.target = self
        alternate.representedObject = session.id
        alternate.isAlternate = true
        alternate.keyEquivalentModifierMask = .option
        alternate.image = symbol(muted ? "bell" : "bell.slash")
        setSubtitle(alternate, muted ? "Alert me about this session again" : "Stop alerts for this session")

        menu.addItem(item)
        menu.addItem(alternate)
        if section == .attention, let approval = store.approval(for: session) { addAnswers(approval, to: menu) }
        if section == .attention, session.attention == .failure, let incident = store.incidents[session.provider] {
            // The provider's own status page names what went wrong on its side.
            let status = NSMenuItem(title: MenuFormat.fit(incident.summary, width: 222, font: titleFont), action: #selector(openStatusPage(_:)),
                                    keyEquivalent: "")
            status.target = self
            status.representedObject = session.provider.rawValue
            status.indentationLevel = 1
            status.image = symbol("exclamationmark.icloud")
            setSubtitle(status, "\(session.provider == .claude ? "Anthropic" : "OpenAI") status page, \(MenuFormat.time(incident.checkedAt))")
            status.toolTip = "\(incident.summary)\nFrom \(ProviderStatus.page(session.provider).host ?? "the status page") at \(MenuFormat.time(incident.checkedAt)). Click to open it."
            menu.addItem(status)
        }
        if section == .attention, let note = store.cacheNote(for: session), note.cache.remaining(now: now) > 0 {
            // Answering while the cache holds the context rereads it at a tenth of the input price.
            let clock = NSMenuItem(title: "Reply within \(MenuFormat.remaining(note.cache.remaining(now: now))) to keep its cache",
                                   action: #selector(openSession(_:)), keyEquivalent: "")
            clock.target = self
            clock.representedObject = session.id
            clock.indentationLevel = 1
            clock.image = symbol("timer")
            let later = note.points.map { "A later reply costs ≈\(MenuFormat.points($0)) of \(note.window)" }
                ?? "A later reply rereads \(MenuFormat.tokens(note.cache.tokens)) tokens"
            setSubtitle(clock, MenuFormat.fit(later, width: 222, font: subtitleFont))
            clock.toolTip = cacheTooltip(note, now: now)
            menu.addItem(clock)
        }
    }

    /// Answers to a prompt, below its session: allow or deny a tool, or pick an option of a question.
    private func addAnswers(_ approval: PendingApproval, to menu: NSMenu) {
        let request = approval.request
        var choices: [(String, String, ApprovalChoice)] = []
        if request.isQuestion {
            // Only a single choice fits a menu item. Other questions are answered in their session.
            if let question = request.questions.first, request.questions.count == 1, !question.multiSelect {
                choices = question.options.prefix(6).enumerated().map { index, label in (label, "circle", .option(index)) }
            }
        } else {
            choices.append(("Allow", "checkmark.circle", .allow))
            if request.canAllowForSession { choices.append(("Allow for This Session", "checkmark.circle.badge.plus", .allowForSession)) }
            if let rule = request.alwaysRule { choices.append(("Always Allow \(rule)", "checkmark.seal", .allowAlways)) }
            choices.append(("Deny", "xmark.circle", .deny))
        }
        for (title, image, choice) in choices {
            let item = NSMenuItem(title: MenuFormat.fit(title, width: 200, font: titleFont), action: #selector(runViewAction(_:)), keyEquivalent: "")
            item.target = self
            item.indentationLevel = 1
            item.image = symbol(image)
            item.representedObject = ViewAction { [weak self] in self?.store.answer(request.id, choice) }
            switch choice {
            case .allowAlways where request.provider == .codex:
                // Codex writes the rule, as its own "Yes, and don't ask again" does.
                item.toolTip = "Codex adds an allow rule to \(request.alwaysFile ?? "its rules file") and stops asking for \(request.alwaysRule ?? "these commands")."
            case .allowAlways:
                // Claude Code writes the rule, as its own "Yes, and don't ask again" does.
                item.toolTip = request.alwaysRule.map { "Claude Code keeps the rule \($0) in \(request.alwaysFile ?? "its settings") and stops asking for it." }
            case .allowForSession where request.provider == .codex:
                item.toolTip = "Codex stops asking for this until the session ends."
            case .deny where request.provider == .codex:
                item.toolTip = "Codex stops and waits for what to do instead, as “No, and tell Codex what to do differently” does in the terminal."
            default:
                break
            }
            menu.addItem(item)
        }
    }

    /// A report window keeps filtering and exporting usable without holding a menu open. Its subtitle gives today's
    /// use in a plan's own currency, the share of each week's limit, when the limits have been split.
    private func historyItem(_ history: UsageSummary?) -> NSMenuItem {
        let item = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "")
        item.target = self
        item.image = symbol("chart.bar.xaxis")
        let day = UsageLedger.dayString(Date())
        var today: [String] = []
        if let quota = store.quota {
            let weeks = quota.windows.values.filter { $0.durationMinutes == 10_080 && $0.scope == nil }
                .sorted { ($0.provider.rawValue, $0.account ?? "") < ($1.provider.rawValue, $1.account ?? "") }
            let prices = MenuFormat.planPrices
            today = weeks.compactMap { week in
                let points = quota.charges.filter { $0.window == week.id && $0.day == day }.reduce(0) { $0 + $1.points }
                // With a plan price, the same share in the money the plan costs.
                let money = PlanPrice.perPoint(week, prices: prices).map { " ≈\(MenuFormat.cost(points * $0))" } ?? ""
                return points >= 0.5 ? "\(week.rowLabel) +\(Int(points.rounded()))%\(money)" : nil
            }
        }
        if today.isEmpty, let history {
            today = AgentProvider.allCases.sorted { $0.rawValue < $1.rawValue }.compactMap { provider -> String? in
                let totals = history.totals(lastDays: 1, provider: provider)
                return totals.tokens > 0 ? "\(provider.rawValue) \(MenuFormat.amount(totals, showCost: UserDefaults.standard.bool(forKey: "showAPIEquivalent")))" : nil
            }
        }
        setSubtitle(item, history == nil ? "Reading local usage…" : today.isEmpty ? "No recorded usage today" : "Today: " + today.joined(separator: " · "))
        var tip = ["Usage by day, project, and model; where each limit went; and when agents worked and waited for you."]
        if UserDefaults.standard.bool(forKey: "activityEnabled") {
            let now = Date()
            let activity = ActivitySummary(store.activitySpans + store.activity.open.values, from: Calendar.current.startOfDay(for: now), to: now)
            if activity.working + activity.waiting > 0 {
                tip.append("Today, agents worked \(ActivityReportView.duration(activity.working)) and waited \(ActivityReportView.duration(activity.waiting)) for you\(activity.waits > 0 ? " (\(activity.waits) \(activity.waits == 1 ? "time" : "times"))" : "").")
            }
        }
        if !today.isEmpty, store.quota != nil { tip.append("Today's share of each weekly limit is estimated from its rises.") }
        item.toolTip = tip.joined(separator: "\n")
        return item
    }

    /// What happened while you were away, with each line in a submenu. It opens the session that waits longest.
    private func awayItem(_ digest: AwayDigest) -> NSMenuItem {
        let item = NSMenuItem(title: "While You Were Away · \(AwayDigest.duration(digest.away.duration))", action: nil, keyEquivalent: "")
        item.image = symbol("figure.walk.arrival")
        setSubtitle(item, digest.headline.isEmpty ? "What agents did meanwhile" : digest.headline)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for line in digest.lines {
            let entry = NSMenuItem(title: MenuFormat.fit(line, width: 420, font: titleFont), action: nil, keyEquivalent: "")
            entry.isEnabled = false
            entry.toolTip = line
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        if let waiting = digest.firstWaiting {
            let open = NSMenuItem(title: "Show the Session That Waits Longest", action: #selector(openSession(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = waiting
            submenu.addItem(open)
        }
        let dismiss = NSMenuItem(title: "Dismiss", action: #selector(dismissAway), keyEquivalent: "")
        dismiss.target = self
        submenu.addItem(dismiss)
        item.submenu = submenu
        item.toolTip = "From \(MenuFormat.time(digest.away.start)) to \(MenuFormat.time(digest.away.end)), with no keyboard or mouse input or a locked screen."
        return item
    }

    /// A session with its alert styles. It follows its agent's style from Settings until you pick another.
    private func styleItem(for session: AgentSession) -> NSMenuItem {
        let chosen = store.sessionStyles[session.id]
        let general = AlertStyle.general(for: session.provider)
        let item = NSMenuItem(title: name(of: session), action: nil, keyEquivalent: "")
        setSubtitle(item, "\(session.provider.rawValue) · \(session.project) · \(chosen?.title ?? "Default")")
        let styles = NSMenu()
        styles.autoenablesItems = false
        for style in [nil] + AlertStyle.allCases.map(Optional.some) {
            let option = NSMenuItem(title: style?.title ?? "Default (\(general.title))",
                                    action: #selector(runViewAction(_:)), keyEquivalent: "")
            option.target = self
            option.state = style == chosen ? .on : .off
            option.representedObject = ViewAction { [weak self] in self?.store.setStyle(style, forSession: session.id) }
            styles.addItem(option)
            if style == nil { styles.addItem(.separator()) }
        }
        item.submenu = styles
        return item
    }

    /// The agents whose jobs train-guard runs at full speed, when train-guard is installed. It otherwise pauses long
    /// jobs on battery and lowers their priority while the battery is warm. Each session names its guarded jobs and
    /// what train-guard does with them now.
    private func trainGuardItem(for sessions: [AgentSession]) -> NSMenuItem? {
        let trainGuard = TrainGuard(home: store.trainGuard.home)
        guard !sessions.isEmpty, trainGuard.supportsSessionControl else { return nil }
        let ignored = trainGuard.ignoredAgents()
        let jobs = Dictionary(grouping: trainGuard.jobs(), by: \.agent)
        let item = NSMenuItem(title: "Ignore train-guard", action: nil, keyEquivalent: "")
        let chosen = sessions.filter { ignored.contains($0.id) }.map { $0.title ?? $0.project }
        setSubtitle(item, MenuFormat.fit(chosen.isEmpty ? "No agent ignored" : "Full speed for " + chosen.joined(separator: ", "),
                                         width: 222, font: subtitleFont))
        item.toolTip = "train-guard pauses long jobs on battery and lowers their priority while the battery is warm. The jobs a checked agent starts under train-guard run at full speed instead, on battery too."
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for session in sessions {
            let isIgnored = ignored.contains(session.id)
            let option = NSMenuItem(title: name(of: session), action: #selector(runViewAction(_:)), keyEquivalent: "")
            option.target = self
            option.state = isIgnored ? .on : .off
            let guarded = (jobs[session.id] ?? []).map { job in
                // The Python package says full and gentle, the shell script run and ecore.
                switch job.decision {
                case "stop": return "\(job.name) paused"
                case "gentle", "ecore": return "\(job.name) at low priority"
                case "full", "run": return "\(job.name) at full speed"
                case "waiting": return "\(job.name) waiting for its process"
                default: return job.name
                }
            }
            // The jobs matter more than the folder here, and the session's title already names it.
            setSubtitle(option, MenuFormat.fit(guarded.isEmpty ? "\(session.provider.rawValue) · \(session.project)" : guarded.joined(separator: " · "),
                                               width: 222, font: subtitleFont))
            option.toolTip = isIgnored
                ? "train-guard runs the jobs this agent starts at full speed. Click to put them back under its policy."
                : "Click to let the jobs this agent starts under train-guard run at full speed, on battery too. train-guard applies it at its next check."
            option.representedObject = ViewAction { [weak self] in self?.setTrainGuardIgnored(!isIgnored, session: session) }
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    /// The session's title from its provider, or its folder when there is none, fitted to the menu width.
    private func name(of session: AgentSession, prefix: String = "") -> String {
        MenuFormat.fit(prefix + (session.title ?? session.project), width: 222, font: titleFont)
    }

    private func icon(for session: AgentSession) -> NSImage? {
        switch session.phase {
        case .needsAttention:
            switch session.attention {
            case .permission: return symbol("hand.raised")
            case .failure: return symbol("exclamationmark.triangle")
            case .interrupted: return symbol("pause.circle")
            case .notification: return symbol("bell.badge")
            default: return symbol("questionmark.bubble")
            }
        case .working: return session.resumesAt == nil ? ContextRing.image(session.contextPercent) : symbol("hourglass")
        case .finished: return symbol("checkmark.circle")
        case .idle: return symbol(session.ended ? "stop.circle" : "pause.circle")
        case .unknown: return symbol("circle.dashed")
        }
    }

    private func subtitle(for session: AgentSession) -> String {
        var parts = [session.provider.rawValue + (session.account.map { " (\($0))" } ?? "")]
        // A titled session names its task above, so the folder moves here.
        if session.title != nil { parts.append(session.project) }
        if store.isMuted(session) { parts.append("Muted") }
        let threshold = UserDefaults.standard.double(forKey: "contextThreshold")
        let context = session.contextPercent.map { "\(session.contextEvidence == .inferred ? "≈" : "")\(Int($0.rounded()))%" }
        switch session.phase {
        case .needsAttention:
            switch session.attention {
            case .question: parts.append(session.detail ?? "Asked you a question")
            case .choice: parts.append(session.detail ?? "Waiting for your answer")
            case .permission:
                if let request = store.approval(for: session)?.request {
                    parts.append([request.tool, request.summary].compactMap { $0 }.joined(separator: ": "))
                } else {
                    parts.append(session.detail.map { "Approve \($0)" } ?? "Waiting for approval")
                }
            case .failure: parts.append(MenuFormat.failure(session.detail))
            case .interrupted: parts.append("Interrupted")
            default: parts.append(session.detail ?? "Needs your input")
            }
        case .working:
            if let resumes = session.resumesAt {
                parts.append("Usage limit, resumes \(MenuFormat.resetPhrase(resumes))")
            } else if let retry = session.retry, Date().timeIntervalSince(retry.at) < 600 {
                parts.append("\(retry.networkDown ? "Offline, retrying" : "Retrying after an error") (\(retry.attempt) of \(retry.maxAttempts))")
            } else if session.activeSubagents > 0 {
                parts.append(session.activeSubagents == 1 ? "1 agent working" : "\(session.activeSubagents) agents working")
            } else if session.busyInBackground {
                parts.append("Background task running")
            } else if let quiet = quietMinutes(session) {
                parts.append("No new output for \(MenuFormat.remaining(Double(quiet) * 60))")
            } else if let value = session.contextPercent, let context, value >= threshold {
                parts.append("Context \(context), compact soon")
            } else if let context {
                parts.append("Context \(context)")
            } else {
                parts.append(session.phaseEvidence == .inferred ? "Likely active" : "Working")
            }
        case .finished, .idle, .unknown:
            if session.phase == .idle, session.attention == nil, session.detail != nil {
                // A run that stopped on an error and then exited.
                parts.append(MenuFormat.failure(session.detail))
            } else {
                parts.append(session.phase == .finished ? "Done" : session.ended ? "Ended"
                    : session.phase == .idle ? "Paused" : "Quiet")
            }
            if !session.ended, let note = store.cacheNote(for: session) {
                let left = note.cache.remaining()
                parts.append(left > 0 ? "Cache \(MenuFormat.remaining(left))" : "Cache expired")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Minutes a working session's log has stayed unchanged, from ten on: a long tool run, a long reasoning step, or a
    /// stalled request.
    private func quietMinutes(_ session: AgentSession, now: Date = Date()) -> Int? {
        guard session.phase == .working, session.resumesAt == nil, session.activeSubagents == 0 else { return nil }
        let quiet = now.timeIntervalSince(session.updatedAt)
        return quiet >= 600 ? Int(quiet / 60) : nil
    }

    /// What the prompt cache holds, when it expires, and what a reply after that costs.
    private func cacheTooltip(_ note: CacheNote, now: Date = Date()) -> String {
        let cache = note.cache
        let lifetime = cache.minutes >= 60 ? "an hour" : "\(cache.minutes) minutes"
        let dollars = UserDefaults.standard.bool(forKey: "showAPIEquivalent")
            ? cache.warm.flatMap { warm in cache.cold.map { " (≈\(MenuFormat.cost($0)) instead of \(MenuFormat.cost(warm)) at API prices)" } } ?? ""
            : ""
        let rate = note.points == nil ? " Its cost in your limits shows once this window's rises have been split." : " An estimate at this window's rate."
        let source = cache.evidence == .provider ? "as Claude Code reports" : "from the last cache write in its log"
        var text: String
        if cache.remaining(now: now) > 0 {
            text = "Claude keeps this session's \(MenuFormat.tokens(cache.tokens))-token context cached until \(MenuFormat.time(cache.expiresAt)), \(lifetime) after its last request, \(source). A reply after that writes it to the cache again\(dollars): \(note.cost).\(rate)"
        } else {
            text = "The prompt cache expired at \(MenuFormat.time(cache.expiresAt)), \(source). Resuming writes the \(MenuFormat.tokens(cache.tokens))-token context to the cache again\(dollars): \(note.cost).\(rate)"
        }
        if let health = cacheHealth(cache.report) { text += "\n" + health }
        return text
    }

    /// Claude Code's own account of the cache: its hit ratio, and the misses that wrote the context again.
    private func cacheHealth(_ report: StatusCache?) -> String? {
        guard let report, let ratio = report.hitRatio else { return nil }
        var text = "\(ratio.formatted(.percent.precision(.fractionLength(0)))) of this session's input came from the cache"
        if let misses = report.misses, misses > 0 {
            text += "; \(misses == 1 ? "1 miss" : "\(misses) misses") wrote \(MenuFormat.tokens(report.missTokens ?? 0)) tokens again"
            if let causes = report.lastMissCauses, !causes.isEmpty {
                text += ", the last because \(ListFormatter.localizedString(byJoining: causes.map(PromptCache.cause)))"
            }
        }
        return text + "."
    }

    private func tooltip(for session: AgentSession) -> String {
        var lines: [String] = []
        if let title = session.title { lines.append(title) }
        let host = SessionNavigator.hostName(SessionNavigator.hostBundleID(for: session, processes: store.processes))
        lines.append(["\(session.provider.rawValue)\(host.map { " in \($0)" } ?? "")", session.model]
            .compactMap { $0 }.joined(separator: " · "))
        if let value = session.contextPercent {
            let source = session.contextEvidence == .provider ? "reported by Claude Code" : "estimated from the local log"
            lines.append("Context \(Int(value.rounded()))%, \(source)")
        } else {
            lines.append("Context unavailable")
        }
        if let totals = store.history?.sessions[session.id], totals.tokens > 0 {
            let cost = UserDefaults.standard.bool(forKey: "showAPIEquivalent") && totals.cost > 0
                ? "≈\(MenuFormat.cost(totals.cost)) API equivalent\(totals.isFullyPriced ? "" : " for priced models"), " : ""
            lines.append("Recent recorded use: \(cost)\(MenuFormat.tokens(totals.tokens)) tokens")
        }
        if let limits = store.quota?.points(session: session.id), !limits.isEmpty {
            // The session's share of each limit's current window, in the currency a plan is metered in.
            let shares = limits.prefix(3).map { "≈\(MenuFormat.points($0.points)) of \($0.window.name)" }
            lines.append("Limits so far in their current windows: \(shares.joined(separator: ", ")), estimated from limit rises")
        }
        switch session.phaseEvidence {
        case .provider: lines.append("State from Claude Code hooks")
        case .localLog: lines.append("State from the local session log")
        case .inferred: lines.append("State inferred from process activity")
        }
        if session.attention == .question || session.attention == .choice {
            // The subtitle often cuts the question short.
            if let question = session.detail { lines.append("Asks: \(question)") }
            lines.append(session.attention == .choice ? "Claude Code waits for your answer to its question."
                         : "A final question is detected by a heuristic.")
        }
        if let retry = session.retry, session.phase == .working, Date().timeIntervalSince(retry.at) < 600 {
            lines.append("\(retry.networkDown ? "Claude Code cannot reach its API" : "A request failed"), and it retries by itself: attempt \(retry.attempt) of \(retry.maxAttempts), at \(MenuFormat.time(retry.at)).")
        }
        if session.busyInBackground, session.phase == .working {
            lines.append("Its turn ended at \(MenuFormat.time(session.updatedAt)), but Claude Code reports it busy: a command it started in the background still runs, and Claude goes on when it ends.")
        } else if quietMinutes(session) != nil {
            lines.append("Its log has not changed since \(MenuFormat.time(session.updatedAt)): a long tool run, a long reasoning step, or a stalled request. Esc in its terminal stops a stalled turn.")
        }
        if !session.ended, let note = store.cacheNote(for: session) {
            lines.append(cacheTooltip(note))
        } else if let health = cacheHealth(session.statusCache), (session.statusCache?.misses ?? 0) > 0 {
            lines.append(health)
        }
        lines.append((session.cwd as NSString).abbreviatingWithTildeInPath)
        lines.append("Click to show. Option-click to mute.")
        return lines.joined(separator: "\n")
    }

    private func usageTooltip() -> String {
        let lines = store.windows.map { window -> String in
            let source = window.provider == .claude ? "Claude account, reported by Claude Code"
                : window.evidence == .provider ? "Codex account, read through the Codex CLI" : "Codex session log"
            let reset = window.resetsAt.map { ", resets \(MenuFormat.resetPhrase($0))" } ?? ""
            // Where this window went so far, by project, when its rises have been split.
            let shares = (store.quota?.projects(inCurrent: window.id) ?? []).filter { $0.points >= 0.5 }.prefix(3)
                .map { "\($0.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "no local use") \(MenuFormat.points($0.points))" }
            let split = shares.isEmpty ? "" : " So far: \(shares.joined(separator: ", "))."
            // The recent pace, from the readings of the last hour, next to the window's average in the projection.
            let pace = store.paceTracker.pace(for: window).map {
                " Recently +\($0.pointsPerHour.formatted(.number.precision(.fractionLength(1)))) points an hour, over \($0.sampledMinutes) min."
            } ?? ""
            return "\(window.name): \(Int(window.usedPercent.rounded()))% used\(reset). From the \(source) at \(MenuFormat.time(window.observedAt)).\(pace)\(split)"
        }
        let plans = store.plans.sorted { ($0.provider.rawValue, $0.account ?? "") < ($1.provider.rawValue, $1.account ?? "") }
            .compactMap { plan in plan.planName.map { "\(plan.provider.rawValue)\(plan.account.map { " (\($0))" } ?? "") \($0) plan" } }
        return (lines + plans + ["The tick marks an even pace through the window. Projections are estimates."]).joined(separator: "\n")
    }

    private func connectionItem() -> NSMenuItem? {
        let item: NSMenuItem
        switch store.claudeConnection {
        case .connected:
            return nil
        case .notConnected:
            guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude") else { return nil }
            item = NSMenuItem(title: "Connect Claude Code…", action: #selector(connectClaude), keyEquivalent: "")
            setSubtitle(item, "Exact context, limits, and approval alerts")
        case .needsRepair:
            item = NSMenuItem(title: "Repair Claude Code Connection…", action: #selector(connectClaude), keyEquivalent: "")
            setSubtitle(item, "Warden's hooks point elsewhere or are incomplete")
        }
        item.target = self
        item.image = symbol("link")
        return item
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func setSubtitle(_ item: NSMenuItem, _ text: String) {
        if #available(macOS 14.4, *) { item.subtitle = text }
    }

    // MARK: Actions

    private func choose(_ choice: AlertChoice) {
        switch choice {
        case .all: store.setAlertMode(.all)
        case .attention: store.setAlertMode(.attention)
        case .snooze:
            if store.snoozedUntil != nil { store.setAlertMode(store.alertMode) } else { store.snooze(for: 3600) }
        }
        updateButton()
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.open(sessionID: id)
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.toggleMute(sessionID: id)
    }

    @objc private func connectClaude() {
        store.confirmAndConnectClaude()
    }

    @objc private func runViewAction(_ sender: NSMenuItem) {
        (sender.representedObject as? ViewAction)?.run()
    }

    @objc private func dismissAway() { store.dismissAwayDigest() }

    private func setTrainGuardIgnored(_ ignored: Bool, session: AgentSession) {
        do {
            try TrainGuard(home: store.trainGuard.home).setIgnored(ignored, agent: session.id, label: "\(session.provider.rawValue) · \(session.project)")
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openStatusPage(_ sender: NSMenuItem) {
        guard let provider = (sender.representedObject as? String).flatMap(AgentProvider.init) else { return }
        NSWorkspace.shared.open(ProviderStatus.page(provider))
    }

    @objc private func showTutorial() { openTutorial() }
    @objc private func showSettings() { openSettings() }
    @objc private func showHistory() { openHistory() }
    @objc private func showPlanner() { openPlanner() }

    @objc private func quit() { NSApp.terminate(nil) }
}
