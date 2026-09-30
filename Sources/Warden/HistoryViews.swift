import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers
import WardenCore

struct UsageHistoryView: View {
    @ObservedObject var store: WardenStore
    @AppStorage("historyEnabled") private var enabled = true
    @AppStorage("activityEnabled") private var activityEnabled = true
    @AppStorage("historyTab") private var tab = "usage"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Report", selection: $tab) {
                Text("Usage").tag("usage")
                Text("Limits").tag("limits")
                Text("Activity").tag("activity")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320)
            .padding(.top, 14).padding(.bottom, 2)
            .help("Usage: tokens by day, project, and model. Limits: where each usage limit went. Activity: when agents worked and waited for you.")
            switch tab {
            case "limits":
                if !enabled { paused } else if let quota = store.quota { TimelineView(.everyMinute) { LimitsReportView(quota: quota, now: $0.date) } }
                else { reading }
            case "activity":
                if activityEnabled {
                    TimelineView(.everyMinute) { context in
                        ActivityReportView(spans: store.activitySpans + store.activity.open.values,
                                           titles: Dictionary(store.sessions.compactMap { session in session.title.map { (session.id, $0) } },
                                                              uniquingKeysWith: { first, _ in first }),
                                           now: context.date)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Activity is not recorded", systemImage: "pause.circle")
                    } description: {
                        Text("Turn on Record agent activity in Settings → Usage to see when agents work and wait for you.")
                    }
                }
            default:
                if !enabled { paused } else if let summary = store.history { HistoryReportView(summary: summary) } else { reading }
            }
        }
        .frame(minWidth: 660, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { store.refreshHistory(soon: true) }
    }

    private var paused: some View {
        ContentUnavailableView {
            Label("Usage history is paused", systemImage: "pause.circle")
        } description: {
            Text("Your saved totals stay on this Mac. Enable history to read new local usage.")
        } actions: {
            Button("Enable Usage History") { store.setHistoryEnabled(true) }
        }
        .frame(maxHeight: .infinity)
    }

    private var reading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading local usage…").font(.headline)
            Text("The first read can take a little longer. Later reads only process new log entries.")
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxHeight: .infinity)
    }
}

/// A native report window: the same selection controls the chart, rankings, totals, and export.
struct HistoryReportView: View {
    let summary: UsageSummary
    @AppStorage("showAPIEquivalent") private var showAPIEquivalent = false
    @AppStorage("historyMetric") private var metricID = HistoryMetric.tokens.rawValue
    @State private var days = 30
    @State private var account: UsageAccount?
    @State private var project: String?
    @State private var selectedDate: Date?
    @State private var exportError: String?

