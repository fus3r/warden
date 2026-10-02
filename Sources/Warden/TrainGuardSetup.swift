import AppKit
import Foundation
import WardenCore

/// Installs train-guard for someone who does not have it, and tells the agents of each account to run long jobs under
/// it. Its self-contained runtime installs offline after checking every file against the bundled manifest. Warden asks before changing anything and can take it all out again.
@MainActor
final class TrainGuardSetup: ObservableObject {
    /// An agent's instructions file, such as `~/.claude/CLAUDE.md`, and what it says about train-guard.
    struct InstructionFile: Identifiable {
        let url: URL
        /// "Claude Code" or "Codex", with the account's name for another account.
        let agent: String
        /// It tells agents about train-guard, in Warden's section or in its owner's own words.
        let mentions: Bool
        let hasSection: Bool
        var id: String { url.path }
    }

    enum Install: Equatable {
        case none
        /// Installed by Warden, with the version found in its environment; nil when the environment is incomplete or
        /// its Python is gone.
        case managed(version: String?)
        /// Installed another way, from where it runs.
        case other(String)
        case legacy
    }

    @Published private(set) var install = Install.none
    @Published private(set) var files: [InstructionFile] = []
    @Published private(set) var isBusy = false
    @Published var message: String?
    @Published var choosingOverrideEnd = false
    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    func ignoreAll(until: Date? = nil) {
        guard TrainGuard(home: home).supportsGlobalControl else {
            message = "Update train-guard to the bundled version to use exceptions for all jobs."
            return
        }
        do {
            try TrainGuard(home: home).setGlobalOverride(true, until: until)
            message = nil
            choosingOverrideEnd = false
            objectWillChange.send()
        } catch { message = error.localizedDescription }
    }

    func resumeGuarding() {
        do {
            try TrainGuard(home: home).setGlobalOverride(false)
            message = nil
            objectWillChange.send()
        } catch { message = error.localizedDescription }
    }

    func refresh(accounts: [AgentAccount]) {
        let trainGuard = TrainGuard(home: home)
        if let environment = TrainGuardPackage.currentEnvironment(home: home) {
            let runs = FileManager.default.isExecutableFile(atPath: environment.appendingPathComponent("bin/train-guard").path)
            install = .managed(version: runs ? TrainGuardPackage.installedVersion(in: environment) : nil)
        } else if (try? FileManager.default.destinationOfSymbolicLink(atPath: TrainGuardPackage.link(home: home).path)) == trainGuard.scriptFolder.appendingPathComponent("train-guard.sh").path {
            install = .legacy
        } else if let command = trainGuard.command {
            install = .other((command.path as NSString).abbreviatingWithTildeInPath)
        } else {
            install = .none
        }
        var accounts = accounts
        #if DEBUG
        // A preview that stands a scratch folder for the home folder must never write to the real agents' instructions.
        if home != FileManager.default.homeDirectoryForCurrentUser { accounts = Accounts.discover(home: home) }
        #endif
        files = Self.instructionFiles(accounts)
    }

    /// Each existing account folder's instructions file, which the agent reads at the start of every session. A file
    /// that is not readable text is left out, so Warden never writes to it.
    nonisolated static func instructionFiles(_ accounts: [AgentAccount]) -> [InstructionFile] {
        accounts.filter { FileManager.default.fileExists(atPath: $0.folder.path) }.compactMap { account in
            let url = account.folder.appendingPathComponent(account.provider == .claude ? "CLAUDE.md" : "AGENTS.md")
            guard let text = TrainGuardInstructions.text(of: url) else { return nil }
            let agent = (account.provider == .claude ? "Claude Code" : "Codex") + (account.name.map { " (\($0))" } ?? "")
            return InstructionFile(url: url, agent: agent, mentions: TrainGuardInstructions.mentions(text),
                                   hasSection: TrainGuardInstructions.hasSection(text))
        }
    }

    // MARK: Actions

