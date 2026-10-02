import SwiftUI
import WardenCore

/// train-guard in Settings: install it or remove what Warden installed, and tell each account's agents to use it.
struct TrainGuardSettings: View {
    @ObservedObject var setup: TrainGuardSetup
    let accounts: [AgentAccount]
    @State private var overrideUntil = Date().addingTimeInterval(3600)

    var body: some View {
        LabeledContent {
            if setup.isBusy {
                ProgressView().controlSize(.small)
            } else {
                switch setup.install {
                case .none:
                    if TrainGuardPackage.installationIssue == nil {
                        Button("Install…") { setup.confirmInstall(accounts: accounts) }
                    } else {
                        Text("Unavailable").foregroundStyle(.secondary)
                    }
                case .managed(let version):
                    // A newer version, as one the owner upgraded to, is left alone.
                    if TrainGuardPackage.installationIssue == nil, (version.map(TrainGuardPackage.isOlder) ?? true) || (version == TrainGuardPackage.version && TrainGuardPackage.currentEnvironment(home: setup.home).map { !TrainGuardPackage.isStandalone($0) } == true) {
                        Button(version == nil ? "Reinstall…" : "Update…") { setup.confirmInstall(accounts: accounts) }
                    }
                    Button("Remove…") { setup.confirmRemove(accounts: accounts) }
                case .legacy:
                    if TrainGuardPackage.installationIssue == nil {
                        Button("Migrate…") { setup.confirmInstall(accounts: accounts) }
                    }
                case .other:
                    EmptyView()
                }
            }
        } label: {
            Label {
                SettingLabel("train-guard", detail: detail)
            } icon: {
                Image(systemName: installationComplete ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(installationComplete ? Color.green : Color.secondary)
            }
        }
        Text("Only jobs started with train-guard run or attached to train-guard are supervised. Agent instructions ask agents to use it; they do not automatically capture every job. Lower priority is a scheduling hint, not a power limit.")
            .font(.caption).foregroundStyle(.secondary)
        if setup.install != .none {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let control = TrainGuard(home: setup.home)
                let exception = control.globalOverride(now: context.date)
                LabeledContent {
                    HStack {
                        Menu("Ignore All Jobs") {
                            ForEach([30, 60, 240], id: \.self) { minutes in
                                Button(minutes < 60 ? "For \(minutes) Minutes" : "For \(minutes / 60) \(minutes == 60 ? "Hour" : "Hours")") {
                                    setup.ignoreAll(until: Date().addingTimeInterval(Double(minutes) * 60))
                                }
                            }
                            Button("Until a Date…") { setup.choosingOverrideEnd = true }
                            Button("Until Turned Back On") { setup.ignoreAll() }
                        }
                        .disabled(!control.supportsGlobalControl || setup.isBusy)
                        if exception != nil {
                            Button("End Exception") { setup.resumeGuarding() }.disabled(setup.isBusy)
                        }
                    }
                    .fixedSize()
                } label: {
                    SettingLabel("All supervised jobs", detail: exception.map {
                        $0.expiresAt.map { "Full speed until \($0.formatted(date: .abbreviated, time: .shortened))." }
                            ?? "Full speed until you end this exception."
                    } ?? "Following the usual policy and any per-session exceptions.")
                }
            }
            Text("Includes current and future jobs, even without a chat owner, and allows full speed on battery. Timed exceptions expire even when Warden is closed. Per-session exceptions stay as chosen; legacy shell jobs keep their own policy.")
                .font(.caption).foregroundStyle(.secondary)
            if !TrainGuard(home: setup.home).supportsGlobalControl {
                Text("Update or migrate train-guard to use exceptions for all jobs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if setup.choosingOverrideEnd {
                DatePicker("Run at full speed until", selection: $overrideUntil, in: Date()...,
                           displayedComponents: [.date, .hourAndMinute])
                HStack {
                    Button("Apply") { setup.ignoreAll(until: overrideUntil) }
                        .disabled(overrideUntil <= Date() || setup.isBusy)
                    Button("Cancel") { setup.choosingOverrideEnd = false }
                }
            }
        }
        if setup.install != .none, !setup.files.isEmpty {
            LabeledContent {
                if setup.files.contains(where: { !$0.mentions }) {
                    Button("Add…") { setup.confirmAddInstructions(accounts: accounts) }.disabled(setup.isBusy)
                } else if setup.files.contains(where: \.hasSection) {
                    Button("Remove") { setup.removeInstructions(accounts: accounts) }.disabled(setup.isBusy)
                }
            } label: {
                SettingLabel("Agent instructions", detail: instructions)
            }
        }
        if let message = setup.message {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var installationComplete: Bool {
        switch setup.install {
        case .none, .managed(nil): return false
        case .managed, .legacy, .other: return true
        }
    }

    private var detail: String {
        switch setup.install {
        case .none:
            return TrainGuardPackage.installationIssue ?? "Pauses supervised jobs on battery and lowers their priority while the battery is warm. Bundled development version \(TrainGuardPackage.version). Installs offline with its own runtime; no Python setup is needed."
        case .managed(let version?):
            let kind = version.contains("dev") ? " (development build)" : ""
            return "Version \(version)\(kind), installed by Warden. Existing job policy is preserved."
        case .managed(nil):
            return "Warden's install is incomplete. " + (TrainGuardPackage.installationIssue ?? "Reinstall it to use it again.")
        case .legacy:
            return "Legacy shell script in ~/.claude/tools/train-guard. Migrate to the self-contained version; existing policy and logs are preserved, and removal restores the old command."
        case .other(let place):
            return "Installed at \(place). Per-session control requires train-guard 0.5 or a compatible legacy script."
        }
    }

    /// "Claude Code's CLAUDE.md tells agents to use it. Codex's AGENTS.md does not."
    private var instructions: String {
        let told = setup.files.filter(\.mentions).map { "\($0.agent)'s \($0.url.lastPathComponent)" }
        let untold = setup.files.filter { !$0.mentions }.map { "\($0.agent)'s \($0.url.lastPathComponent)" }
        var lines: [String] = []
        if !told.isEmpty { lines.append("\(ListFormatter.localizedString(byJoining: told)) \(told.count == 1 ? "tells" : "tell") agents to use it.") }
        if !untold.isEmpty { lines.append("\(ListFormatter.localizedString(byJoining: untold)) \(untold.count == 1 ? "does" : "do") not.") }
        return lines.joined(separator: " ")
    }
}