    private var metric: HistoryMetric {
        let chosen = HistoryMetric(rawValue: metricID) ?? .tokens
        return chosen == .apiEquivalent && !showAPIEquivalent ? .tokens : chosen
    }
    private var accountReport: UsageSummary { summary.filtered(to: account) }
    private var report: UsageSummary { accountReport.filtered(project: project) }
    private var detailReport: UsageSummary { report.filtered(day: selectedDay) }
    private var totals: UsageTotals { detailReport.totals(lastDays: days) }
    private var providers: [AgentProvider] {
        AgentProvider.allCases.sorted { $0.rawValue < $1.rawValue }
            .filter { report.totals(lastDays: days, provider: $0).tokens > 0 }
    }
    private var selectedDay: String? {
        guard let date = selectedDate else { return nil }
        let day = UsageLedger.dayString(date)
        return day >= report.firstDay(ofLast: days) && day <= report.today ? day : nil
    }
    private var detailPeriod: String {
        selectedDay.flatMap(MenuFormat.date).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "\(days) days"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                Picker("Account", selection: $account) {
                    Text("All accounts").tag(UsageAccount?.none)
                    ForEach(summary.accounts) { Text($0.title).tag(Optional($0)) }
                }.labelsHidden().frame(maxWidth: 240)
                Spacer(minLength: 0)
                Button(action: exportCSV) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .disabled(totals.tokens == 0)
                    .help("Export \(detailPeriod), with the selected account and project. Contains project paths and counts, without conversation text.")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Picker("Measure", selection: Binding(get: { metric.rawValue }, set: { metricID = $0 })) {
                            Text("Tokens").tag(HistoryMetric.tokens.rawValue)
                            Text("Requests").tag(HistoryMetric.requests.rawValue)
                            if showAPIEquivalent { Text("API equivalent").tag(HistoryMetric.apiEquivalent.rawValue) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: showAPIEquivalent ? 320 : 200)
                        Spacer()
                        Picker("Project", selection: $project) {
                            Text("All projects").tag(String?.none)
                            ForEach(accountReport.projects(lastDays: 90), id: \.name) { group in
                                Text(projectName(group.name)).tag(Optional(group.name))
                            }
                        }.frame(maxWidth: 240).help(project ?? "Filter all views and the export by project")
                    }
                    if metric == .apiEquivalent { priceNotice }
                    if report.totals(lastDays: days).tokens == 0 {
                        ContentUnavailableView("No recorded usage in this period", systemImage: "chart.bar.xaxis",
                                               description: Text("Try another account or a longer period. Web and other-device usage is not included."))
                            .frame(height: 220)
                    } else {
                        chart
                        if selectedDay == nil { periodTable }
                        tokenBreakdown
                        Divider()
                        HStack(alignment: .top, spacing: 28) {
                            ranking("Top projects", detailReport.projects(lastDays: days, metric: metric), projects: true)
                            ranking("Top models", detailReport.models(lastDays: days, metric: metric), projects: false)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Recorded on this Mac. Tokens include cached and repeated input; they do not measure subscription charges.")
                        if let earliest = report.records.map(\.day).min(), let date = MenuFormat.date(earliest) {
                            Text("Earliest retained usage: \(date.formatted(date: .abbreviated, time: .omitted)). Empty days may have no available local records.")
                        }
                        if metric == .apiEquivalent {
                            Link("Standard API prices · checked \(Pricing.verifiedOn)", destination: Pricing.source)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: days) { selectedDate = nil }
        .onChange(of: account) { selectedDate = nil; project = nil }
        .onChange(of: project) { selectedDate = nil }
        .alert("Could not export usage", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var priceNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("API equivalent, not your bill", systemImage: "info.circle").font(.callout.weight(.semibold))
            Text("A comparison at standard API list prices. Subscription fees, extra usage, fast mode, and other billing adjustments are not calculated here.")
            let period = report.totals(lastDays: days)
            if period.unpricedTokens > 0 {
                Text("\(MenuFormat.tokens(period.unpricedTokens)) tokens in this period have no known price and are excluded from dollar amounts.")
                    .fontWeight(.medium)
            }
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var chart: some View {
        let daily = report.daily(lastDays: days)
        let chartProviders = providers.filter { metric != .apiEquivalent || report.totals(lastDays: days, provider: $0).cost > 0 }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(metric == .apiEquivalent ? "Daily API equivalent" : "Daily \(metric.title.lowercased())")
                    .font(.headline)
                Spacer()
                Picker("Inspect day", selection: Binding(get: { selectedDay }, set: { selectedDate = $0.flatMap(MenuFormat.date) })) {
                    Text("All days").tag(String?.none)
                    ForEach(daily.reversed(), id: \.day) { entry in
                        Text(MenuFormat.date(entry.day)!.formatted(date: .abbreviated, time: .omitted)).tag(Optional(entry.day))
                    }
                }.frame(width: 230)
            }
            if let selectedDay, let entry = daily.first(where: { $0.day == selectedDay }) {
                Text(chartProviders.map { "\($0.rawValue) \(amount(entry.byProvider[$0] ?? UsageTotals()))" }.joined(separator: " · "))
                    .font(.callout).monospacedDigit()
            }
            if chartProviders.isEmpty {
                ContentUnavailableView("No known API prices", systemImage: "dollarsign.circle",
                                       description: Text("Choose Tokens or Requests to see all recorded activity."))
                    .frame(height: 180)
            } else {
                Chart {
                    ForEach(daily, id: \.day) { entry in
                        ForEach(chartProviders) { provider in
                            BarMark(x: .value("Day", MenuFormat.date(entry.day)!, unit: .day),
                                    y: .value(metric.title, metric.value(entry.byProvider[provider] ?? UsageTotals())))
                                .foregroundStyle(by: .value("Agent", provider.rawValue))
                                .opacity(selectedDay == nil || selectedDay == entry.day ? 1 : 0.4)
                        }
                    }
                    if let selectedDate {
                        RuleMark(x: .value("Selected day", selectedDate, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                    }
                }
                .chartForegroundStyleScale(domain: chartProviders.map(\.rawValue),
                                           range: chartProviders.map { $0 == .claude ? Color.orange : Color.accentColor })
                .chartLegend(position: .bottom, alignment: .leading)
                .chartXSelection(value: $selectedDate)
                .chartXScale(range: .plotDimension(padding: 24))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: days == 7 ? 1 : days == 30 ? 7 : 21)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            Text(metric == .apiEquivalent ? MenuFormat.cost(value.as(Double.self) ?? 0)
                                 : MenuFormat.tokens(Int(value.as(Double.self) ?? 0)))
                        }
                    }
                }
                .frame(height: 190)
                .accessibilityLabel("Daily \(metric.title.lowercased()) over \(days) days, from local logs")
            }
        }
    }

