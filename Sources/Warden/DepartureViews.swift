import SwiftUI
import WardenCore

struct DepartureReviewView: View {
    let review: DepartureReview
    let now: Date
    let openSession: (String) -> Void
    @AppStorage("plannerShowsDeparture") private var expanded = false
    @State private var showAll = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if review.items.isEmpty {
                    Text("No decision or context warning in the latest scan. New approvals and task completion remain unpredictable.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(showAll ? review.items : Array(review.items.prefix(3))) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(item.kind)).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text(item.detail).font(.caption)
                            Text(evidence(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let id = item.sessionID {
                            Button("Show Session") { openSession(id) }.controlSize(.small)
                                .accessibilityLabel("Show session: \(item.title)")
                        }
                    }
                }
                if review.items.count > 3 {
                    Button(showAll ? "Show fewer checks" : "Show \(review.items.count - 3) more checks") { showAll.toggle() }
                        .font(.caption)
                }
                Text("Quota scenarios below check the selected duration. These checks use existing local observations and never answer prompts or keep a cache warm for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 10)
        } label: {
            HStack {
                Text("Before you step away").font(.headline)
                Spacer()
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        if review.items.isEmpty { return "\(review.workingCount) working · no flags in this scan" }
        let decisions = review.items.filter { $0.kind == .decision }.count
        return "\(review.items.count) checks" + (decisions > 0 ? " · \(decisions) need you" : "")
    }

    private func evidence(_ item: DepartureReview.Item) -> String {
        var parts = [item.evidence == .provider ? "Provider reading" : item.evidence == .localLog ? "Local log"
                     : item.evidence == .inferred ? "Estimate" : "Unavailable"]
        if let at = item.observedAt { parts.append(at.formatted(date: .abbreviated, time: .shortened)) }
        if let deadline = item.deadline {
            parts.append("In \(max(1, Int(ceil(deadline.timeIntervalSince(now) / 60)))) min, at \(deadline.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func icon(_ kind: DepartureReview.Kind) -> String {
        switch kind {
        case .scan: return "arrow.clockwise"
        case .decision: return "hand.raised"
        case .context: return "text.alignleft"
        case .cache: return "hourglass"
        case .quotaCoverage: return "gauge.with.dots.needle.0percent"
        case .resume: return "clock.arrow.circlepath"
        }
    }
}

struct DeparturePowerRow: View {
    @ObservedObject var keepAwake: KeepAwake
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: keepAwake.isAwake ? "cup.and.saucer" : "moon.zzz").frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sleep protection: \(keepAwake.status)").font(.callout.weight(.medium))
                Text(keepAwake.detail).font(.caption).foregroundStyle(.secondary)
                if keepAwake.isAwake && !keepAwake.closedLidActive {
                    Text("Idle sleep is prevented. Keep the lid open; closed-lid protection is not confirmed.")
                        .font(.caption)
                }
            }
            Spacer(minLength: 8)
            Button("Power Settings…", action: openSettings).controlSize(.small)
        }
    }
}
