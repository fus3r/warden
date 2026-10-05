import SwiftUI
import WardenCore

struct RemoteSettings: View {
    @ObservedObject var connections: RemoteConnections
    @State private var destination = ""
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Agents over SSH") {
                Text("Follow Claude Code and Codex on a Linux server from this Mac. Warden keeps its own SSH connection, including when your terminal is closed.")
                    .foregroundStyle(.secondary)
                Text("Use a host or alias that already works with ssh in Terminal. The server needs Python 3.8 or newer. SSH keys and known hosts stay managed by OpenSSH; Warden never reads them.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("SSH destination", text: $destination, prompt: Text("cluster or user@server"))
                TextField("Display name", text: $name, prompt: Text("Optional"))
                HStack {
                    Button("Add Host") {
                        if connections.add(destination: destination, name: name) {
                            destination = ""; name = ""; error = nil
                        } else {
                            error = connections.storageError ?? "Use a unique SSH host or alias, without spaces or shell commands."
                        }
                    }
                    .disabled(!RemoteSSHHost.validDestination(destination.trimmingCharacters(in: .whitespacesAndNewlines)))
                    Button("Open SSH in Terminal") {
                        let host = RemoteSSHHost(destination: destination.trimmingCharacters(in: .whitespacesAndNewlines))
                        if let command = RemoteNavigation.loginCommand(host: host) { SessionNavigator.runInTerminal(command) }
                    }
                    .disabled(!RemoteSSHHost.validDestination(destination.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                Text("Connect once in Terminal to accept the server's host key. For passwords, phone approval or expiring access, add the host then choose Authenticate in Terminal. For a cluster reached through a login node, use your usual SSH alias with ProxyJump.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = error ?? connections.storageError { Text(message).foregroundStyle(.red).font(.caption) }
            }
            Section("Hosts") {
                if connections.hosts.isEmpty {
                    Text("No remote hosts yet.").foregroundStyle(.secondary)
                }
                ForEach(connections.hosts) { host in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(get: { host.enabled }, set: { connections.setEnabled($0, host: host) })) {
                            Text(host.name).fontWeight(.medium)
                        }
                        let state = connections.states[host.id]
                        Text("\(host.destination) · \(state?.phase.rawValue ?? "Paused")")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let received = state?.receivedAt {
                            Text("Last update \(received.formatted(date: .omitted, time: .standard))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = state?.message {
                            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        HStack {
                            Button("Retry") { connections.retry(host) }.disabled(!host.enabled)
                            Button("Authenticate in Terminal") {
                                if let command = connections.authenticationCommand(for: host) { SessionNavigator.runInTerminal(command) }
                            }
                            Spacer()
                            Button("Remove") { connections.remove(host) }
                        }
                    }.padding(.vertical, 4)
                }
            }
            Section("Returning to an agent") {
                Text("Use tmux to reopen the exact pane, or screen to return to its existing session and window list. Without either, Warden can focus a single matching SSH tab in Terminal or iTerm. If several tabs connect to the same host, return to the agent's tab yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Only filtered states, titles, paths and counters cross SSH. Questions show a generic indicator; answer in the remote terminal. Remote quotas are shown separately. Token history and train-guard controls cover this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Pausing or removing a host closes monitoring only. Remote agents keep running. Monitoring resumes when Warden reconnects; it pauses while this Mac is asleep.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Phone approval stays manual in your usual authentication app. Warden reuses the SSH connection you approved. If the server expires it, sign in again; agents in tmux or screen can keep running while their state is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
