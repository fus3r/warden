import Charts
import SwiftUI
import WardenCore

/// How agents spent a day: when each session worked, when it waited for you, and how quickly you answered.
struct ActivityReportView: View {
    /// Spans that ended and spans still open, in any order.
    let spans: [ActivitySpan]
    /// Titles of sessions Warden lists now. Past sessions show their folder.
    var titles: [String: String] = [:]
    var now = Date()
    @State private var dayOffset = 0

    private static let lanes = 14
    private static let laneHeight: CGFloat = 24
    private var calendar: Calendar { Calendar.current }
    private var dayStart: Date {
        calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: now)) ?? now
    }
    private var dayEnd: Date { min(now, calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now) }
    private var daySpans: [ActivitySpan] { spans.filter { $0.end > dayStart && $0.start < dayEnd } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Day", selection: $dayOffset) {
                    ForEach(0..<7, id: \.self) { offset in
                        Text(offset == 0 ? "Today" : offset == 1 ? "Yesterday"
                             : (calendar.date(byAdding: .day, value: -offset, to: now) ?? now).formatted(.dateTime.weekday(.wide).day().month()))
                            .tag(offset)
                    }
                }.labelsHidden().frame(maxWidth: 220)
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    let summary = ActivitySummary(spans, from: dayStart, to: dayEnd)
                    if daySpans.isEmpty {
                        ContentUnavailableView("No agent activity recorded", systemImage: "timeline.selection",
                                               description: Text("Warden records when sessions work and when they wait for you, from the moment it runs."))
                            .frame(height: 220)
                    } else {
                        tiles(summary)
                        timeline
                        waits(summary)
                    }
                    Divider()
                    week
                    Divider()
                    Text("From the states Warden reads every eight seconds: hooks, session logs, and Claude Code's session list. A final question is recognized by a heuristic, so a few waits may be missed or added. Only times, states, project folders, and tool names are kept, for 30 days.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Summary

    private func tiles(_ summary: ActivitySummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
            GridRow {
                tile("Agent work", Self.duration(summary.working),
                     detail: "\(Self.duration(summary.busy)) with at least one agent working")
                tile("Waiting for you", Self.duration(summary.waiting),
                     detail: summary.waits == 0 ? "No waits" : "\(summary.waits) \(summary.waits == 1 ? "time" : "times")\(summary.medianWait.map { ", median \(Self.duration($0))" } ?? "")")
                tile("Autonomy", summary.autonomy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–",
                     detail: "Share of agent time spent working rather than waiting")
            }
        }
    }

    private func tile(_ title: String, _ value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Timeline

    private struct Lane: Identifiable {
        let id: String
        let name: String
        let spans: [ActivitySpan]
    }

    /// One row per session, busiest first, named by title when Warden lists the session and by folder otherwise.
    private var lanes: [Lane] {
        let grouped = Dictionary(grouping: daySpans, by: \.session)
        let ordered = grouped.sorted { left, right in
            let a = left.value.reduce(0) { $0 + $1.duration }, b = right.value.reduce(0) { $0 + $1.duration }
            return a != b ? a > b : left.key < right.key
        }
        var used: [String: Int] = [:]
        return ordered.prefix(Self.lanes).map { id, spans in
            var name = titles[id] ?? Self.folder(spans.first?.project ?? "")
            name = String(name.prefix(34))
            used[name, default: 0] += 1
            if used[name]! > 1 { name += " (\(used[name]!))" }
            return Lane(id: id, name: name, spans: spans)
        }
    }

    private var timeline: some View {
        let lanes = self.lanes
        let from = max(dayStart, (daySpans.map(\.start).min() ?? dayStart).addingTimeInterval(-600))
        let to = min(dayEnd, (daySpans.map(\.end).max() ?? dayEnd).addingTimeInterval(600))
        let hidden = Set(daySpans.map(\.session)).count - lanes.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Timeline").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                // Lane names sit in their own column, each as tall as its lane in the plot.
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(lanes) { lane in
                        Text(lane.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            .frame(height: Self.laneHeight)
                    }
                }
                .frame(width: 170, alignment: .trailing)
                Chart {
                    ForEach(lanes) { lane in
                        ForEach(Array(lane.spans.enumerated()), id: \.offset) { _, span in
                            RectangleMark(xStart: .value("Start", max(span.start, from)), xEnd: .value("End", min(span.end, to)),
                                          y: .value("Session", lane.id), height: .fixed(Self.laneHeight * 0.55))
                                .foregroundStyle(by: .value("State", Self.label(span.kind)))
                                .cornerRadius(3)
                        }
                    }
                }
                .chartForegroundStyleScale(domain: ["Working", "Waiting for you", "Waiting for a limit"],
                                           range: [ChartPalette.slot(0), ChartPalette.slot(1), ChartPalette.neutral])
                .chartXScale(domain: from...max(to, from.addingTimeInterval(1800)))
                .chartYScale(domain: lanes.map(\.id))
                .chartYAxis(.hidden)
                .chartPlotStyle { $0.frame(height: CGFloat(lanes.count) * Self.laneHeight) }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .accessibilityLabel("Timeline of \(lanes.count) sessions: working and waiting spans")
            }
            if hidden > 0 {
                Text("\(hidden) quieter \(hidden == 1 ? "session is" : "sessions are") not shown.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Waits

    private func waits(_ summary: ActivitySummary) -> some View {
        let kinds: [(AttentionKind, String)] = [(.permission, "Approvals"), (.question, "Questions"), (.choice, "Question prompts"),
                                                (.failure, "Errors"), (.interrupted, "Interrupted turns"), (.notification, "Other waits")]
        let byKind = kinds.compactMap { kind, title in summary.waitingByKind[kind].map { (title, $0) } }.filter { $0.1 >= 1 }
        let byProject = summary.waitingByProject.sorted { $0.value > $1.value }.prefix(5)
        return Group {
            if !byKind.isEmpty {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What agents waited for").font(.headline)
                        ForEach(byKind, id: \.0) { title, time in
                            HStack {
                                Text(title)
                                Spacer(minLength: 12)
                                Text(Self.duration(time)).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                        if summary.answeredInWarden > 0 {
                            Text("\(summary.answeredInWarden) answered from Warden's menu or notifications.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where they waited").font(.headline)
                        ForEach(Array(byProject), id: \.key) { project, time in
                            HStack {
                                Text(Self.folder(project)).lineLimit(1).truncationMode(.middle).help(project)
                                Spacer(minLength: 12)
                                Text(Self.duration(time)).monospacedDigit().foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                        if let longest = summary.longestWait {
                            Text("Longest wait: \(Self.duration(longest)).").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    // MARK: Week

    private var week: some View {
        let days: [(date: Date, working: Double, waiting: Double)] = (0..<7).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let summary = ActivitySummary(spans, from: start, to: min(end, now))
            return (start, summary.working / 3600, summary.waiting / 3600)
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 days").font(.headline)
            Chart {
                ForEach(days, id: \.date) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", day.working))
                        .foregroundStyle(by: .value("State", "Working"))
                        .position(by: .value("State", "Working"))
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Hours", day.waiting))
                        .foregroundStyle(by: .value("State", "Waiting for you"))
                        .position(by: .value("State", "Waiting for you"))
                }
            }
            .chartForegroundStyleScale(domain: ["Working", "Waiting for you"], range: [ChartPalette.slot(0), ChartPalette.slot(1)])
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.abbreviated)) }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Double.self).map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "") h") }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 150)
            .accessibilityLabel("Hours of agent work and of waiting for you on each of the last seven days")
        }
    }

    // MARK: Formatting

    private static func label(_ kind: ActivitySpan.Kind) -> String {
        switch kind {
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .limited: return "Waiting for a limit"
        }
    }

    private static func folder(_ path: String) -> String {
        path.isEmpty ? "Unknown project" : URL(fileURLWithPath: path).lastPathComponent
    }

    /// "45 s", "12 min", "3 h 05".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) s" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return String(format: "%d h %02d", Int(seconds / 3600), Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))
    }
}
