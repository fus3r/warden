import CryptoKit
import Foundation

/// A self-contained train-guard runtime, signed with Warden and verified before offline installation.
public enum TrainGuardPackage {
    public static let version = "0.5.1.dev0"
    public static let wheelName = "train_guard-\(version)-py3-none-any.whl"

    public static var installationIssue: String? {
        do { _ = try runtimeFolder(); return nil }
        catch { return error.localizedDescription }
    }

    public struct InstallationError: LocalizedError {
        public let errorDescription: String?
        public init(_ text: String) { errorDescription = text }
    }

    /// The self-contained runtime is copied unchanged; installation needs neither Python nor a network.
    public static func runtimeFolder(resources: URL? = Bundle.main.resourceURL) throws -> URL {
        guard let resources else { throw InstallationError("This app has no bundled train-guard runtime.") }
        let folder = resources.deletingLastPathComponent().appendingPathComponent("Helpers/TrainGuard.app")
        guard FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("Contents/MacOS/train-guard").path),
              (try? String(contentsOf: folder.appendingPathComponent("Contents/Resources/version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == version,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("TrainGuard/runtime-files.json").path) else {
            throw InstallationError("The bundled train-guard runtime is missing or incomplete. Reinstall a complete copy of Warden.")
        }
        return folder
    }

    public static func verifiedRuntime(resources: URL? = Bundle.main.resourceURL) throws -> URL {
        let folder = try runtimeFolder(resources: resources)
        guard let resources else { throw InstallationError("This app has no bundled train-guard runtime.") }
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: resources.appendingPathComponent("TrainGuard/runtime-files.json")))
        guard manifest["Contents/MacOS/train-guard"] != nil, manifest["Contents/Resources/version"] != nil else {
            throw InstallationError("The train-guard runtime manifest is incomplete.")
        }
        for (path, digest) in manifest {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(path)),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw InstallationError("The bundled train-guard runtime is damaged. Reinstall Warden before trying again.")
            }
        }
        return folder
    }

    public static func isStandalone(_ environment: URL) -> Bool {
        FileManager.default.fileExists(atPath: environment.appendingPathComponent("version").path)
            && FileManager.default.isExecutableFile(atPath: environment.appendingPathComponent("bin/train-guard").path)
    }

    /// Validate the bundled artifact before creating environments or changing agent instructions.
    public static func installationRequirements(resources: URL? = Bundle.main.resourceURL) throws -> String {
        guard let resources else { throw InstallationError("This build has no bundled train-guard package. Rebuild Warden with its train-guard dependency.") }
        let folder = resources.appendingPathComponent("TrainGuard")
        let wheel = folder.appendingPathComponent(wheelName)
        guard let data = try? Data(contentsOf: wheel),
              let expected = try? String(contentsOf: folder.appendingPathComponent("wheel.sha256"), encoding: .utf8),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw InstallationError("The bundled train-guard package is missing or damaged. Reinstall Warden before trying again.")
        }
        return "train-guard @ \(wheel.absoluteString) --hash=sha256:\(expected.trimmingCharacters(in: .whitespacesAndNewlines))\n" + dependencies
    }

    /// psutil's macOS wheels for Apple silicon and Intel, including free-threaded Python.
    private static let dependencies = """
    psutil==7.2.2 \\
        --hash=sha256:1a7b04c10f32cc88ab39cbf606e117fd74721c831c98a27dc04578deb0c16979 \\
        --hash=sha256:ed0cace939114f62738d808fdcecd4c869222507e266e574799e9c0faa17d486 \\
        --hash=sha256:e78c8603dcd9a04c7364f1a3e670cea95d51ee865e4efb3556a3a63adef958ea \\
        --hash=sha256:2edccc433cbfa046b980b0df0171cd25bcaeb3a68fe9022db0979e7aa74a826b \\
        --hash=sha256:7b6d09433a10592ce39b13d7be5a54fbac1d1228ed29abc880fb23df7cb694c9 \\
        --hash=sha256:eed63d3b4d62449571547b60578c5b2c4bcccc5387148db46e0c2313dad0ee00

    """

    public static func folder(home: URL) -> URL { home.appendingPathComponent(".local/share/train-guard", isDirectory: true) }
    public static func link(home: URL) -> URL { home.appendingPathComponent(".local/bin/train-guard") }
    /// Warden removes only a folder that its installer marked as managed.
    public static func marker(home: URL) -> URL { folder(home: home).appendingPathComponent("installed-by-warden") }
    /// train-guard's login agent, which restarts persisted jobs with the Python of the environment it was made from.
    public static func loginAgent(home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/com.trainguard.restart.plist")
    }

    /// The environment the command links to, when Warden installed it.
    public static func currentEnvironment(home: URL) -> URL? {
        let folder = folder(home: home)
        guard FileManager.default.fileExists(atPath: marker(home: home).path),
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link(home: home).path),
              destination.hasPrefix(folder.path + "/") else { return nil }
        // The link is `<environment>/bin/train-guard`.
        return URL(fileURLWithPath: destination).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Whether train-guard's login agent starts a Python from inside the folder, as one installed by Warden's
    /// train-guard does.
    public static func loginAgentUses(_ folder: URL, home: URL) -> Bool {
        guard let data = try? Data(contentsOf: loginAgent(home: home)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let program = (plist["ProgramArguments"] as? [String])?.first else { return false }
        return program.hasPrefix(folder.path + "/")
    }

    /// Read an environment's installed version without running Python in the menu.
    public static func installedVersion(in environment: URL) -> String? {
        if isStandalone(environment) {
            return try? String(contentsOf: environment.appendingPathComponent("version"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let lib = environment.appendingPathComponent("lib")
        for python in (try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? [] {
            let packages = lib.appendingPathComponent(python).appendingPathComponent("site-packages")
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: packages.path)) ?? []
            where entry.hasPrefix("train_guard-") && entry.hasSuffix(".dist-info") {
                return String(entry.dropFirst("train_guard-".count).dropLast(".dist-info".count))
            }
        }
        return nil
    }

    /// Translate the legacy script's literal policy assignments without executing a shell file.
    /// Existing Python configuration always takes precedence.
    public static func legacyPolicy(_ text: String) throws -> Data {
        let names = ["POLL": "poll", "RUN_ON_BATTERY": "run_on_battery", "BATTERY_FLOOR_PCT": "battery_floor_pct",
                     "BATTERY_BAND": "battery_band", "AC_BAND": "ac_band", "TEMP_ECORE_C": "temp_gentle_c",
                     "TEMP_PAUSE_C": "temp_pause_c", "TEMP_RESUME_C": "temp_resume_c",
                     "CHARGE_COOL_UNTIL_PCT": "charge_cool_until_pct", "TEMP_CHARGE_ECORE_C": "temp_charge_gentle_c"]
        var policy: [String: Any] = [:]
        for line in text.components(separatedBy: .newlines) {
            let assignment = line.prefix { $0 != "#" }.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard assignment.count == 2, let key = names[assignment[0]] else { continue }
            let value = assignment[1]
            if key == "run_on_battery", ["true", "false"].contains(value) { policy[key] = value == "true" }
            else if key.hasSuffix("_band"), ["ecore", "gentle", "full"].contains(value) { policy[key] = value == "ecore" ? "gentle" : value }
            else if let number = Double(value), number.isFinite { policy[key] = number }
            else { throw InstallationError("The legacy policy has a nonliteral value for \(assignment[0]). Convert it to ~/.train-guard/config.json before migrating; the original was left unchanged.") }
        }
        return try JSONSerialization.data(withJSONObject: policy, options: [.prettyPrinted, .sortedKeys])
    }

    /// Whether an installed version is older than the one Warden carries.
    public static func isOlder(_ installed: String) -> Bool {
        // A final release is newer than its bundled development build.
        if installed == version.components(separatedBy: ".dev")[0] { return false }
        return installed.compare(version, options: .numeric) == .orderedAscending
    }
}

/// The section that tells agents to run long jobs under train-guard, in Claude Code's CLAUDE.md and Codex's AGENTS.md
/// of each account. Warden marks it so it can take it out again, and leaves a file that already mentions train-guard,
/// in its owner's own words, as it is.
public enum TrainGuardInstructions {
    static let begin = "<!-- BEGIN train-guard, added by Warden -->"
    static let end = "<!-- END train-guard -->"

    public static let section = """
    \(begin)
    ## Long or heavy jobs: run them under train-guard

    This Mac has train-guard, which pauses a job while the Mac runs on battery and lowers its priority while the battery is warm, without restarting it. Heat and charge cycles wear a laptop battery, and the owner would rather a job take longer.

    Run any long or heavy job under it: training, encoding, large batch jobs, data preparation, anything that keeps the CPU or GPU busy for more than a few minutes. Do not run such a job bare.

    ```bash
    train-guard run --name <job> -- <command...>   # start and supervise a job
    train-guard attach --pid <pid> --name <job>    # supervise a job that already runs
    train-guard status                             # power, battery, and each guarded job
    train-guard stop <job> [--kill]                # stop supervising; --kill also ends the job
    ```

    `run` records the invoking Claude Code or Codex session when its session ID is available. With `attach`, pass `--agent <original-session-id>` only when the job's original owner is known; attaching from a session does not establish ownership.

    If `train-guard` is not on the PATH, look in `~/.local/bin`. `train-guard run` prints where the job's output goes. The owner can exempt a session or all jobs from Warden's menu (Ignore train-guard), including until a chosen time. Keep using train-guard all the same, and never change its ignored-agents list or global override yourself.
    \(end)
    """

    /// Whether the text tells agents about train-guard, in Warden's section or in the owner's own words.
    public static func mentions(_ text: String) -> Bool { text.range(of: "train-guard", options: .caseInsensitive) != nil }

    public static func hasSection(_ text: String) -> Bool { text.contains(begin) }

    /// The text with Warden's section at the end, after a blank line, unless it already mentions train-guard.
    public static func adding(to text: String) -> String {
        guard !mentions(text) else { return text }
        let before = trimmingNewlines(text, leading: false)
        return (before.isEmpty ? "" : before + "\n\n") + section + "\n"
    }

    /// The text without Warden's section and the blank line it added, as it was before, whatever came after it since.
    public static func removing(from text: String) -> String {
        guard let start = text.range(of: begin),
              let stop = text.range(of: end, range: start.upperBound..<text.endIndex) else { return text }
        let before = trimmingNewlines(String(text[..<start.lowerBound]), leading: false)
        let after = trimmingNewlines(String(text[stop.upperBound...]), leading: true)
        let joined = before + (before.isEmpty || after.isEmpty ? "" : "\n\n") + after
        return joined.isEmpty || joined.hasSuffix("\n") ? joined : joined + "\n"
    }

    public struct UnreadableFile: LocalizedError {
        public let file: URL
        public var errorDescription: String? {
            "\((file.path as NSString).abbreviatingWithTildeInPath) could not be read as text, so Warden left it as it is."
        }
    }

    /// The file's text: empty when it does not exist yet, nil when it exists but is not readable UTF-8 text, which
    /// Warden then leaves alone. A symbolic link, as to a dotfiles folder, is read through.
    public static func text(of file: URL) -> String? {
        do { return try String(contentsOf: file.resolvingSymlinksInPath(), encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return "" }
        catch { return nil }
    }

    /// Adds the section to each file that does not mention train-guard, saving the file once first. A symbolic link
    /// stays a link: its target gets the section.
    public static func add(to files: [URL]) throws {
        for file in files {
            guard let text = text(of: file) else { throw UnreadableFile(file: file) }
            let updated = adding(to: text)
            guard updated != text else { continue }
            try backUp(file)
            try write(updated, to: file.resolvingSymlinksInPath())
        }
    }

    /// Takes the section out of each file. A plain file that held nothing else was Warden's to begin with, and goes.
    public static func remove(from files: [URL]) throws {
        for file in files {
            let target = file.resolvingSymlinksInPath()
            guard let text = text(of: file) else { continue }
            let updated = removing(from: text)
            guard updated != text else { continue }
            if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.path == file.path {
                try FileManager.default.removeItem(at: file)
            } else {
                try write(updated, to: target)
            }
        }
    }

    /// Saves a file's text once, before Warden first changes it, as `CLAUDE.warden-backup.md` beside it.
    static func backUp(_ file: URL) throws {
        let backup = file.deletingPathExtension().appendingPathExtension("warden-backup").appendingPathExtension(file.pathExtension)
        guard !FileManager.default.fileExists(atPath: backup.path),
              let data = try? Data(contentsOf: file.resolvingSymlinksInPath()) else { return }
        try data.write(to: backup, options: .withoutOverwriting)
    }

    /// Replaces a file's text in one step and keeps its permissions.
    private static func write(_ text: String, to file: URL) throws {
        let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
        try text.write(to: file, atomically: true, encoding: .utf8)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
    }

    private static func trimmingNewlines(_ text: String, leading: Bool) -> String {
        var text = Substring(text)
        if leading { while text.first?.isNewline == true { text = text.dropFirst() } }
        else { while text.last?.isNewline == true { text = text.dropLast() } }
        return String(text)
    }
}
