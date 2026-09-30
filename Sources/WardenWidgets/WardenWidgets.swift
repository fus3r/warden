import SwiftUI
import WardenCore
import WidgetKit

/// Warden's widgets: what needs you, how many agents work, and the limits, from the snapshot the app writes.
@main
struct WardenWidgets: WidgetBundle {
    var body: some Widget { StatusWidget() }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "status", provider: Provider()) { entry in
            StatusView(entry: entry)
                .containerBackground(for: .widget) { Night.background }
        }
        .configurationDisplayName("Warden")
        .description("Sessions that need you, agents at work, and your usage limits.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct Provider: TimelineProvider {
    /// The widget runs in a sandbox whose home is its container, so the real one comes from the user record. The
    /// sandbox lets it read Warden's widget folder and nothing else.
    private var file: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let preview = Bundle.main.bundleIdentifier?.contains("Preview") ?? false
        return WidgetSnapshot.folder(home: URL(fileURLWithPath: home), preview: preview).appendingPathComponent(WidgetSnapshot.fileName)
    }

    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: .sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let snapshot = WidgetSnapshot.read(from: file)
        completion(Entry(date: Date(), snapshot: context.isPreview ? snapshot ?? .sample : snapshot))
    }

    /// Entries every five minutes for an hour keep ages and reset times moving. Warden asks for a new timeline when
    /// what it shows changes, and every quarter hour while it runs.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snapshot = WidgetSnapshot.read(from: file)
        let now = Date()
        let entries = (0...12).map { Entry(date: now.addingTimeInterval(Double($0) * 300), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

extension WidgetSnapshot {
    static let sample = WidgetSnapshot(
        needsYou: [Item(session: "", agent: "Claude", project: "example-app", reason: "Wants to use Bash", since: Date().addingTimeInterval(-120)),
                   Item(session: "", agent: "Codex", project: "learning-app", reason: "Asked a question", since: Date().addingTimeInterval(-600))],
        working: ["warden", "site"],
        limits: [Limit(name: "Claude 5h", used: 71, resetsAt: Date().addingTimeInterval(7200), minutes: 300, urgent: false),
                 Limit(name: "Claude 7d", used: 62, resetsAt: Date().addingTimeInterval(2 * 86_400), minutes: 10_080, urgent: false),
                 Limit(name: "Codex 7d", used: 40, resetsAt: Date().addingTimeInterval(4 * 86_400), minutes: 10_080, urgent: false)],
        updatedAt: Date())
}

// MARK: Views

/// The app icon's night sky and lantern light.
enum Night {
    static let top = Color(red: 0.15, green: 0.22, blue: 0.43)
    static let bottom = Color(red: 0.04, green: 0.07, blue: 0.17)
    static let metal = Color(red: 0.98, green: 0.95, blue: 0.89)
    static let flame = Color(red: 1, green: 0.71, blue: 0.3)
    static let background = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct StatusView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private var scheme: String { Bundle.main.bundleIdentifier?.contains("Preview") == true ? "warden-preview" : "warden" }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
                    // Warden has not written for a while: it quit, or the Mac slept.
                    .opacity(entry.date.timeIntervalSince(snapshot.updatedAt) > 1800 ? 0.55 : 1)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    LanternGlyph(glow: .idle, height: 26)
                    Spacer(minLength: 0)
                    Text("Open Warden to see your agents here.").font(.system(size: 13)).foregroundStyle(Night.metal.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(.white)
        .widgetURL(URL(string: "\(scheme)://open"))
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        switch family {
        case .systemSmall: small(snapshot)
        case .systemLarge: large(snapshot)
        default: medium(snapshot)
        }
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LanternGlyph(glow: glow(snapshot), height: 26)
            Spacer(minLength: 0)
            Text(headline(snapshot)).font(.system(size: 16, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
            Text(detail(snapshot)).font(.system(size: 12)).foregroundStyle(Night.metal.opacity(0.75)).lineLimit(2)
            if let limit = fullest(snapshot, 1).first {
                LimitRow(limit: limit, date: entry.date, compact: true).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LanternGlyph(glow: glow(snapshot), height: 22)
                    Text(headline(snapshot)).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                if snapshot.needsYou.isEmpty {
                    workingRows(snapshot, limit: 3)
                    Spacer(minLength: 0)
                } else {
                    items(snapshot, limit: 3)
                    Spacer(minLength: 0)
                    if !snapshot.working.isEmpty { workingLine(snapshot) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(fullest(snapshot, 3).enumerated()), id: \.offset) { _, limit in
                    LimitRow(limit: limit, date: entry.date, compact: false)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 128)
        }
    }

    private func large(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                LanternGlyph(glow: glow(snapshot), height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(snapshot)).font(.system(size: 17, weight: .bold))
                    Text(snapshot.needsYou.isEmpty && !snapshot.working.isEmpty ? "Nothing needs you" : detail(snapshot))
                        .font(.system(size: 12)).foregroundStyle(Night.metal.opacity(0.75)).lineLimit(1)
                }
            }
            if snapshot.needsYou.isEmpty { workingRows(snapshot, limit: 5) } else { items(snapshot, limit: 5) }
            Spacer(minLength: 0)
            ForEach(Array(fullest(snapshot, 5).enumerated()), id: \.offset) { _, limit in
                LimitRow(limit: limit, date: entry.date, compact: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func items(_ snapshot: WidgetSnapshot, limit: Int) -> some View {
        ForEach(Array(snapshot.needsYou.prefix(limit).enumerated()), id: \.offset) { _, item in
            Link(destination: URL(string: "\(scheme)://session/\(item.session)") ?? URL(fileURLWithPath: "/")) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Self.age(item.since, at: entry.date)).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Night.metal.opacity(0.7))
                    }
                    Text(item.reason).font(.system(size: 11)).foregroundStyle(Night.flame).lineLimit(1)
                }
            }
        }
        if snapshot.needsYou.count > limit {
            Text("and \(snapshot.needsYou.count - limit) more").font(.system(size: 11)).foregroundStyle(Night.metal.opacity(0.7))
        }
    }

    /// The folders at work, when nothing needs you.
    @ViewBuilder
    private func workingRows(_ snapshot: WidgetSnapshot, limit: Int) -> some View {
        ForEach(Array(snapshot.working.prefix(limit).enumerated()), id: \.offset) { _, project in
            HStack(spacing: 7) {
                Circle().fill(Night.flame).frame(width: 6, height: 6)
                Text(project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
        }
        if snapshot.working.count > limit {
            Text("and \(snapshot.working.count - limit) more").font(.system(size: 11)).foregroundStyle(Night.metal.opacity(0.7))
        }
    }

    private func workingLine(_ snapshot: WidgetSnapshot) -> some View {
        Text("\(snapshot.working.count == 1 ? "1 agent" : "\(snapshot.working.count) agents") working")
            .font(.system(size: 11)).foregroundStyle(Night.metal.opacity(0.75))
    }

    /// The fullest limits, in the menu's order so rows do not swap places as they fill.
    private func fullest(_ snapshot: WidgetSnapshot, _ count: Int) -> [WidgetSnapshot.Limit] {
        snapshot.limits.enumerated().sorted { $0.element.used > $1.element.used }.prefix(count)
            .sorted { $0.offset < $1.offset }.map(\.element)
    }

    private func glow(_ snapshot: WidgetSnapshot) -> LanternGlyph.Glow {
        !snapshot.needsYou.isEmpty ? .attention : snapshot.working.isEmpty ? .idle : .working
    }

    private func headline(_ snapshot: WidgetSnapshot) -> String {
        switch snapshot.needsYou.count {
        case 0: return snapshot.working.isEmpty ? "All quiet" : snapshot.working.count == 1 ? "1 agent working" : "\(snapshot.working.count) agents working"
        case 1: return "1 needs you"
        default: return "\(snapshot.needsYou.count) need you"
        }
    }

    /// Which folders the headline counts.
    private func detail(_ snapshot: WidgetSnapshot) -> String {
        if !snapshot.needsYou.isEmpty {
            var seen = Set<String>()
            let folders = snapshot.needsYou.map(\.project).filter { seen.insert($0).inserted }
            let working = snapshot.working.isEmpty ? "" : ", \(snapshot.working.count) working"
            return ListFormatter.localizedString(byJoining: folders) + working
        }
        return snapshot.working.isEmpty ? "No agent is working" : ListFormatter.localizedString(byJoining: snapshot.working)
    }

    /// "now", "4 min", "2 h", as in the menu.
    static func age(_ date: Date, at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }
}

/// A limit with its bar, the even-pace tick, and its reset.
struct LimitRow: View {
    let limit: WidgetSnapshot.Limit
    let date: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(limit.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(Int(limit.used.rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Night.metal.opacity(0.18))
                    Capsule().fill(limit.urgent ? Night.flame : Night.metal.opacity(0.85))
                        .frame(width: geometry.size.width * min(1, max(0, limit.used / 100)))
                    if let pace = limit.pace(at: date) {
                        Rectangle().fill(Color.white.opacity(0.7)).frame(width: 1.5, height: 8)
                            .offset(x: geometry.size.width * pace - 0.75)
                    }
                }
            }
            .frame(height: 4)
            if !compact, let reset = limit.resetsAt {
                Text(Self.reset(reset, at: date)).font(.system(size: 10)).foregroundStyle(Night.metal.opacity(0.65))
            }
        }
    }

    /// "Resets in 42 min", "Resets in 2 h 05", "Resets Friday".
    static func reset(_ date: Date, at now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "Reset" }
        if seconds < 3600 { return "Resets in \(max(1, Int(seconds / 60))) min" }
        if seconds < 86_400 { return String(format: "Resets in %d h %02d", Int(seconds / 3600), Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) }
        return "Resets \(date.formatted(.dateTime.weekday(.wide)))"
    }
}

