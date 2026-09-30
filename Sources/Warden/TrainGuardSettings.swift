import SwiftUI
import WardenCore

/// train-guard in Settings: install it or remove what Warden installed, and tell each account's agents to use it.
struct TrainGuardSettings: View {
    @ObservedObject var setup: TrainGuardSetup
    let accounts: [AgentAccount]

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