    /// Asks, then installs train-guard, or a newer or working copy of Warden's own, and adds the section to the agents'
    /// instructions that lack one.
    func confirmInstall(accounts: [AgentAccount]) {
        if let issue = TrainGuardPackage.installationIssue { message = issue; return }
        refresh(accounts: accounts)
        let untold = files.filter { !$0.mentions }
        let alert = NSAlert()
        alert.messageText = install == .legacy ? "Migrate train-guard?" : (install == .none ? "Install train-guard?" : "Install train-guard \(TrainGuardPackage.version) again?")
        let replacing = install == .legacy
            ? " The legacy script and its files stay in place; its literal policy settings are copied only if no Python policy exists. Removing Warden's install restores the old command."
            : (install == .none ? "" : " The current install keeps working until the new one runs.")
        alert.informativeText = """
        Warden installs train-guard \(TrainGuardPackage.version) and its runtime from this app. No Python installation or download is needed. Files are checked against SHA-256 digests.\(replacing)
        • It goes in an environment of its own in ~/.local/share/train-guard, including its own runtime, and the train-guard command in ~/.local/bin.
        \(untold.isEmpty ? "" : "• A short section in \(ListFormatter.localizedString(byJoining: untold.map { Self.display($0.url) })) tells agents to run long jobs under it. Each file is saved once, before the first change, as a .warden-backup copy.\n")• Jobs keep their state and output in ~/.train-guard.

        Settings can remove it again.
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let home = self.home
        let files = untold.map(\.url)
        perform(accounts: accounts, working: "Installing train-guard…") {
            let version = try Self.installPackage(home: home)
            try TrainGuardInstructions.add(to: files)
            return "train-guard \(version) is installed" + (files.isEmpty ? "." : ", and \(files.count == 1 ? "one agent's instructions mention" : "the agents' instructions mention") it.")
        }
    }

    /// Asks, then takes out what Warden installed and its sections. Jobs' state and logs in ~/.train-guard stay.
    func confirmRemove(accounts: [AgentAccount]) {
        let running = TrainGuard(home: home).runningPackageGuards()
        guard running.isEmpty else {
            message = Self.stillRunning(running)
            return
        }
        let sections = files.filter(\.hasSection).map(\.url)
        let agent = TrainGuardPackage.loginAgentUses(TrainGuardPackage.folder(home: home), home: home)
        let alert = NSAlert()
        alert.messageText = "Remove train-guard?"
        alert.informativeText = "Warden deletes ~/.local/share/train-guard and the train-guard command it linked in ~/.local/bin\(sections.isEmpty ? "" : ", and takes its section out of \(ListFormatter.localizedString(byJoining: sections.map(Self.display)))")\(agent ? ". train-guard's login agent, which restarts saved jobs at login, goes too" : ""). The state and logs in ~/.train-guard stay."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let home = self.home
        perform(accounts: accounts, working: "Removing train-guard…") {
            try Self.removePackage(home: home)
            try TrainGuardInstructions.remove(from: sections)
            return "train-guard is removed. ~/.train-guard still holds its jobs' logs."
        }
    }

    /// Adds Warden's section to the instructions that do not mention train-guard, after asking.
    func confirmAddInstructions(accounts: [AgentAccount]) {
        let untold = files.filter { !$0.mentions }.map(\.url)
        guard !untold.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Tell agents to use train-guard?"
        alert.informativeText = "Warden adds a short section to \(ListFormatter.localizedString(byJoining: untold.map(Self.display))) that tells agents to run long or heavy jobs under train-guard. Each file is saved once, before the first change, as a .warden-backup copy, and Settings can take the section out again."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(accounts: accounts, working: nil) {
            try TrainGuardInstructions.add(to: untold)
            return "Agents read the new section from their next session."
        }
    }

    func removeInstructions(accounts: [AgentAccount]) {
        let sections = files.filter(\.hasSection).map(\.url)
        perform(accounts: accounts, working: nil) {
            try TrainGuardInstructions.remove(from: sections)
            return "Warden's section is out of \(ListFormatter.localizedString(byJoining: sections.map(Self.display)))."
        }
    }

    private func perform(accounts: [AgentAccount], working: String?, _ work: @escaping @Sendable () throws -> String) {
        isBusy = true
        message = working
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBusy = false
                switch result {
                case .success(let text): self.message = text
                case .failure(let error): self.message = error.localizedDescription
                }
                self.refresh(accounts: accounts)
            }
        }
    }

    nonisolated private static func display(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }

    nonisolated private static func stillRunning(_ names: [String]) -> String {
        "train-guard still supervises \(ListFormatter.localizedString(byJoining: names)). Stop \(names.count == 1 ? "it" : "them") first, with train-guard stop."
    }

    // MARK: Steps

    struct SetupError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Makes a new environment, installs the pinned files in it, checks that it runs, points the command at it in one
    /// step, and only then deletes the environments it replaces. Returns the version installed.
    nonisolated static func installPackage(home: URL) throws -> String {
        let runtime = try TrainGuardPackage.verifiedRuntime()
        let manager = FileManager.default
        let folder = TrainGuardPackage.folder(home: home)
        let link = TrainGuardPackage.link(home: home)
        let current = TrainGuardPackage.currentEnvironment(home: home)
        let trainGuard = TrainGuard(home: home)
        let legacy = trainGuard.scriptFolder.appendingPathComponent("train-guard.sh")
        let previousLink = try? manager.destinationOfSymbolicLink(atPath: link.path)
        let migrating = current == nil && previousLink == legacy.path && trainGuard.hasScript
        if current == nil, !migrating, manager.fileExists(atPath: link.path) || previousLink != nil {
            throw SetupError("\(display(link)) already exists and is not Warden's. Remove it first.")
        }
        let owned = manager.fileExists(atPath: TrainGuardPackage.marker(home: home).path)
        guard owned || !manager.fileExists(atPath: folder.path) else {
            throw SetupError("\(display(folder)) already exists and is not Warden's. Its contents were left unchanged.")
        }
        let running = trainGuard.runningPackageGuards() + (migrating ? trainGuard.runningScriptGuards() : [])
        guard running.isEmpty else { throw SetupError(stillRunning(running)) }
        let policy = trainGuard.packageFolder.appendingPathComponent("config.json")
        let legacyPolicy = trainGuard.scriptFolder.appendingPathComponent("config.env")
        let policyData = migrating && !manager.fileExists(atPath: policy.path) && manager.fileExists(atPath: legacyPolicy.path)
            ? try TrainGuardPackage.legacyPolicy(String(contentsOf: legacyPolicy, encoding: .utf8)) : nil
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let environment = folder.appendingPathComponent("env-\(UUID().uuidString)", isDirectory: true)
        let command = environment.appendingPathComponent("bin/train-guard")
        var createdPolicy = false
        do {
            try manager.createDirectory(at: environment.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try manager.copyItem(at: runtime, to: environment.appendingPathComponent("TrainGuard.app"))
            try manager.createSymbolicLink(atPath: command.path, withDestinationPath: "../TrainGuard.app/Contents/MacOS/train-guard")
            try (TrainGuardPackage.version + "\n").write(to: environment.appendingPathComponent("version"), atomically: true, encoding: .utf8)
            let expected = "train-guard \(TrainGuardPackage.version)"
            let output = try run(command, ["--version"], in: folder, timeout: 30, doing: "train-guard did not start")
            guard output.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == expected }) else {
                throw SetupError("train-guard did not report \(expected): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if let policyData {
                try manager.createDirectory(at: trainGuard.packageFolder, withIntermediateDirectories: true)
                try policyData.write(to: policy, options: .withoutOverwriting)
                createdPolicy = true
            }
            try run(command, ["config", "--check"], in: folder, timeout: 30, doing: "train-guard rejected the policy", home: home)
            if migrating {
                let oldList = trainGuard.scriptFolder.appendingPathComponent("ignored-agents")
                let newList = trainGuard.packageFolder.appendingPathComponent("ignored-agents")
                if manager.fileExists(atPath: oldList.path), !manager.fileExists(atPath: newList.path) {
                    try manager.createDirectory(at: trainGuard.packageFolder, withIntermediateDirectories: true)
                    try manager.copyItem(at: oldList, to: newList)
                }
                try legacy.path.write(to: folder.appendingPathComponent("previous-command"), atomically: true, encoding: .utf8)
            }
            try "Installed by Warden. Manage in Settings → General → Long Jobs.\n"
                .write(to: TrainGuardPackage.marker(home: home), atomically: true, encoding: .utf8)
            try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = link.deletingLastPathComponent().appendingPathComponent(".train-guard-\(UUID().uuidString)")
            try manager.createSymbolicLink(at: temporary, withDestinationURL: command)
            guard rename(temporary.path, link.path) == 0 else {
                try? manager.removeItem(at: temporary)
                throw SetupError("Warden could not link \(display(link)).")
            }
        } catch {
            try? manager.removeItem(at: environment)
            if createdPolicy { try? manager.removeItem(at: policy) }
            if !owned { try? manager.removeItem(at: folder) }
            throw error
        }
        if let current, TrainGuardPackage.loginAgentUses(current, home: home) {
            do {
                try run(command, ["install-agent"], in: folder, timeout: 30, doing: "train-guard could not update its login agent", home: home)
            } catch {
                // A failed launchd update must never leave its old Python path deleted.
                throw SetupError("train-guard was updated, but its login agent needs repair. The previous environment was kept. \(error.localizedDescription)")
            }
        }
        for entry in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        where entry.hasPrefix("env-") && entry != environment.lastPathComponent {
            let old = folder.appendingPathComponent(entry)
            if !TrainGuardPackage.loginAgentUses(old, home: home) { try? manager.removeItem(at: old) }
        }
        return TrainGuardPackage.version
    }

    /// Deletes Warden's install, once no guard runs from it, and train-guard's login agent when it starts it.
    nonisolated static func removePackage(home: URL) throws {
        let manager = FileManager.default
        let folder = TrainGuardPackage.folder(home: home)
        let link = TrainGuardPackage.link(home: home)
        guard manager.fileExists(atPath: TrainGuardPackage.marker(home: home).path) else {
            throw SetupError("\(display(folder)) was not installed by Warden, so Warden left it as it is.")
        }
        let running = TrainGuard(home: home).runningPackageGuards()
        guard running.isEmpty else { throw SetupError(stillRunning(running)) }
        if TrainGuardPackage.loginAgentUses(folder, home: home) {
            // Otherwise it would try to start a Python that no longer exists at every login.
            let command = TrainGuardPackage.currentEnvironment(home: home)?.appendingPathComponent("bin/train-guard") ?? link
            try run(command, ["uninstall-agent"], in: folder, timeout: 30, doing: "train-guard could not remove its login agent", home: home)
        }
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path), existing.hasPrefix(folder.path + "/") {
            let legacy = TrainGuard(home: home).scriptFolder.appendingPathComponent("train-guard.sh")
            if (try? String(contentsOf: folder.appendingPathComponent("previous-command"), encoding: .utf8)) == legacy.path,
               manager.isExecutableFile(atPath: legacy.path) {
                let temporary = link.deletingLastPathComponent().appendingPathComponent(".train-guard-\(UUID().uuidString)")
                try manager.createSymbolicLink(at: temporary, withDestinationURL: legacy)
                guard rename(temporary.path, link.path) == 0 else {
                    try? manager.removeItem(at: temporary)
                    throw SetupError("Warden could not restore the legacy train-guard command.")
                }
            } else { try manager.removeItem(at: link) }
        }
        try manager.removeItem(at: folder)
    }

    /// Runs a program to its end and returns its output, or throws with the end of what it printed.
    @discardableResult
    nonisolated private static func run(_ program: URL, _ arguments: [String], in folder: URL, timeout: TimeInterval,
                                        doing: String, home: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = program
        process.arguments = arguments
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        for key in ["PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "VIRTUAL_ENV"] { environment[key] = nil }
        if let home {
            environment["HOME"] = home.path
            environment["TRAIN_GUARD_HOME"] = home.appendingPathComponent(".train-guard").path
        }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let started = Date()
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Reading to the end while it runs keeps a long pip log from filling the pipe and stalling it.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        let text = String(decoding: data, as: UTF8.self)
        let signaled = process.terminationReason == .uncaughtSignal
        guard signaled || process.terminationStatus != 0 else { return text }
        if signaled, Date().timeIntervalSince(started) >= timeout {
            throw SetupError("\(doing): it took more than \(Int(timeout)) seconds.")
        }
        let tail = text.split(separator: "\n").suffix(3).joined(separator: " ")
        let reason = tail.isEmpty ? (signaled ? "stopped by signal \(process.terminationStatus)" : "exit status \(process.terminationStatus)") : tail
        throw SetupError(doing.isEmpty ? reason : "\(doing): \(reason)")
    }
}