/// The menu bar's lantern on a 12 by 16 grid: unlit when nothing works, lit while an agent works, and solid with a mark
/// when one needs you.
struct LanternGlyph: View {
    enum Glow { case idle, working, attention }
    let glow: Glow
    let height: CGFloat

    var body: some View {
        let scale = height / 16
        ZStack {
            LanternPart(part: .ring).stroke(Night.metal, lineWidth: 1.25 * scale)
            LanternPart(part: .roof).fill(Night.metal)
            LanternPart(part: .base).fill(Night.metal)
            switch glow {
            case .attention:
                LanternPart(part: .markedGlass)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.9, blue: 0.62), Night.flame, Color(red: 0.92, green: 0.46, blue: 0.15)],
                                         startPoint: .top, endPoint: .bottom), style: FillStyle(eoFill: true))
                    .shadow(color: Night.flame.opacity(0.6), radius: 4 * scale)
            case .working:
                LanternPart(part: .outline).stroke(Night.metal, lineWidth: 1.4 * scale)
                LanternPart(part: .flame).fill(Night.flame)
            case .idle:
                LanternPart(part: .outline).stroke(Night.metal, lineWidth: 1.4 * scale)
            }
        }
        .frame(width: height * 12 / 16, height: height)
        .accessibilityHidden(true)
    }
}

