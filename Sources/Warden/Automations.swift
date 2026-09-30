import Foundation
import WardenCore

/// Runs the executable files in Warden's Automations folder on each alert: a session needs you or finishes, a limit
/// warns, runs out or comes back, or you return from an absence. Each script gets the event as JSON on its standard
/// input and in environment variables, runs in the background for at most 30 seconds, and its output is dropped.
/// Warden itself sends nothing anywhere; a script can, such as one that notifies a phone.
@MainActor
final class Automations: ObservableObject {
    struct Run: Identifiable {
        let id = UUID()
        let script: String
        let event: String
        let at: Date
        let result: String
    }

    nonisolated static let folder = WardenPaths.support.appendingPathComponent("Automations", isDirectory: true)
    private static let timeout: TimeInterval = 30

    /// The latest runs, newest first, for Settings.
    @Published private(set) var runs: [Run] = []
    /// Variables every script gets besides the event's, such as the phone page's address.
    var environment: () -> [String: String] = { [:] }
    private let queue = DispatchQueue(label: "Warden.automations", qos: .utility, attributes: .concurrent)

    /// Executable files in the folder, by name. Hidden files and files that are not executable are left alone.
    nonisolated static func scripts() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { file in
            (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                && FileManager.default.isExecutableFile(atPath: file.path)
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func post(_ event: AutomationEvent) {
        guard UserDefaults.standard.bool(forKey: "automationsEnabled") || event.event == "test" else { return }
        let extra = environment()
        for script in Self.scripts() { run(script, event, extra: extra) }
    }

    private func run(_ script: URL, _ event: AutomationEvent, extra: [String: String]) {
        queue.async { [weak self] in
            let process = Process()
            process.executableURL = script
            process.currentDirectoryURL = Self.folder
            process.environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }.merging(event.environment) { $1 }
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            let result: String
            if (try? process.run()) == nil {
                result = "could not start"
            } else {
                // A script that does not read its input must not hold Warden; the write fails instead.
                try? input.fileHandleForWriting.write(contentsOf: event.json)
                try? input.fileHandleForWriting.close()
                if done.wait(timeout: .now() + Self.timeout) == .timedOut {
                    process.terminate()
                    result = "stopped after 30 s"
                } else {
                    result = process.terminationStatus == 0 ? "ran" : "exited with status \(process.terminationStatus)"
                }
            }
            let run = Run(script: script.lastPathComponent, event: event.event, at: event.at, result: result)
            DispatchQueue.main.async { self?.runs = Array(([run] + (self?.runs ?? [])).prefix(20)) }
        }
    }

    /// Creates the folder and a script that sends each alert to a phone through ntfy once you name a topic in it.
    /// Until then it exits at once. Returns the script, or nil when one with that name already exists.
    static func addExample() -> URL? {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notify-phone.sh")
        guard !manager.fileExists(atPath: file.path) else { return nil }
        let script = """
        #!/bin/sh
        # Sends Warden's alerts to your phone with ntfy (https://ntfy.sh): install its app, subscribe to a topic
        # only you know, and write that topic below. Until then this script does nothing.
        # Warden runs every executable file in this folder on each alert, with the event as JSON on standard input
        # and in WARDEN_EVENT, WARDEN_TITLE, WARDEN_MESSAGE, WARDEN_AGENT, WARDEN_PROJECT, and WARDEN_SESSION.
        # Events: needs-you, finished, context, cache-expiring, limit-warning, limit-reached, limit-unused,
        # reset-moved, daily-budget, quota-available, away-summary, test. Sending an alert shares its title and text, which can quote an agent's question.
        # With Warden's phone page on, tapping the notification opens it; the link names this Mac on your network.
        TOPIC=""
        [ -z "$TOPIC" ] && exit 0
        case "$WARDEN_EVENT" in
          needs-you|limit-reached|quota-available|test) ;;
          *) exit 0 ;;
        esac
        if [ -n "$WARDEN_PHONE_URL" ]; then
          curl -s -H "Title: $WARDEN_TITLE" -H "Click: $WARDEN_PHONE_URL" -d "$WARDEN_MESSAGE" "https://ntfy.sh/$TOPIC" >/dev/null
        else
          curl -s -H "Title: $WARDEN_TITLE" -d "$WARDEN_MESSAGE" "https://ntfy.sh/$TOPIC" >/dev/null
        fi

        """
        guard manager.createFile(atPath: file.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755]) else {
            return nil
        }
        return file
    }
}
