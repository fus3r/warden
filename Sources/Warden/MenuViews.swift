import AppKit
import SwiftUI
import WardenCore

enum MenuLayout {
    static let width: CGFloat = 330
    static let inset: CGFloat = 14
}

final class MenuRowState: ObservableObject {
    @Published var highlighted = false
}

/// Hosts SwiftUI content in a menu item. Rows with an action handle their own click, as NSMenu leaves that to item views.
final class MenuHostView: NSView {
    let state = MenuRowState()
    private let action: (() -> Void)?
    private let closesMenu: Bool

    init(height: CGFloat, closesMenu: Bool = true, action: (() -> Void)? = nil, content: some View) {
        self.action = action
        self.closesMenu = closesMenu
        super.init(frame: NSRect(x: 0, y: 0, width: MenuLayout.width, height: height))
        autoresizingMask = [.width]
        let host = NSHostingView(rootView: AnyView(content.environmentObject(state)))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard let action else { return }
        if closesMenu {
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async(execute: action)
        } else {
            action()
        }
    }
}

struct MenuHeaderView: View {
    @ObservedObject var store: WardenStore

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Warden").font(.system(size: 13, weight: .bold))
            Text(MenuFormat.summary(attention: store.attentionCount, working: store.activeCount))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MenuLayout.inset)
        .padding(.vertical, 3)
    }
}

/// Usage windows as one aligned row each, like the hourly strip in the Weather menu.
struct UsageSectionView: View {
    @ObservedObject var store: WardenStore

    static func height(windowCount: Int, hasNote: Bool, hasBanked: Bool) -> CGFloat {
        CGFloat(windowCount) * 24 + (hasNote ? 20 : 0) + (hasBanked ? 20 : 0) + 4
    }