struct LanternPart: Shape {
    enum Part { case ring, roof, base, outline, flame, markedGlass }
    let part: Part

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 12, rect.height / 16)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rect.minX + x * scale, y: rect.minY + y * scale, width: width * scale, height: height * scale)
        }
        var path = Path()
        switch part {
        case .ring:
            path.addEllipse(in: box(4.45, 0.55, 3.1, 3.1))
        case .roof:
            path.move(to: point(1.95, 5.15))
            path.addLine(to: point(10.05, 5.15))
            path.addLine(to: point(7.85, 4.05))
            path.addLine(to: point(4.15, 4.05))
            path.closeSubpath()
        case .base:
            path.addRoundedRect(in: box(1.1, 13.6, 9.8, 1.9), cornerSize: CGSize(width: 0.9 * scale, height: 0.9 * scale))
        case .outline:
            path.addRoundedRect(in: box(2.8, 6.4, 6.4, 6.6), cornerSize: CGSize(width: 1.6 * scale, height: 1.6 * scale))
        case .flame:
            path.move(to: point(6.155, 7.15))
            path.addCurve(to: point(7.55, 10.648), control1: point(6.465, 8.21), control2: point(7.55, 9.27))
            path.addCurve(to: point(6, 12.45), control1: point(7.55, 11.761), control2: point(6.899, 12.45))
            path.addCurve(to: point(4.45, 10.648), control1: point(5.101, 12.45), control2: point(4.45, 11.761))
            path.addCurve(to: point(6.155, 7.15), control1: point(4.45, 9.376), control2: point(5.659, 8.316))
            path.closeSubpath()
        case .markedGlass:
            path.addRoundedRect(in: box(2.1, 5.7, 7.8, 8), cornerSize: CGSize(width: 2.1 * scale, height: 2.1 * scale))
            path.addRoundedRect(in: box(5.25, 7, 1.5, 3.4), cornerSize: CGSize(width: 0.75 * scale, height: 0.75 * scale))
            path.addEllipse(in: box(5.2, 11, 1.6, 1.6))
        }
        return path
    }
}