    private var periodTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 22, verticalSpacing: 8) {
            GridRow {
                Text("Recorded usage").fontWeight(.semibold).gridColumnAlignment(.leading)
                Text("Today")
                Text("7 days")
                if days != 7 { Text("\(days) days") }
            }.foregroundStyle(.secondary)
            ForEach(providers) { provider in
                GridRow {
                    Text(provider.rawValue)
                    Text(amount(report.totals(lastDays: 1, provider: provider)))
                    Text(amount(report.totals(lastDays: 7, provider: provider)))
                    if days != 7 { Text(amount(report.totals(lastDays: days, provider: provider))) }
                }.monospacedDigit()
            }
        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tokenBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Token breakdown · \(detailPeriod)").font(.headline)
                Spacer()
                Text("\(MenuFormat.tokens(totals.tokens)) tokens · \(totals.requests.formatted()) requests")
                    .font(.callout).monospacedDigit()
            }
            if totals.tokens == 0 {
                Text("No local records for this day. This does not establish that the account was unused.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 5) {
                    GridRow {
                        Text("Uncached input")
                        Text("Cache written")
                        Text("Cache read")
                        Text("Output")
                    }.foregroundStyle(.secondary)
                    GridRow {
                        Text(MenuFormat.tokens(totals.usage.input))
                        Text(MenuFormat.tokens(totals.usage.cacheWrite + totals.usage.cacheWriteHour))
                            .help("5-minute writes: \(totals.usage.cacheWrite.formatted()); 1-hour writes: \(totals.usage.cacheWriteHour.formatted())")
                        Text(MenuFormat.tokens(totals.usage.cacheRead))
                        Text(MenuFormat.tokens(totals.usage.output))
                    }.monospacedDigit()
                }.font(.callout)
                if let fraction = totals.cacheReadFraction {
                    Text("\(fraction.formatted(.percent.precision(.fractionLength(0)))) of recorded input came from cache. Reused context counts each time it is read; this percentage does not measure subscription savings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func projectName(_ path: String) -> String {
        path.isEmpty ? "Unknown project" : URL(fileURLWithPath: path).lastPathComponent
    }

    private func ranking(_ title: String, _ groups: [UsageSummary.Group], projects: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(Array(groups.prefix(5).enumerated()), id: \.offset) { _, group in
                HStack(spacing: 12) {
                    Text(projects ? projectName(group.name)
                         : MenuFormat.modelName(group.name))
                        .lineLimit(1).truncationMode(.middle).help(group.name)
                    Spacer(minLength: 0)
                    Text(amount(group.totals)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize()
                }.font(.callout)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func amount(_ totals: UsageTotals) -> String {
        switch metric {
        case .tokens: return MenuFormat.tokens(totals.tokens) + " tok"
        case .requests: return totals.requests.formatted()
        case .apiEquivalent:
            if totals.tokens == 0 { return "–" }
            if totals.unpricedTokens == totals.tokens { return "Unpriced" }
            return "≈" + MenuFormat.cost(totals.cost) + (totals.isFullyPriced ? "" : " + unpriced")
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Warden-usage-\(selectedDay ?? "\(days)d-\(summary.today)").csv"
        panel.title = "Export local usage"
        let csv = detailReport.csv(lastDays: days, includeAPIEquivalent: showAPIEquivalent)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try csv.write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = error.localizedDescription }
        }
    }
}
