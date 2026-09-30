import AppKit
import SwiftUI
import WardenCore

/// Scripts that run on Warden's alerts: the folder, the scripts in it, and their latest runs.
struct AutomationSettings: View {
    @ObservedObject var automations: Automations
    @AppStorage("automationsEnabled") private var enabled = false
    @State private var scripts: [URL] = []
    @State private var note: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    SettingLabel("Run scripts on alerts",
                                 detail: "Each alert also runs every executable file in the Automations folder: a session needs you or finishes, a prompt cache is about to expire, a limit warns, runs out, or comes back, or you return from an absence. Scripts run even while alerts are snoozed or quiet, and never for a muted session.")
                }
                HStack {
                    Button("Open Folder") { open() }
                    Button("Add Phone Example") { addExample() }
                    Button("Send Test Event") { test() }
                        .disabled(scripts.isEmpty)
                        .help("Runs every script once with a test event, even while scripts are off.")
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Scripts") {
                if scripts.isEmpty {
                    Text("No executable files in \((Automations.folder.path as NSString).abbreviatingWithTildeInPath) yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scripts, id: \.self) { script in
                        LabeledContent(script.lastPathComponent) {
                            Text(lastRun(of: script.lastPathComponent)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("What a script receives") {
                Group {
                    Text("The event as JSON on standard input: event, at, title, message, session, agent, account, project, and alerted, which says whether Warden also showed the alert. The same values are in WARDEN_EVENT, WARDEN_TITLE, WARDEN_MESSAGE, WARDEN_AGENT, WARDEN_PROJECT, and WARDEN_SESSION, and, once a phone is paired in the Phone tab, the page's address is in WARDEN_PHONE_URL.")
                    Text("Events: needs-you, finished, context, cache-expiring, limit-warning, limit-reached, limit-unused, reset-moved, daily-budget, quota-available, away-summary, and test. A script runs as you, in the background, for at most 30 seconds; its output is dropped.")
                    Text("Warden itself sends nothing anywhere. A script can, such as the phone example, which sends the alert's title and text to ntfy once you name a topic in it. Titles and texts can quote an agent's question, never a prompt, reply, or command.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { scripts = Automations.scripts() }
    }

    private func lastRun(of name: String) -> String {
        guard let run = automations.runs.first(where: { $0.script == name }) else { return "Not run yet" }
        return "\(run.event): \(run.result) at \(MenuFormat.time(run.at))"
    }

    private func open() {
        try? FileManager.default.createDirectory(at: Automations.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Automations.folder)
        scripts = Automations.scripts()
    }

    private func addExample() {
        if let file = Automations.addExample() {
            note = "Added \(file.lastPathComponent). Open it, write your ntfy topic, and turn on Run scripts on alerts."
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            note = "notify-phone.sh is already in the folder."
        }
        scripts = Automations.scripts()
    }

    private func test() {
        automations.post(AutomationEvent(event: "test", at: Date(), title: "Warden · test",
                                         message: "A test event from Warden's settings.", alerted: false))
        note = "Sent a test event to \(scripts.count == 1 ? "1 script" : "\(scripts.count) scripts")."
    }
}