    /// Codex limit resets and credits the account holds, which can outlast a full window: "Codex: 2 limit resets
    /// banked". Warden only shows them; Codex spends them.
    static func banked(_ plans: [PlanDetails]) -> String? {
        let lines = plans.filter { $0.provider == .codex }.sorted { ($0.account ?? "") < ($1.account ?? "") }.compactMap { codex -> String? in
            var parts: [String] = []
            if codex.resets > 0 {
                var banked = codex.resets == 1 ? "1 limit reset banked" : "\(codex.resets) limit resets banked"
                // Unused resets expire; the soonest one matters.
                if let expires = codex.resetsExpire.first(where: { $0 > Date() }) {
                    banked += expires.timeIntervalSinceNow < 6 * 86_400
                        ? ", next expires \(expires.formatted(.dateTime.weekday(.wide)))"
                        : ", next expires \(expires.formatted(.dateTime.day().month(.abbreviated)))"
                }
                parts.append(banked)
            }
            if codex.unlimitedCredits {
                parts.append("unlimited credits")
            } else if let credits = codex.credits, let amount = Double(credits), amount > 0 {
                parts.append("\(amount.formatted(.number.precision(.fractionLength(0)))) credits")
            }
            return parts.isEmpty ? nil : "Codex\(codex.account.map { " (\($0))" } ?? ""): " + parts.joined(separator: ", ")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "; ")
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.windows) { window in
                    UsageRow(window: window, now: context.date)
                }
                if let note = UsageNote.text(windows: store.windows, now: context.date) {
                    Text(note.text)
                        .font(.system(size: 11))
                        .foregroundStyle(note.warning ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, MenuLayout.inset)
                        .frame(height: 20, alignment: .leading)
                }
                if let banked = Self.banked(store.plans) {
                    Text(banked)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, MenuLayout.inset)
                        .frame(height: 20, alignment: .leading)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

enum UsageNote {
    static func text(windows: [UsageWindow], now: Date) -> (text: String, warning: Bool)? {
        if let alert = UsageAlert.mostUrgent(in: windows, now: now) {
            let window = alert.window
            let name = window.name
            switch alert {
            case .exhausted:
                return ("\(name) limit reached. Resets \(window.resetsAt.map { MenuFormat.resetPhrase($0, now: now) } ?? "later").", true)
            case .runsOut(_, let date):
                return ("At this pace, \(name) runs out \(MenuFormat.moment(date, now: now)) (estimate).", true)
            case .nearlyUsed:
                return ("\(name) is nearly used. Resets \(window.resetsAt.map { MenuFormat.resetPhrase($0, now: now) } ?? "later").", true)
            }
        }
        if let reset = windows.filter({ $0.hasReset(now: now) }).min(by: { $0.resetsAt! < $1.resetsAt! }) {
            return ("\(reset.name) reset at \(MenuFormat.time(reset.resetsAt!)); awaiting a new reading.", false)
        }
        let stale = windows.filter { !$0.isCurrent(now: now) }
        if let oldest = stale.min(by: { $0.observedAt < $1.observedAt }) {
            let providers = Set(stale.map(\.provider.rawValue)).sorted().joined(separator: " and ")
            let day = Calendar.current.isDate(oldest.observedAt, inSameDayAs: now) ? "" : " \(oldest.observedAt.formatted(.dateTime.weekday(.abbreviated)))"
            return ("\(providers) as of\(day) \(MenuFormat.time(oldest.observedAt)), when last reported.", false)
        }
        return nil
    }
}

private struct UsageRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let forecast = window.forecast(now: now)
        let urgent = window.isCurrent(now: now) && (window.usedPercent >= 90 || forecast?.exhaustsAt != nil)
        // After its reset the last percentage describes a window that ended; the next reading gives the new one.
        let reset = window.hasReset(now: now)
        HStack(spacing: 10) {
            Text(window.rowLabel)
                .font(.system(size: 13))
                .frame(width: 76, alignment: .leading)
            UsageBar(value: reset ? 0 : window.usedPercent, marker: forecast?.elapsedFraction, tint: urgent ? .orange : .accentColor)
            Text(reset ? "–" : "\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 13).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
            HStack(spacing: 3) {
                if let reset = window.resetsAt {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                    Text(MenuFormat.resetShort(reset, now: now)).monospacedDigit()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, MenuLayout.inset)
        .frame(height: 24)
        .opacity(window.isCurrent(now: now) ? 1 : 0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reset ? "\(window.name) window reset, awaiting a new reading"
                            : "\(window.name) window, \(Int(window.usedPercent.rounded())) percent used\(window.isCurrent(now: now) ? "" : ", awaiting an updated reading")")
    }
}

/// Filled share of a limit, with a tick where usage would sit at an even pace through the window.
private struct UsageBar: View {
    let value: Double
    let marker: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * min(100, max(0, value)) / 100)
                if let marker {
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: 2, height: 11)
                        .offset(x: geometry.size.width * marker - 1)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 11)
    }
}

enum AlertChoice: CaseIterable {
    case all
    case attention
    case snooze

    var symbol: String {
        switch self {
        case .all: return "bell.fill"
        case .attention: return "exclamationmark"
        case .snooze: return "moon.fill"
        }
    }

    var help: String {
        switch self {
        case .all: return "Alerts for questions, approvals, errors, interruptions, finished tasks, context, and usage limits, as set in Settings."
        case .attention: return "Only questions, approvals, errors, and interruptions."
        case .snooze: return "No alerts for one hour. Choose again to resume."
        }
    }
}

/// A choice row with a round icon, like Energy Mode in the Battery menu.
struct AlertChoiceRow: View {
    @ObservedObject var store: WardenStore
    @EnvironmentObject private var row: MenuRowState
    let choice: AlertChoice

    private var selected: Bool {
        switch choice {
        case .snooze: return store.snoozedUntil != nil
        case .all: return store.snoozedUntil == nil && store.alertMode == .all
        case .attention: return store.snoozedUntil == nil && store.alertMode == .attention
        }
    }

