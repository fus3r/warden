import AppKit
import Charts
import SwiftUI
import WardenCore

/// Series colors in a fixed order, checked for color vision deficiencies in light and dark mode. A series keeps its
/// color when filters change; past the fifth, series fold into Other, drawn in a neutral gray.
enum ChartPalette {
    private static let light: [UInt32] = [0x2a78d6, 0xeb6834, 0x1baf7a, 0xeda100, 0xe87ba4]
    private static let dark: [UInt32] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181]
    static let count = light.count

    static func slot(_ index: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb((dark ? Self.dark : Self.light)[index % count])
        })
    }

    static let neutral = Color(nsColor: NSColor(name: nil) { _ in rgb(0x898781) })
    static let faint = Color(nsColor: NSColor(name: nil) { appearance in
        rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0x383835 : 0xc3c2b7)
    })

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

/// Where each limit went: every rise the provider reported, split among the projects whose sessions used tokens
/// before it. The currency a subscription is metered in, rather than dollars.
struct LimitsReportView: View {
    let quota: QuotaSummary
    var now = Date()
    @AppStorage("limitsWindow") private var windowID = ""
    @AppStorage("showAPIEquivalent") private var showAPIEquivalent = false
    @State private var days = 30

    private static let other = "Other projects"
    private static let elsewhere = "No local use"

