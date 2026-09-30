#if DEBUG
import AppKit
import WardenCore

/// A headless check of Codex prompts for debug builds: `WARDEN_CODEX_WATCH=1` runs only the daemon client, without the
/// menu, the store, its preferences, or the prompt socket, and prints what it sees. `WARDEN_CODEX_ANSWER` answers
/// prompts in turn, `WARDEN_CODEX_ANSWER_AFTER` seconds after each arrives (default 5), from a list such as
/// "allow,none,always,deny", where each is allow, session, always, deny, option:N, or none. `WARDEN_CODEX_HOME` picks the account folder (default ~/.codex), and the run ends after
/// `WARDEN_CODEX_TIMEOUT` seconds (default 300).
enum CodexWatch {
    static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["WARDEN_CODEX_WATCH"] == "1" else { return false }
        let folder = URL(fileURLWithPath: ((environment["WARDEN_CODEX_HOME"] ?? "~/.codex") as NSString).expandingTildeInPath)
        var answers = (environment["WARDEN_CODEX_ANSWER"] ?? "").split(separator: ",").map(String.init)
        let delay = Double(environment["WARDEN_CODEX_ANSWER_AFTER"] ?? "") ?? 5
        let timeout = Double(environment["WARDEN_CODEX_TIMEOUT"] ?? "") ?? 300
        let client = CodexDaemonClient(account: AgentAccount(provider: .codex, folder: folder, name: nil))
        func say(_ line: String) {
            print("\(ISO8601DateFormatter().string(from: Date())) \(line)")
            fflush(stdout)
        }
        client.log = { say($0) }
        client.onWaits = { waits in say("waits \(waits.map { "\($0.key)=\($0.value.kind.rawValue) \($0.value.detail ?? "")" }.sorted())") }
        client.onGone = { say("gone \($0)") }
        client.onRequest = { request in
            var choices: [String] = []
            if request.isQuestion {
                choices = request.questions.first?.options ?? []
            } else {
                choices = ["Allow"] + (request.canAllowForSession ? ["Allow for This Session"] : [])
                    + (request.alwaysRule.map { ["Always Allow \($0) (\(request.alwaysFile ?? "?"))"] } ?? []) + ["Deny"]
            }
            say("request \(request.id) session=\(request.sessionID) tool=\(request.tool) summary=\(request.summary ?? "-") cwd=\(request.cwd ?? "-") questions=\(request.questions.map { "\($0.id ?? "-"): \($0.text)" }) choices=\(choices)")
            guard !answers.isEmpty else { return }
            let answer = answers.removeFirst()
            let choice: ApprovalChoice
            switch answer {
            case "allow": choice = .allow
            case "session": choice = .allowForSession
            case "always": choice = .allowAlways
            case "deny": choice = .deny
            case "none": return say("leaving it to the terminal")
            default: choice = .option(Int(answer.dropFirst("option:".count)) ?? 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let reply = WardenStore.reply(choice, to: request) else { return say("no answer for \(answer)") }
                say("answer \(answer): \(client.answer(request.id, with: reply) ? "sent" : "not offered or gone")")
            }
        }
        client.connectIfNeeded()
        // As the store's scan does: connect again when the daemon comes back.
        let timer = Timer(timeInterval: 8, repeats: true) { _ in client.connectIfNeeded() }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.run(until: Date().addingTimeInterval(timeout))
        client.disconnect()
        say("done")
        return true
    }
}
#endif
