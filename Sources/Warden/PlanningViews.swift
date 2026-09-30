import Charts
import SwiftUI
import WardenCore

struct WorkPlannerView: View {
    @ObservedObject var store: WardenStore
    var openPowerSettings: () -> Void = {}

    var body: some View {
        TimelineView(.everyMinute) { _ in
            WorkPlannerReport(windows: store.windows, tracker: store.paceTracker, sessions: store.sessions,
                              now: Date(), scannedAt: store.scannedAt, power: store.keepAwake,
                              openPowerSettings: openPowerSettings, refresh: { store.refresh(usage: true) },
                              openSession: { store.open(sessionID: $0) })
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct WorkPlannerReport: View {
    let windows: [UsageWindow]
    let tracker: UsagePaceTracker
    let sessions: [AgentSession]
    let now: Date
    var scannedAt: Date? = nil
    var power: KeepAwake? = nil
    var openPowerSettings: () -> Void = {}
    var refresh: () -> Void = {}
    var openSession: (String) -> Void = { _ in }
    @AppStorage("plannerMinutes") private var minutes = 60
    @AppStorage("plannerPaceMultiplier") private var paceMultiplier = 1.0
    @AppStorage("plannerReservePercent") private var reservePercent = 0.0
    @AppStorage("contextThreshold") private var threshold = 85.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Plan the next").font(.headline)
                Picker("Session duration", selection: $minutes) {
                    Text("30 min").tag(30)
                    Text("60 min").tag(60)
                    Text("120 min").tag(120)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                Spacer()
                Button("Refresh Limits", action: refresh)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DepartureReviewView(review: DepartureReview(sessions: sessions, windows: windows, scannedAt: scannedAt,
                                                                 minutes: minutes, contextThreshold: threshold, now: now),
                                        now: now, openSession: openSession)
                    if let power { DeparturePowerRow(keepAwake: power, openSettings: openPowerSettings) }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 20) {
                            Picker("Work pace", selection: $paceMultiplier) {
                                Text("Half the recent pace").tag(0.5)
                                Text("Recent pace").tag(1.0)
                                Text("Twice the recent pace").tag(2.0)
                            }
                            Picker("Keep unused", selection: $reservePercent) {
                                Text("No margin").tag(0.0)
                                Text("10% of each limit").tag(10.0)
                                Text("20% of each limit").tag(20.0)
                            }
                        }
                        Text("Try a busier task or leave some quota for later. These are scenarios; Warden cannot reserve or enforce a margin.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    let routes = WorkRoute.all(in: windows)
                    if routes.isEmpty {
                        ContentUnavailableView("No quota readings yet", systemImage: "gauge.with.dots.needle.0percent",
                                               description: Text("Use Claude Code or Codex, or enable current account limits in Settings."))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(routes) { route in
                                PlanningRouteRow(route: route, plan: WorkPlan(route: route, tracker: tracker, minutes: minutes, now: now,
                                                                             paceMultiplier: paceMultiplier, reservePercent: reservePercent),
                                                 minutes: minutes, now: now, paceMultiplier: paceMultiplier, reservePercent: reservePercent)
                                if route.id != routes.last?.id { Divider().padding(.vertical, 14) }
                            }
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("How to read this", systemImage: "info.circle").font(.callout.weight(.semibold))
                        Text("Shared limits apply across models. Model rows also check the shared limits for that account. Only limits the provider reports can be checked.")
                        Text("Estimates use at least three readings over ten minutes, with a measurable quota change. They include recent activity on the account, which may include other devices. Different tasks or models can change the pace.")
                        Text("A reset or long gap starts a new sample. Warden cannot predict capacity after a reset, extra paid usage, or banked resets. These checks do not start work or switch accounts.")
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }

}

private struct PlanningRouteRow: View {
    let route: WorkRoute
    let plan: WorkPlan
    let minutes: Int
    let now: Date
    let paceMultiplier: Double
    let reservePercent: Double
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var warning: Bool {
        switch plan.status {
        case .limitReached, .atRisk, .reserveReached, .reserveAtRisk: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(route.title).font(.headline)
                Spacer()
                Text(outcome).font(.callout.weight(.medium))
                    .foregroundStyle(warning ? warningColor : Color.primary)
            }
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            if let projected = plan.checks.compactMap(\.projectedUsedPercent).max(),
               plan.status == .withinObservedPace {
                Text("Tightest margin at the end: ≈\(max(0, Int((100 - projected).rounded(.down))))% left")
                    .font(.caption).monospacedDigit()
            }
            DisclosureGroup("Readings and estimate", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.checks) { check in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(check.window.name).fontWeight(.medium)
                                Spacer()
                                Text("\(max(0, 100 - Int(check.window.usedPercent.rounded())))% left at last reading")
                                    .monospacedDigit()
                            }
                            Text(evidence(check)).foregroundStyle(.secondary)
                            if check.observations.count >= 2 {
                                observationChart(check)
                            }
                            if let projected = check.projectedUsedPercent {
                                Text(projected >= 100
                                     ? "Scenario reaches 100% within this session · target ≤\(Int(100 - reservePercent))%"
                                     : "Scenario at the end: ≈\(Int(projected.rounded()))% used · target ≤\(Int(100 - reservePercent))%")
                                    .monospacedDigit()
                            }
                        }.font(.caption)
                    }
                }.padding(.top, 8)
            }.font(.caption)
        }
    }

    private var outcome: String {
        switch plan.status {
        case .limitReached: return "Limit reached"
        case .reserveReached: return "Already within your margin"
        case .needsRefresh: return "Updated reading needed"
        case .atRisk(let date):
            return date <= now ? "May already be at the limit" : "May run out in ≈\(Int(ceil(date.timeIntervalSince(now) / 60))) min"
        case .reserveAtRisk(let date):
            return date <= now ? "Margin may already be reached" : "Margin reached in ≈\(Int(ceil(date.timeIntervalSince(now) / 60))) min"
        case .resetDuringSession: return "Reset during this session"
        case .learning: return "Pace not available yet"
        case .withinObservedPace: return "\(minutes) min within your target"
        }
    }

    private var explanation: String {
        let limit = plan.limitingWindow?.name ?? "This account"
        switch plan.status {
        case .limitReached:
            return "\(limit) was reported at 100%. Check its reset before starting a long task."
        case .reserveReached:
            return "\(limit) has at most \(Int(reservePercent))% left at the last reading. This is your chosen margin, not a provider block."
        case .needsRefresh:
            return "\(limit) is old or its reset time has passed. Refresh to check the current window."
        case .atRisk:
            return "\(limit) is the earliest projected constraint at \(paceDescription). Try a shorter session and inspect the readings."
        case .reserveAtRisk:
            return "\(limit) would reach your \(Int(reservePercent))% margin first at \(paceDescription). A shorter session could leave room for later."
        case .resetDuringSession(let reset):
            return "The provider reports a reset \(MenuFormat.resetPhrase(reset, now: now)). Capacity after that reset is not yet known."
        case .learning:
            return "Quota is available, but there is not enough recent change to estimate this duration."
        case .withinObservedPace:
            return "Scenario at \(paceDescription)\(reservePercent > 0 ? ", keeping \(Int(reservePercent))% unused" : ""). Actual work can consume quota differently."
        }
    }

    private var paceDescription: String {
        paceMultiplier == 1 ? "the recent pace" : paceMultiplier == 2 ? "twice the recent pace" : "half the recent pace"
    }

    private var warningColor: Color {
        colorScheme == .dark ? .orange : Color(red: 0.55, green: 0.24, blue: 0)
    }

    private func observationChart(_ check: WorkPlan.Check) -> some View {
        Chart {
            ForEach(check.observations, id: \.observedAt) { reading in
                LineMark(x: .value("Reading", reading.observedAt), y: .value("Used %", reading.usedPercent))
                    .foregroundStyle(Color.accentColor)
                PointMark(x: .value("Reading", reading.observedAt), y: .value("Used %", reading.usedPercent))
                    .foregroundStyle(Color.accentColor).symbolSize(14)
            }
            RuleMark(y: .value("Target", 100 - reservePercent))
                .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .chartYScale(domain: 0...max(100, check.observations.map(\.usedPercent).max() ?? 100))
        .chartXScale(range: .plotDimension(padding: 24))
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: 90).padding(.vertical, 5)
        .accessibilityLabel("Observed quota for \(check.window.name). Dashed line: \(Int(100 - reservePercent))% target.")
    }

    private func evidence(_ check: WorkPlan.Check) -> String {
        let window = check.window
        let source = window.evidence == .provider ? "Provider reading" : "Local log"
        var text = "\(source) · \(window.observedAt.formatted(date: .abbreviated, time: .shortened))"
        if let reset = window.resetsAt { text += " · reset \(MenuFormat.resetPhrase(reset, now: now))" }
        if let pace = check.pace {
            text += "\nEstimate: \(pace.pointsPerHour.formatted(.number.precision(.fractionLength(1)))) percentage points/hour across \(pace.sampledMinutes) min (\(pace.sampleCount) readings)."
        } else {
            text += "\nNo usable recent pace sample."
        }
        return text
    }
}