    /// Limits in a steady order: each provider and account, the week before shorter windows, shared before one model.
    private var limits: [UsageWindow] {
        quota.windows.values.sorted {
            ($0.provider.rawValue, $0.account ?? "", -($0.durationMinutes ?? 0), $0.scope ?? "")
                < ($1.provider.rawValue, $1.account ?? "", -($1.durationMinutes ?? 0), $1.scope ?? "")
        }
    }
    private var selected: UsageWindow? { limits.first { $0.id == windowID } ?? limits.first }
    private var firstDay: String { UsageLedger.dayString(Calendar.current.date(byAdding: .day, value: 1 - days, to: now) ?? now) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                if !limits.isEmpty {
                    Picker("Limit", selection: Binding(get: { selected?.id ?? "" }, set: { windowID = $0 })) {
                        ForEach(limits) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 260)
                }
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                Spacer(minLength: 0)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let window = selected {
                        current(window)
                        Divider()
                        byDay(window)
                        capacity(window)
                        past(window)
                    } else {
                        ContentUnavailableView("No limit readings yet", systemImage: "gauge.with.dots.needle.0percent",
                                               description: Text("Warden splits a limit once Claude Code or Codex reports it rising. Keep Claude or Codex limits current in Settings."))
                            .frame(height: 260)
                    }
                    Divider()
                    footnote
                }.padding(20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Current window

    private func current(_ window: UsageWindow) -> some View {
        let period = quota.current[window.id]
        // Shares under a tenth of a point fold into one line, so a quick look at another folder does not crowd the list.
        let all = quota.projects(inCurrent: window.id)
        let small = all.filter { $0.project != nil && $0.points < 0.1 }
        var shares = all.filter { $0.project == nil || $0.points >= 0.1 }
        if !small.isEmpty { shares.append((Self.other, small.reduce(0) { $0 + $1.points })) }
        let unsplit = max(0, (period?.percent ?? 0) - (period?.attributed ?? 0) - (period?.unexplained ?? 0))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Current window").font(.headline)
                Spacer()
                Text(window.hasReset(now: now) ? "Reset \(MenuFormat.time(window.resetsAt!)), awaiting a reading"
                     : window.resetsAt.map { "Resets \(MenuFormat.resetPhrase($0, now: now))" } ?? "")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(window.usedPercent.rounded()))%").font(.system(size: 28, weight: .semibold))
                Text("of \(window.name) used").foregroundStyle(.secondary)
            }
            ShareBar(segments: segments(shares, unsplit: unsplit))
                .frame(height: 14)
                .accessibilityLabel("\(window.name): \(Int(window.usedPercent.rounded())) percent used, split by project below.")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                ForEach(Array(shares.prefix(8).enumerated()), id: \.offset) { _, share in
                    GridRow {
                        Circle().fill(share.project == Self.other ? ChartPalette.neutral : color(for: share.project, window: window.id))
                            .frame(width: 8, height: 8)
                        Text(share.project == Self.other ? "\(Self.other) (\(small.count))" : name(share.project))
                            .lineLimit(1).truncationMode(.middle).help(share.project ?? "")
                        Text(points(share.points)).monospacedDigit().gridColumnAlignment(.trailing)
                        if let perPoint = planPerPoint(window) {
                            Text("≈" + MenuFormat.cost(share.points * perPoint)).monospacedDigit().foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                        Text(share.project == nil ? "Web, phone, or another computer" : "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if unsplit >= 0.5 {
                    GridRow {
                        Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 8, height: 8)
                        Text("Before Warden timed use")
                        Text(points(unsplit)).monospacedDigit()
                        if let perPoint = planPerPoint(window) {
                            Text("≈" + MenuFormat.cost(unsplit * perPoint)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text("Reached before this window's use could be split").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.font(.callout)
            if shares.isEmpty && unsplit < 0.5 {
                Text("No rise of this limit has been split yet. Warden splits each rise once the provider reports it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            plan(window)
            exchange(window, period: period)
        }
    }

    /// Dollars of the plan one point of this limit stands for, when you entered its price in Settings.
    private func planPerPoint(_ window: UsageWindow) -> Double? { PlanPrice.perPoint(window, prices: MenuFormat.planPrices) }

    /// The weekly limit in the money you pay for the plan: used so far, and left.
    @ViewBuilder
    private func plan(_ window: UsageWindow) -> some View {
        if let perPoint = planPerPoint(window), let monthly = MenuFormat.planPrices[PlanPrice.key(window)] {
            let used = window.hasReset(now: now) ? 0 : window.usedPercent
            VStack(alignment: .leading, spacing: 3) {
                Text("Your plan costs \(MenuFormat.cost(monthly)) a month, so \(MenuFormat.cost(perPoint * 100)) a week. This window has used \(MenuFormat.cost(used * perPoint)) of it so far; \(MenuFormat.cost(max(0, 100 - used) * perPoint)) is not used yet.")
                Text("Each point of the weekly limit stands for a hundredth of the week's price, from the price you entered in Settings → Usage.")
                    .foregroundStyle(.secondary)
            }.font(.callout)
        } else if PlanPrice.applies(to: window) {
            Text("Enter your plan's monthly price in Settings → Usage to see this limit in the money you pay for it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// What one point of this limit is worth at API list prices, when those prices are shown at all.
    @ViewBuilder
    private func exchange(_ window: UsageWindow, period: QuotaPeriod?) -> some View {
        let rate = quota.exchange(window: window.id)
        if let value = rate.current {
            if showAPIEquivalent {
                VStack(alignment: .leading, spacing: 3) {
                    Text("1 point ≈ \(MenuFormat.cost(value)) of use at API list prices, so the whole window ≈ \(MenuFormat.cost(value * 100)).")
                    if let typical = rate.typical {
                        let ratio = value / typical
                        Text(abs(ratio - 1) < 0.15 ? "In line with past windows (\(MenuFormat.cost(typical)) per point)."
                             : "Past windows gave \(MenuFormat.cost(typical)) per point: this one \(ratio < 1 ? "drains faster" : "lasts longer") for the same use.")
                    }
                    if let perPoint = planPerPoint(window), perPoint > 0 {
                        Text("That is \((value / perPoint).formatted(.number.precision(.fractionLength(0...1))))× what a point costs on your plan.")
                    }
                    Text("An estimate from \(points(period?.pricedPoints ?? 0)) split among priced models. Not a bill: a comparison with pay-as-you-go prices.")
                        .foregroundStyle(.secondary)
                }.font(.callout)
            } else {
                Text("Turn on API price equivalents in Settings → Usage to see what a point of this limit is worth at API prices.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: By day

    private func byDay(_ window: UsageWindow) -> some View {
        let calendar = Calendar.current
        let dates = (0..<days).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: calendar.startOfDay(for: now)) }
        let keys = dates.map { UsageLedger.dayString($0) }
        let daily = quota.daily(window: window.id, days: keys)
        let ranked = rankedProjects(window.id)
        let rows: [(date: Date, series: String, points: Double)] = zip(dates, keys).flatMap { date, key in
            var grouped: [String: Double] = [:]
            for (project, value) in daily[key] ?? [:] { grouped[seriesName(project, ranked: ranked), default: 0] += value }
            return grouped.map { (date, $0.key, $0.value) }
        }
        let series = (ranked.prefix(ChartPalette.count).map(name) + [Self.other, Self.elsewhere]).filter { name in rows.contains { $0.series == name } }
        let total = rows.reduce(0) { $0 + $1.points }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("By day").font(.headline)
                Spacer()
                // Days and periods add points of successive windows, so the total is no share of one window.
                Text("\(total.formatted(.number.precision(.fractionLength(0...1)))) points of \(window.name) windows in \(days) days")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .help("A point is 1% of one window. A day can take points of several \(window.shortLabel) windows, and a period of several weeks.")
            }
            if rows.isEmpty {
                Text("No split rises in this period.").font(.callout).foregroundStyle(.secondary).frame(height: 60)
            } else {
                Chart {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        BarMark(x: .value("Day", row.date, unit: .day), y: .value("Points", row.points))
                            .foregroundStyle(by: .value("Project", row.series))
                    }
                }
                .chartForegroundStyleScale(domain: series, range: series.map { seriesColor($0, ranked: ranked) })
                .chartLegend(position: .bottom, alignment: .leading)
                .chartXScale(domain: (dates.first ?? now)...(calendar.date(byAdding: .day, value: 1, to: dates.last ?? now) ?? now),
                             range: .plotDimension(padding: 20))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: days == 7 ? 1 : days == 30 ? 7 : 21)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Double.self).map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "")%") }
                    }
                }
                .frame(height: 180)
                .accessibilityLabel("Points of \(window.name) per day over \(days) days, by project")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(Array(quota.projects(window: window.id, firstDay: firstDay).filter { $0.points >= 0.1 }.prefix(6).enumerated()),
                            id: \.offset) { _, share in
                        GridRow {
                            Text(name(share.project)).lineLimit(1).truncationMode(.middle).help(share.project ?? "")
                            Text(points(share.points)).monospacedDigit().gridColumnAlignment(.trailing)
                            if let perPoint = planPerPoint(window) {
                                Text("≈" + MenuFormat.cost(share.points * perPoint)).monospacedDigit().foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                            }
                        }
                    }
                }.font(.callout)
            }
        }
    }

    // MARK: Capacity

    /// What a point of the limit bought in each window: the API list value of the use it was split among, against the
    /// median of past windows. A provider that tightens a limit shows as a lower bar for the same kind of use.
    @ViewBuilder
    private func capacity(_ window: UsageWindow) -> some View {
        let past = quota.finished.filter { $0.window == window.id && $0.dollarsPerPoint != nil }.suffix(8)
        let rate = quota.exchange(window: window.id)
        if past.count >= 2, let typical = rate.typical, typical > 0 {
            // Short windows end several times a day, so their bars carry the hour.
            let short = (window.durationMinutes ?? 0) < 1440
            let bars: [(label: String, value: Double, current: Bool)] = past.enumerated().map { index, period in
                let label = period.resetsAt.map { short ? $0.formatted(.dateTime.day().month(.abbreviated).hour()) : $0.formatted(.dateTime.day().month(.abbreviated)) }
                return (label ?? "#\(index + 1)", period.dollarsPerPoint! / typical, false)
            } + (rate.current.map { [("Now", $0 / typical, true)] } ?? [])
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("What a point buys").font(.headline)
                    Spacer()
                    if let now = rate.current {
                        Text("This window: \((now / typical).formatted(.percent.precision(.fractionLength(0)))) of usual")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                        BarMark(x: .value("Window", bar.label), y: .value("Of usual", bar.value * 100))
                            .foregroundStyle(bar.current ? ChartPalette.slot(1) : ChartPalette.slot(0))
                    }
                    RuleMark(y: .value("Usual", 100)).foregroundStyle(ChartPalette.neutral).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Double.self).map { Int($0.rounded()) } ?? 0)%") }
                    }
                }
                .frame(height: 140)
                .accessibilityLabel("Use a point of \(window.name) bought in each window, relative to past windows")
                Text(showAPIEquivalent
                     ? "Each bar is the API list value of the use a point was split among, against the median of past windows, \(MenuFormat.cost(typical)) a point. A lower bar means the limit filled faster for the same value: the provider may have tightened it, or the use differed, such as other models or colder caches."
                     : "Each bar is the use a point was split among, weighted at API list prices, against the median of past windows. A lower bar means the limit filled faster for the same use: the provider may have tightened it, or the use differed, such as other models or colder caches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Past windows

    @ViewBuilder
    private func past(_ window: UsageWindow) -> some View {
        let finished = quota.finished.filter { $0.window == window.id }.suffix(6).reversed()
        if !finished.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Past windows").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Ended")
                        Text("Peak").gridColumnAlignment(.trailing)
                        Text("Largest share")
                        if planPerPoint(window) != nil { Text("Plan value used").gridColumnAlignment(.trailing) }
                        if showAPIEquivalent { Text("Per point").gridColumnAlignment(.trailing) }
                    }.foregroundStyle(.secondary)
                    ForEach(Array(finished.enumerated()), id: \.offset) { _, period in
                        GridRow {
                            Text(period.resetsAt.map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) } ?? "–")
                            Text("\(Int(period.percent.rounded()))%").monospacedDigit()
                            Text(period.projects.max(by: { $0.value < $1.value }).map { "\(name($0.key)) \(points($0.value))" } ?? "–")
                                .lineLimit(1).truncationMode(.middle)
                            if let perPoint = planPerPoint(window) {
                                Text("\(MenuFormat.cost(period.percent * perPoint)) of \(MenuFormat.cost(perPoint * 100))").monospacedDigit()
                            }
                            if showAPIEquivalent { Text(period.dollarsPerPoint.map(MenuFormat.cost) ?? "–").monospacedDigit() }
                        }
                    }
                }.font(.callout)
            }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("How this works: each time Claude Code or Codex reports a higher percentage, Warden splits the rise among the sessions that used tokens since the previous rise, in proportion to their API list price. A rise with no local use counts as No local use: the web, the phone, or another computer. Use after a window's last reading is never guessed.")
            Text("These are estimates. Providers report only the account's total; they do not say what each session used.")
            if let coverage = quota.coverage {
                Text("Timed local use starts \(coverage.formatted(date: .abbreviated, time: .shortened)). Kept on this Mac for 90 days, with project folders and no conversation text.")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Helpers

    /// Projects ranked by their points in this limit over everything kept, so a project keeps its color when the
    /// period changes.
    private func rankedProjects(_ window: String) -> [String] {
        let all = quota.projects(window: window, firstDay: "")
        let total = all.reduce(0) { $0 + $1.points }
        return all.filter { $0.points >= total / 100 }.compactMap(\.project)
    }

    private func seriesName(_ project: String?, ranked: [String]) -> String {
        guard let project else { return Self.elsewhere }
        return ranked.prefix(ChartPalette.count).contains(project) ? name(project) : Self.other
    }

    private func seriesColor(_ series: String, ranked: [String]) -> Color {
        if series == Self.other { return ChartPalette.neutral }
        if series == Self.elsewhere { return ChartPalette.faint }
        return ChartPalette.slot(ranked.prefix(ChartPalette.count).map(name).firstIndex(of: series) ?? 0)
    }

    private func color(for project: String?, window: String) -> Color {
        let ranked = rankedProjects(window)
        return seriesColor(seriesName(project, ranked: ranked), ranked: ranked)
    }

    private func segments(_ shares: [(project: String?, points: Double)], unsplit: Double) -> [ShareBar.Segment] {
        let window = selected?.id ?? ""
        var list = shares.map { share in
            ShareBar.Segment(value: share.points,
                             color: share.project == Self.other ? ChartPalette.neutral : color(for: share.project, window: window))
        }
        if unsplit > 0 { list.append(ShareBar.Segment(value: unsplit, color: Color.secondary.opacity(0.35))) }
        return list
    }

    private func name(_ project: String?) -> String {
        guard let project else { return Self.elsewhere }
        return project.isEmpty ? "Unknown project" : URL(fileURLWithPath: project).lastPathComponent
    }

    private func points(_ value: Double) -> String { MenuFormat.points(value) }
}

/// A limit's used share, 0 to 100, split into colored segments with a hairline gap between them.
struct ShareBar: View {
    struct Segment {
        var value: Double
        var color: Color
    }

    let segments: [Segment]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle().fill(segment.color)
                            .frame(width: max(1, geometry.size.width * min(100, segment.value) / 100 - 2))
                    }
                }
                .clipShape(Capsule())
            }
        }
    }
}
