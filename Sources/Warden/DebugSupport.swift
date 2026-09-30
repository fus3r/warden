#if DEBUG
import AppKit
import SwiftUI
import WardenCore

/// Development aids for debug builds only.
/// `WARDEN_CAPTURE=/path/prefix` saves the open menu to PNG files: an app may image its own windows without permission.
/// `WARDEN_FIXTURE=1` shows sample sessions so every menu state can be reviewed.
enum DebugSupport {
    static var usesFixture: Bool { ProcessInfo.processInfo.environment["WARDEN_FIXTURE"] == "1" }

    static func sampleScan() -> ScanResult {
        fixture(ScanResult(sessions: [], windows: [], processes: [], nativeApps: [], scannedAt: Date()))
    }

    static func sampleHistory() -> UsageSummary {
        let now = Date()
        var records: [UsageRecord] = []
        for back in 0..<45 {
            let day = UsageLedger.dayString(Calendar.current.date(byAdding: .day, value: -back, to: now)!)
            let scale = (back * 7 % 11 + 2) * 30_000
            records.append(UsageRecord(day: day, provider: .claude, model: "claude-opus-5-5", project: "/Projects/warden",
                                       usage: TokenUsage(input: scale, cacheRead: scale * 4, output: scale / 8, requests: 20 + back)))
            records.append(UsageRecord(day: day, provider: .codex, model: "gpt-unpriced", project: "/Projects/research",
                                       usage: TokenUsage(input: scale * 2, cacheRead: scale * 3, output: scale / 4, requests: 32 + back)))
            records.append(UsageRecord(day: day, provider: .claude, model: "claude-sonnet-5", project: "/Projects/website",
                                       usage: TokenUsage(input: scale / 2, output: scale / 5, requests: 8 + back), account: "Work"))
        }
        return UsageSummary(records: records, now: now)
    }