    private var title: String {
        switch choice {
        case .all: return "All Alerts"
        case .attention: return "Only When Needed"
        case .snooze: return store.snoozedUntil.map { "Snoozed Until \(MenuFormat.time($0))" } ?? "Snooze for 1 Hour"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.12))
                Image(systemName: choice.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.primary)
            }
            .frame(width: 26, height: 26)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 5).fill(row.highlighted ? Color.primary.opacity(0.1) : .clear))
        .padding(.horizontal, 5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Template ring showing how full a session's context window is.
enum ContextRing {
    static func image(_ percent: Double?) -> NSImage {
        let fraction = min(1, max(0, (percent ?? 0) / 100))
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let inset = rect.insetBy(dx: 2, dy: 2)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2.2
            if percent == nil {
                track.setLineDash([2, 2.2], count: 2, phase: 0)
            }
            NSColor.black.withAlphaComponent(percent == nil ? 0.8 : 0.25).setStroke()
            track.stroke()
            guard percent != nil, fraction > 0 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: inset.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Template lantern for the menu bar, matching the app icon: unlit when no agent works, lit while one does,
/// and solid with an exclamation mark when one needs you.
enum Lantern {
    enum State { case idle, working, attention }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: NSRect(x: 4.45, y: 12.35, width: 3.1, height: 3.1))
            ring.lineWidth = 1.25
            ring.stroke()
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: 1.95, y: 10.85))
            roof.line(to: NSPoint(x: 10.05, y: 10.85))
            roof.line(to: NSPoint(x: 7.85, y: 11.95))
            roof.line(to: NSPoint(x: 4.15, y: 11.95))
            roof.close()
            roof.lineWidth = 1.1
            roof.lineJoinStyle = .round
            roof.fill()
            roof.stroke()
            let glass = NSRect(x: 2.1, y: 2.3, width: 7.8, height: 8)
            switch state {
            case .attention:
                // The mark is a hole in the solid glass, so the menu bar shows through it.
                let lamp = NSBezierPath(roundedRect: glass, xRadius: 2.1, yRadius: 2.1)
                lamp.append(NSBezierPath(roundedRect: NSRect(x: 5.25, y: 5.6, width: 1.5, height: 3.4), xRadius: 0.75, yRadius: 0.75))
                lamp.append(NSBezierPath(ovalIn: NSRect(x: 5.2, y: 3.4, width: 1.6, height: 1.6)))
                lamp.windingRule = .evenOdd
                lamp.fill()
            case .working, .idle:
                let outline = NSBezierPath(roundedRect: glass.insetBy(dx: 0.7, dy: 0.7), xRadius: 1.6, yRadius: 1.6)
                outline.lineWidth = 1.4
                outline.stroke()
                if state == .working { flame().fill() }
            }
            NSBezierPath(roundedRect: NSRect(x: 1.1, y: 0.5, width: 9.8, height: 1.9), xRadius: 0.9, yRadius: 0.9).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Candle flame inside the glass, widest a third of the way up.
    private static func flame() -> NSBezierPath {
        let (x, bottom, height, width): (CGFloat, CGFloat, CGFloat, CGFloat) = (6, 3.55, 5.3, 3.1)
        let tip = NSPoint(x: x + width * 0.05, y: bottom + height)
        let path = NSBezierPath()
        path.move(to: tip)
        path.curve(to: NSPoint(x: x + width / 2, y: bottom + height * 0.34),
                   controlPoint1: NSPoint(x: tip.x + width * 0.1, y: bottom + height * 0.8),
                   controlPoint2: NSPoint(x: x + width / 2, y: bottom + height * 0.6))
        path.curve(to: NSPoint(x: x, y: bottom), controlPoint1: NSPoint(x: x + width / 2, y: bottom + height * 0.13),
                   controlPoint2: NSPoint(x: x + width * 0.29, y: bottom))
        path.curve(to: NSPoint(x: x - width / 2, y: bottom + height * 0.34),
                   controlPoint1: NSPoint(x: x - width * 0.29, y: bottom),
                   controlPoint2: NSPoint(x: x - width / 2, y: bottom + height * 0.13))
        path.curve(to: tip, controlPoint1: NSPoint(x: x - width / 2, y: bottom + height * 0.58),
                   controlPoint2: NSPoint(x: tip.x - width * 0.16, y: bottom + height * 0.78))
        path.close()
        return path
    }
}