    /// Limits split by project over 45 days, with a current window and a few finished ones.
    static func sampleQuota() -> QuotaSummary {
        let now = Date()
        let projects = ["/Projects/warden", "/Projects/research", "/Projects/website", "/Projects/api"]
        let week = UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: 62,
                               resetsAt: now.addingTimeInterval(2 * 86_400), observedAt: now, evidence: .provider, minutes: 10_080)
        let hours = UsageWindow(id: "Claude-five_hour", provider: .claude, label: "5h", usedPercent: 71,
                                resetsAt: now.addingTimeInterval(7200), observedAt: now, evidence: .provider, minutes: 300)
        let codex = UsageWindow(id: "Codex-primary", provider: .codex, label: "7d", usedPercent: 40,
                                resetsAt: now.addingTimeInterval(4 * 86_400), observedAt: now, evidence: .provider, minutes: 10_080)
        var charges: [QuotaCharge] = []
        for back in 0..<45 {
            let day = UsageLedger.dayString(Calendar.current.date(byAdding: .day, value: -back, to: now)!)
            for (index, project) in projects.enumerated() where (back + index) % 3 != 0 {
                let points = Double((back * 7 + index * 5) % 11 + 1) / Double(index + 1)
                charges.append(QuotaCharge(day: day, window: week.id, project: project, points: points))
                charges.append(QuotaCharge(day: day, window: hours.id, project: project, points: points * 6))
                charges.append(QuotaCharge(day: day, window: codex.id, project: project, points: points / 2))
            }
            if back % 4 == 0 { charges.append(QuotaCharge(day: day, window: week.id, project: nil, points: 1.5)) }
        }
        var current = QuotaPeriod(window: week.id, resetsAt: week.resetsAt, percent: 62)
        current.projects = [projects[0]: 31, projects[1]: 17, projects[2]: 6.5]
        current.sessions = ["f3": 12, "f1": 4]
        current.unexplained = 3
        current.dollars = 57.5 * 14.2
        current.pricedPoints = 57.5
        var short = QuotaPeriod(window: hours.id, resetsAt: hours.resetsAt, percent: 71)
        short.projects = [projects[0]: 48, projects[3]: 23]
        short.sessions = ["f3": 30, "f1": 9]
        short.dollars = 71 * 1.9
        short.pricedPoints = 71
        let finished = (1...3).reversed().map { back -> QuotaPeriod in
            var period = QuotaPeriod(window: week.id, resetsAt: week.resetsAt!.addingTimeInterval(-Double(back) * 7 * 86_400),
                                     percent: [96, 81, 100][back - 1])
            period.projects = [projects[back % projects.count]: period.percent * 0.6, projects[0]: period.percent * 0.3]
            period.dollars = period.percent * 0.9 * [15.1, 14.6, 9.8][back - 1]
            period.pricedPoints = period.percent * 0.9
            return period
        }
        return QuotaSummary(charges: charges, windows: [week.id: week, hours.id: hours, codex.id: codex],
                            current: [week.id: current, hours.id: short], finished: finished,
                            coverage: now.addingTimeInterval(-8 * 86_400))
    }

    /// A week of work and waits across four sessions, with today's spans ending now.
    static func sampleActivity() -> [ActivitySpan] {
        let calendar = Calendar.current
        let now = Date()
        var spans: [ActivitySpan] = []
        let sessions: [(String, AgentProvider, String)] = [("f3", .claude, "/Users/me/warden"), ("f4", .codex, "/Users/me/site"),
                                                           ("f1", .claude, "/Users/me/example-app"), ("f2", .codex, "/Users/me/learning-app")]
        for back in 0..<7 {
            let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now))!
            for (index, (id, provider, project)) in sessions.enumerated() {
                var time = day.addingTimeInterval(Double(9 * 3600 + index * 1500 + back * 600))
                for turn in 0..<(5 + (back + index) % 4) {
                    let work = Double(600 + (turn * 397 + index * 211 + back * 97) % 2400)
                    let end = time.addingTimeInterval(work)
                    guard end < now else { break }
                    spans.append(ActivitySpan(session: id, provider: provider, project: project, kind: .working, start: time, end: end))
                    let wait = Double(30 + (turn * 173 + index * 59) % 900)
                    let kind: AttentionKind = [.permission, .question, .interrupted, .failure][(turn + index) % 4]
                    var span = ActivitySpan(session: id, provider: provider, project: project, kind: .waiting, attention: kind,
                                            tool: kind == .permission ? "Bash" : nil, start: end, end: min(now, end.addingTimeInterval(wait)))
                    span.answeredInWarden = turn % 3 == 0
                    spans.append(span)
                    time = end.addingTimeInterval(wait + 120)
                }
            }
        }
        return spans
    }

    /// An absence of 47 minutes that ended two minutes ago, with the fixture's sessions and limits.
    static func sampleAway() -> AwayDigest {
        let now = Date()
        let scan = sampleScan()
        let away = DateInterval(start: now.addingTimeInterval(-49 * 60), end: now.addingTimeInterval(-120))
        var before = scan.windows
        for index in before.indices { before[index].usedPercent = max(0, before[index].usedPercent - 9) }
        var sessions = scan.sessions
        for index in sessions.indices where sessions[index].phase == .finished {
            sessions[index].updatedAt = now.addingTimeInterval(-20 * 60)
        }
        return AwayDigest(away: away, sessions: sessions, spans: sampleActivity(), before: before, windows: scan.windows, now: now)
    }

    /// The fixture's permission prompt, answerable from the menu and a paired phone; answers go nowhere.
    static func sampleApprovals() -> [PendingApproval] {
        let hook: [String: Any] = [
            "tool_name": "Bash", "cwd": "/Users/me/example-app",
            "tool_input": ["command": "./deploy.sh --prod &&\n  rm -rf build/cache"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "./deploy.sh:*"]],
                                        "behavior": "allow", "destination": "localSettings"]]
        ]
        return [Approval.request(from: hook, id: "fixture-f1", sessionID: "f1")].compactMap { $0 }
            .map { PendingApproval(request: $0, receivedAt: Date()) }
    }

    static func samplePace(windows: [UsageWindow]) -> UsagePaceTracker {
        let now = Date()
        var tracker = UsagePaceTracker()
        for back in [20, 10, 0] {
            let samples = windows.map { original in
                var sample = original
                sample.observedAt = original.observedAt.addingTimeInterval(-Double(back) * 60)
                sample.usedPercent = max(0, original.usedPercent - Double(back) * (original.scope == nil ? 0.8 : 0.4))
                return sample
            }
            tracker.record(samples, now: now.addingTimeInterval(-Double(back) * 60))
        }
        return tracker
    }
    static func captureMenu() {
        guard let prefix = ProcessInfo.processInfo.environment["WARDEN_CAPTURE"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            typealias Capture = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
            guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
            let capture = unsafeBitCast(symbol, to: Capture.self)
            for window in NSApp.windows where window.isVisible {
                let name = window.className.contains("StatusBar") ? "status" : window.className.contains("Menu") ? "menu" : nil
                guard let name, let image = capture(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue() else { continue }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(name)-\(window.windowNumber).png"))
            }
        }
    }

    /// With `WARDEN_SHOW` and `WARDEN_CAPTURE=/path/prefix`, saves each open window after `WARDEN_CAPTURE_AFTER` seconds
    /// (20 by default), so a report can be checked with the store's live data.
    static func captureWindowsLater() {
        let environment = ProcessInfo.processInfo.environment
        guard let prefix = environment["WARDEN_CAPTURE"], environment["WARDEN_SHOW"] != nil else { return }
        let delay = environment["WARDEN_CAPTURE_AFTER"].flatMap(Double.init) ?? 20
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            typealias Capture = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?
            guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return }
            let capture = unsafeBitCast(symbol, to: Capture.self)
            for window in NSApp.windows where window.isVisible && !window.title.isEmpty {
                guard let image = capture(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                          [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue() else { continue }
                let name = window.title.replacingOccurrences(of: " ", with: "-")
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
            }
            print("captured")
            fflush(stdout)
        }
    }

    /// `WARDEN_PHONE_PAIR=1` opens a phone pairing once the network is known and prints its link and code, for tests
    /// with curl or a simulator.
    static func openPhonePairingIfRequested(_ phone: PhoneCompanion) {
        guard ProcessInfo.processInfo.environment["WARDEN_PHONE_PAIR"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                phone.openPairing()
                print("pairing", (phone.usesRelay ? phone.remote.pairingURL : phone.pairingURL)?.absoluteString ?? "-", phone.pairing?.code ?? "-")
                fflush(stdout)
            }
        }
    }

    /// `WARDEN_TRAIN_GUARD_HOME=/path` makes Settings install train-guard, and read and write the agents' instructions,
    /// in that folder instead of the home folder.
    static var trainGuardHome: URL {
        ProcessInfo.processInfo.environment["WARDEN_TRAIN_GUARD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// `WARDEN_TRAIN_GUARD_CONFIRM=install`, `remove`, or `instructions` asks as the Settings button does, so the alert
    /// and what follows can be checked, and prints the resulting message. Pair it with `WARDEN_TRAIN_GUARD_HOME`.
    @MainActor static func confirmTrainGuardIfRequested(_ store: WardenStore) {
        guard let action = ProcessInfo.processInfo.environment["WARDEN_TRAIN_GUARD_CONFIRM"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let setup = store.trainGuard
            setup.refresh(accounts: store.accounts)
            switch action {
            case "install": setup.confirmInstall(accounts: store.accounts)
            case "remove": setup.confirmRemove(accounts: store.accounts)
            default: setup.confirmAddInstructions(accounts: store.accounts)
            }
            @MainActor func report() {
                guard !setup.isBusy else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { report() } }
                    return
                }
                print("train-guard:", setup.install, "|", setup.message ?? "no message")
                fflush(stdout)
            }
            report()
        }
    }

    /// `WARDEN_TRAIN_GUARD_ONCE=/path` installs train-guard with that folder standing for the home folder, prints the
    /// bundled runtime it used, the version, and the time taken, removes it again with `WARDEN_TRAIN_GUARD_REMOVE=1`, then quits.
    static func trainGuardOnceIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["WARDEN_TRAIN_GUARD_ONCE"] else { return false }
        let home = URL(fileURLWithPath: path)
        let start = Date()
        do {
            print("runtime:", try TrainGuardPackage.verifiedRuntime().path)
            print("installed:", try TrainGuardSetup.installPackage(home: home), "in", Int(Date().timeIntervalSince(start)), "s")
            if environment["WARDEN_TRAIN_GUARD_REMOVE"] == "1" {
                try TrainGuardSetup.removePackage(home: home)
                print("removed")
            }
        } catch {
            print("failed:", error.localizedDescription)
        }
        exit(0)
    }

    /// `WARDEN_SCAN_ONCE=1` prints one scan without showing anything, then quits.
    static func scanOnceIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["WARDEN_SCAN_ONCE"] == "1" else { return false }
        let result = TelemetryScanner().scan(accounts: WardenStore.discoverAccounts(), refreshUsage: true)
        for session in result.sessions.prefix(12) {
            print(session.id.prefix(8), session.provider.rawValue, session.project, session.phase.rawValue,
                  session.attention?.rawValue ?? "-", session.phaseEvidence.rawValue,
                  session.updatedAt.formatted(date: .omitted, time: .standard), "ended:", session.ended,
                  "account:", session.account ?? "-", "title:", session.title ?? "-")
        }
        for window in result.windows {
            print(window.id, window.usedPercent, window.evidence.rawValue, "observed", window.observedAt.formatted(date: .omitted, time: .standard),
                  "resets", window.resetsAt?.formatted() ?? "-")
        }
        exit(0)
    }

    /// `WARDEN_HISTORY_ONCE=1` updates the usage history, prints its totals and timing, then quits.
    static func historyOnceIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["WARDEN_HISTORY_ONCE"] == "1" else { return false }
        let start = Date()
        let records = UsageHistory().update(accounts: WardenStore.discoverAccounts()).records
        let elapsed = Date().timeIntervalSince(start)
        let summary = UsageSummary(records: records)
        print("records:", records.count, "seconds:", String(format: "%.2f", elapsed))
        for days in [1, 7, 30] {
            for provider in AgentProvider.allCases {
                let totals = summary.totals(lastDays: days, provider: provider)
                print("\(days)d", provider.rawValue, "tokens:", totals.tokens, "requests:", totals.requests,
                      "cost:", String(format: "%.2f", totals.cost), "unpriced:", totals.unpricedTokens)
            }
        }
        for group in summary.models(lastDays: 30).prefix(8) {
            print("model", group.name, group.totals.tokens, String(format: "%.2f", group.totals.cost))
        }
        for account in Set(records.compactMap(\.account)).sorted() {
            let own = records.filter { $0.account == account }
            print("account", account, "records:", own.count, "tokens:", own.reduce(0) { $0 + $1.usage.total })
        }
        for group in summary.projects(lastDays: 30).prefix(5) {
            print("project", URL(fileURLWithPath: group.name).lastPathComponent, group.totals.tokens, String(format: "%.2f", group.totals.cost))
        }
        exit(0)
    }

    /// `WARDEN_QUOTA_ONCE=1` reads the logs into a scratch folder, splits the installed app's latest limit readings
    /// among the sessions that used tokens since each window started, prints the result, then quits.
    static func quotaOnceIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["WARDEN_QUOTA_ONCE"] == "1" else { return false }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("warden-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let now = Date()
        let start = Date()
        let update = UsageHistory(directory: scratch).update(accounts: WardenStore.discoverAccounts(), now: now, events: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Warden/usage.json")
        let readings = (try? Data(contentsOf: installed)).flatMap { try? decoder.decode([UsageWindow].self, from: $0) } ?? []
        // The installed app keeps writing readings; the logs are taken as read past the latest one.
        let readAt = max(now, readings.map(\.observedAt).max() ?? now).addingTimeInterval(6)
        let summary = QuotaLedger(directory: scratch).update(events: update.events, readings: readings, readAt: readAt,
                                                             coverage: now.addingTimeInterval(-8 * 86_400))
        print("events:", update.events.count, "seconds:", String(format: "%.2f", Date().timeIntervalSince(start)))
        for (id, period) in summary.current.sorted(by: { $0.key < $1.key }) {
            let exchange = period.dollarsPerPoint.map { String(format: "$%.2f per point", $0) } ?? "no API value"
            print(id, "percent:", period.percent, "split:", String(format: "%.2f", period.attributed),
                  "unexplained:", String(format: "%.2f", period.unexplained), exchange)
            for (project, points) in summary.projects(inCurrent: id).prefix(6) {
                print("   ", project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "(no local use)", String(format: "%.2f", points))
            }
        }
        exit(0)
    }

    /// `WARDEN_RENDER_HISTORY=/path.png` reads the usage history and renders its menu view offscreen, then quits.
    static func renderHistoryIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WARDEN_RENDER_HISTORY"] else { return false }
        let summary = usesFixture ? sampleHistory()
            : UsageSummary(records: UsageHistory().update(accounts: WardenStore.discoverAccounts()).records)
        render(HistoryReportView(summary: summary), size: NSSize(width: 780, height: 740), to: path)
        return true
    }

    /// `WARDEN_RENDER_LIMITS=/path.png` renders the Limits report: sample data with `WARDEN_FIXTURE=1`, and otherwise
    /// this Mac's logs split against the installed app's latest readings.
    static func renderLimitsIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WARDEN_RENDER_LIMITS"] else { return false }
        var quota = sampleQuota()
        if !usesFixture {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("warden-quota-\(UUID().uuidString)")
            let now = Date()
            let update = UsageHistory(directory: scratch).update(accounts: WardenStore.discoverAccounts(), now: now, events: true)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Warden/usage.json")
            let readings = (try? Data(contentsOf: installed)).flatMap { try? decoder.decode([UsageWindow].self, from: $0) } ?? []
            quota = QuotaLedger(directory: scratch).update(events: update.events, readings: readings,
                                                           readAt: max(now, readings.map(\.observedAt).max() ?? now).addingTimeInterval(6),
                                                           coverage: now.addingTimeInterval(-8 * 86_400))
            try? FileManager.default.removeItem(at: scratch)
        }
        render(LimitsReportView(quota: quota), size: NSSize(width: 800, height: 900), to: path)
        return true
    }

    /// `WARDEN_RENDER_ACTIVITY=/path.png` renders the Activity report with sample spans.
    static func renderActivityIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WARDEN_RENDER_ACTIVITY"] else { return false }
        render(ActivityReportView(spans: sampleActivity(), titles: ["f3": "Native menu bar redesign", "f4": "Fix header layout"]),
               size: NSSize(width: 800, height: 1000), to: path)
        return true
    }

    static func renderPlannerIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WARDEN_RENDER_PLANNER"] else { return false }
        let scan = sampleScan()
        render(WorkPlannerReport(windows: scan.windows, tracker: samplePace(windows: scan.windows),
                                 sessions: scan.sessions, now: Date(), scannedAt: scan.scannedAt), size: NSSize(width: 740, height: 720), to: path)
        return true
    }

    private static func render(_ content: some View, size: NSSize, to path: String) {
        let environment = ProcessInfo.processInfo.environment
        let size = NSSize(width: environment["WARDEN_RENDER_WIDTH"].flatMap(Double.init) ?? size.width,
                          height: environment["WARDEN_RENDER_HEIGHT"].flatMap(Double.init) ?? size.height)
        // Menus draw their own material behind item views; a plain dark fill stands in for it.
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["WARDEN_APPEARANCE"] == "light" ? .aqua : .darkAqua)
        window.contentView = view
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }

    /// Offscreen guide layouts, with `-tutorialChapter <chapter>` as a process-only defaults override.
    @MainActor static func renderTutorialIfRequested(store: WardenStore) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WARDEN_RENDER_TUTORIAL"] else { return false }
        guard usesFixture else { return false }
        store.start()
        render(TutorialView(store: store, openSettings: { _ in }, openHistory: {}, openPlanner: {}, close: {}),
               size: NSSize(width: 900, height: 640), to: path)
        return true
    }

    /// `WARDEN_RENDER_SETTINGS=/path.png` renders the Settings window offscreen, then quits.
    @MainActor static func renderSettingsIfRequested(store: WardenStore) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["WARDEN_RENDER_SETTINGS"] else { return false }
        // The Phone tab shows the certificate and the network once the companion has started.
        store.phone.start()
        // And Long Jobs once it has looked for train-guard, which it does when the tab appears.
        store.trainGuard.refresh(accounts: store.accounts)
        render(WardenSettings(store: store), size: NSSize(width: 540, height: WardenSettings.height), to: path)
        return true
    }

    static func fixture(_ result: ScanResult) -> ScanResult {
        if ProcessInfo.processInfo.environment["WARDEN_DUMP"] == "1" {
            for session in result.sessions {
                print(session.id.prefix(8), session.provider.rawValue, session.project, session.phase.rawValue,
                      session.phaseEvidence.rawValue, session.updatedAt.formatted(date: .omitted, time: .standard),
                      "pid:", session.host?.pid.map(String.init) ?? "-", "ended:", session.ended, "title:", session.title ?? "-")
            }
            print("--")
            fflush(stdout)
        }
        guard ProcessInfo.processInfo.environment["WARDEN_FIXTURE"] == "1" else { return result }
        let now = Date()
        func session(_ id: String, _ provider: AgentProvider, _ cwd: String, _ phase: AgentPhase, _ attention: AttentionKind? = nil,
                     title: String? = nil, detail: String? = nil, context: Double? = nil, age: TimeInterval) -> AgentSession {
            AgentSession(id: id, provider: provider, surface: "Terminal", cwd: cwd, model: "Opus 5.5", phase: phase,
                         phaseEvidence: provider == .claude ? .provider : .localLog, attention: attention,
                         updatedAt: now.addingTimeInterval(-age), contextPercent: context,
                         contextEvidence: provider == .claude ? .provider : .inferred, title: title, detail: detail,
                         turnStartedAt: now.addingTimeInterval(-age - 600))
        }
        var fixture = result
        // A permission prompt whose 380K-token context stays cached for 23 more minutes.
        var deploy = session("f1", .claude, "/Users/me/example-app", .needsAttention, .permission, title: "Harden deploy script", detail: "Bash", age: 70)
        deploy.modelID = "claude-opus-5-5"
        deploy.cacheMinutes = 60
        deploy.lastInputTokens = 380_000
        deploy.lastRequestAt = now.addingTimeInterval(-37 * 60)
        var overloaded = session("f8", .claude, "/Users/me/api", .needsAttention, .failure, title: "Migrate billing tables",
                                 detail: "overloaded", age: 240)
        overloaded.modelID = "claude-opus-5-5"
        fixture.sessions = [
            deploy,
            overloaded,
            session("f2", .codex, "/Users/me/learning-app", .needsAttention, .question, title: "Fix the settings form",
                    detail: "Should I also migrate the old snapshots?", context: 41, age: 200),
            session("f7", .claude, "/Users/me/learning-app", .needsAttention, .interrupted, title: "Review open issues", context: 22, age: 600),
            session("f3", .claude, "/Users/me/warden", .working, title: "Native menu bar redesign", context: 23, age: 5),
            session("f4", .codex, "/Users/me/site", .working, title: "Fix header layout", context: 88, age: 30),
            session("f5", .claude, "/Users/me/notes", .finished, title: "Summarize meeting", age: 1500),
            session("f6", .codex, "/Users/me/api", .idle, age: 4000)
        ]
        fixture.windows = [
            UsageWindow(id: "Claude-five_hour", provider: .claude, label: "5h", usedPercent: 71,
                        resetsAt: now.addingTimeInterval(7200), observedAt: now, evidence: .provider),
            UsageWindow(id: "Claude-seven_day", provider: .claude, label: "7d", usedPercent: 62,
                        resetsAt: now.addingTimeInterval(2 * 86_400), observedAt: now, evidence: .provider),
            UsageWindow(id: "Codex-primary", provider: .codex, label: "7d", usedPercent: 10,
                        resetsAt: now.addingTimeInterval(5 * 86_400), observedAt: now.addingTimeInterval(-7200),
                        evidence: .localLog, minutes: 10_080),
            UsageWindow(id: "Claude-fable", provider: .claude, label: "7d", usedPercent: 94,
                        resetsAt: now.addingTimeInterval(2 * 86_400), observedAt: now, evidence: .provider,
                        minutes: 10_080, scope: "Fable")
        ]
        return fixture
    }
}
#endif
