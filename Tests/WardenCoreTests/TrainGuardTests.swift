import CryptoKit
import XCTest
@testable import WardenCore

final class TrainGuardTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testBundledWheelMustMatchItsDigestBeforeInstallation() throws {
        XCTAssertTrue(TrainGuardPackage.isOlder("0.4.0"))
        XCTAssertFalse(TrainGuardPackage.isOlder("0.5.0"), "A final release must not be downgraded to a development wheel")
        let folder = home.appendingPathComponent("TrainGuard")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wheel = folder.appendingPathComponent(TrainGuardPackage.wheelName)
        let data = Data("fixture wheel".utf8)
        try data.write(to: wheel)
        XCTAssertThrowsError(try TrainGuardPackage.installationRequirements(resources: home))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try (digest + "\n").write(to: folder.appendingPathComponent("wheel.sha256"), atomically: true, encoding: .utf8)
        let requirements = try TrainGuardPackage.installationRequirements(resources: home)
        XCTAssertTrue(requirements.contains("train-guard @ " + wheel.absoluteString + " --hash=sha256:" + digest))
        XCTAssertTrue(requirements.contains("psutil==7.2.2"))
        try Data("damaged".utf8).write(to: wheel)
        XCTAssertThrowsError(try TrainGuardPackage.installationRequirements(resources: home))
    }

    func testRuntimeIsVerifiedBeforeItCanBeInstalledOffline() throws {
        let resources = home.appendingPathComponent("App/Contents/Resources")
        let runtime = home.appendingPathComponent("App/Contents/Helpers/TrainGuard.app")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("TrainGuard"), withIntermediateDirectories: true)
        let files = ["Contents/MacOS/train-guard": Data("#!/bin/sh\nexit 0\n".utf8), "Contents/Resources/version": Data((TrainGuardPackage.version + "\n").utf8), "Contents/Resources/library": Data("fixture library".utf8)]
        for (path, data) in files { try data.write(to: runtime.appendingPathComponent(path)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.appendingPathComponent("Contents/MacOS/train-guard").path)
        let manifest = files.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        try JSONEncoder().encode(manifest).write(to: resources.appendingPathComponent("TrainGuard/runtime-files.json"))
        XCTAssertEqual(try TrainGuardPackage.verifiedRuntime(resources: resources).path, runtime.path)
        try Data("damaged".utf8).write(to: runtime.appendingPathComponent("Contents/Resources/library"))
        XCTAssertThrowsError(try TrainGuardPackage.verifiedRuntime(resources: resources))
    }

    func testLegacyPolicyRetainsTheOwnersValuesWithoutExecutingShell() throws {
        let data = try TrainGuardPackage.legacyPolicy("""
        POLL=20 # keep the interval
        RUN_ON_BATTERY=false
        AC_BAND=ecore
        BATTERY_FLOOR_PCT=30
        TEMP_ECORE_C=38
        TEMP_PAUSE_C=42
        TEMP_RESUME_C=36
        """)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(value["poll"] as? Int, 20)
        XCTAssertEqual(value["run_on_battery"] as? Bool, false)
        XCTAssertEqual(value["ac_band"] as? String, "gentle")
        XCTAssertEqual(value["battery_floor_pct"] as? Int, 30)
        XCTAssertEqual(value["temp_gentle_c"] as? Int, 38)
        XCTAssertEqual(value["temp_pause_c"] as? Int, 42)
        XCTAssertEqual(value["temp_resume_c"] as? Int, 36)
        XCTAssertThrowsError(try TrainGuardPackage.legacyPolicy("POLL=$(echo 20)"))
    }

    func testCheckingAnAgentKeepsTheListsOtherLinesInBothImplementations() throws {
        let trainGuard = TrainGuard(home: home)
        XCTAssertEqual(trainGuard.ignoredAgents(), [])

        // The shell script is installed beside the package, and its list has an id the owner added by hand.
        let script = home.appendingPathComponent(".claude/tools/train-guard")
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        try "#!/usr/bin/env bash\n".write(to: script.appendingPathComponent("train-guard.sh"), atomically: true, encoding: .utf8)
        try "# mine\n019a-codex-thread   # Codex · research\n\n".write(to: script.appendingPathComponent("ignored-agents"), atomically: true, encoding: .utf8)
        let claude = "3f2b8c1e-5d4a-4e9b-9c7d-1a2b3c4d5e6f"
        try trainGuard.setIgnored(true, agent: claude, label: "Claude · warden")
        try trainGuard.setIgnored(true, agent: claude, label: "Claude · warden")
        XCTAssertEqual(trainGuard.ignoredAgents(), ["019a-codex-thread", claude])
        XCTAssertEqual(try String(contentsOf: script.appendingPathComponent("ignored-agents"), encoding: .utf8),
                       "# mine\n019a-codex-thread   # Codex · research\n\(claude)  # Claude · warden\n")
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".train-guard/ignored-agents"), encoding: .utf8),
                       TrainGuard.listHeader + "\(claude)  # Claude · warden\n")

        try trainGuard.setIgnored(false, agent: claude, label: "Claude · warden")
        XCTAssertEqual(trainGuard.ignoredAgents(), ["019a-codex-thread"])
        // An unreadable existing list must not be replaced, losing the owner's other choices.
        let packageList = home.appendingPathComponent(".train-guard/ignored-agents")
        let invalid = Data([0xff, 0xfe])
        try invalid.write(to: packageList)
        XCTAssertThrowsError(try trainGuard.setIgnored(true, agent: "another", label: "Codex"))
        XCTAssertEqual(try Data(contentsOf: packageList), invalid)
        // An id that would break the one-id-per-line format is left out.
        XCTAssertEqual(TrainGuard.list("", agent: "a\nb", ignored: true, label: "x"), "")
    }

    func testThePackagesRunningJobsNameTheirAgentAndDecision() throws {
        let run = home.appendingPathComponent(".train-guard/run")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        // As train-guard 0.5 writes them. This test process stands for a live supervisor, named by process id and start time.
        let pid = getpid()
        let started = try XCTUnwrap(ProcessDetails.startTime(of: pid))
        func write(_ name: String, agent: String?, started: Double) throws {
            let agentField = agent.map { "\"agent\": \"\($0)\", " } ?? ""
            try """
            {\(agentField)"created_at": "2026-09-27T14:02:11.412Z", "job_create_time": 1790517731.2, "jobpid": 70112,
             "log": "/Users/me/.train-guard/logs/\(name).log", "mode": "run", "name": "\(name)", "schema_version": 1}
            """.write(to: run.appendingPathComponent("\(name).meta.json"), atomically: true, encoding: .utf8)
            try "{\"create_time\": \(started), \"pid\": \(pid)}"
                .write(to: run.appendingPathComponent("\(name).guard.json"), atomically: true, encoding: .utf8)
            try """
            {"cooling": false, "decision": {"action": "full", "cooling": false, "reason": "agent_ignored"},
             "observation": {"charging": false, "observed_at": "2026-09-27T14:45:47.273Z", "percent": 93.0, "source": "battery",
             "temperature_c": 30.87, "warnings": []}, "owned_suspensions": [], "pids": [70112],
             "process_report": {"access_denied": 0, "gone": 0, "restored": 0, "resumed": 0, "suspended": 0, "targeted": 1, "tuned": 0},
             "schema_version": 1, "state": "full", "tuned_processes": [], "updated_at": "2026-09-27T14:45:47.274Z"}
            """.write(to: run.appendingPathComponent("\(name).runtime.json"), atomically: true, encoding: .utf8)
        }
        try write("probe", agent: "3f2b8c1e-5d4a-4e9b-9c7d-1a2b3c4d5e6f", started: started)
        try write("unattributed", agent: nil, started: started)
        // A record whose process id now belongs to a process that started later.
        try write("stale", agent: "3f2b8c1e-5d4a-4e9b-9c7d-1a2b3c4d5e6f", started: started - 3600)

        let trainGuard = TrainGuard(home: home)
        XCTAssertEqual(trainGuard.jobs(), [TrainGuard.Job(name: "probe", agent: "3f2b8c1e-5d4a-4e9b-9c7d-1a2b3c4d5e6f", decision: "full")])
        XCTAssertEqual(trainGuard.runningPackageGuards(), ["probe", "unattributed"])
        XCTAssertEqual(trainGuard.workingJobs(), ["probe", "unattributed"], "Unattributed live work still needs wake protection.")
        try #"{"state":"stop","pids":[70112]}"#.write(to: run.appendingPathComponent("unattributed.runtime.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(trainGuard.workingJobs(), ["probe"], "Paused work must not hold a wake assertion.")
        try #"{"state":"waiting","pids":[]}"#.write(to: run.appendingPathComponent("probe.runtime.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(trainGuard.workingJobs(), [])
    }

    func testAShellGuardsRecordAndLogGiveItsAgentAndDecision() {
        // As the shell script writes them: its record, shell-quoted, and its log.
        let meta = """
        MODE=run
        NAME=t-claude
        JOBPID=50395
        LOG=/Users/me/.claude/tools/train-guard/logs/t-claude.log
        GUARDLOG=/Users/me/.claude/tools/train-guard/logs/t-claude.guard.log
        AGENT=3f2b8c1e-5d4a-4e9b-9c7d-1a2b3c4d5e6f

        """
        XCTAssertEqual(TrainGuard.agent(inMeta: meta), "3f2b8c1e-5d4a-4e9b-9c7d-1a2b3c4d5e6f")
        XCTAssertNil(TrainGuard.agent(inMeta: "MODE=run\nNAME=t-none\nJOBPID=50418\nAGENT=''\n"))
        // Guards started before the script recorded agents.
        XCTAssertNil(TrainGuard.agent(inMeta: "MODE=run\nNAME=old-job\nJOBPID=37981\n"))

        let log = """
        [guard] 2026-09-27 13:42:16 START name=t-claude mode=run jobpid=50395 agent=3f2b8c1e-5d4a-4e9b-9c7d-1a2b3c4d5e6f
        [guard] 2026-09-27 13:42:16 -> ecore   (power=AC batt=66% temp=31C charging=yes)
        [guard] 2026-09-27 13:42:29 -> run   (power=AC batt=66% temp=31C charging=yes; agent ignored)
        [guard] 2026-09-27 13:42:50 -> stop   (power=Battery batt=67% temp=31C charging=no)
        [guard] 2026-09-27 13:43:02 no process matches pattern yet (waiting)

        """
        XCTAssertEqual(TrainGuard.decision(inLog: log), "stop")
        XCTAssertNil(TrainGuard.decision(inLog: "[guard] 2026-09-27 13:42:16 START name=t mode=run jobpid=1\n"))
    }
}

extension TrainGuardTests {
    func testTheAgentsSectionComesOutAsItWentIn() throws {
        let claude = home.appendingPathComponent(".claude/CLAUDE.md")
        let codex = home.appendingPathComponent(".codex/AGENTS.md")
        let work = home.appendingPathComponent(".claude-work/CLAUDE.md")
        let dotfile = home.appendingPathComponent("dotfiles/CLAUDE.md")
        for folder in [".claude", ".codex", ".claude-work", "dotfiles"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let original = "# Global instructions\n\nAnswer in French.\n"
        try original.write(to: claude, atomically: true, encoding: .utf8)
        // Another account's instructions live in a dotfiles folder, behind a symbolic link.
        try original.write(to: dotfile, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: dotfile)

        try TrainGuardInstructions.add(to: [claude, codex, work])
        let added = try String(contentsOf: claude, encoding: .utf8)
        XCTAssertTrue(added.hasPrefix(original + "\n<!-- BEGIN train-guard"))
        XCTAssertEqual(TrainGuardInstructions.adding(to: added), added)
        XCTAssertTrue(TrainGuardInstructions.hasSection(try String(contentsOf: codex, encoding: .utf8)))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: work.path), dotfile.path)
        XCTAssertEqual(try String(contentsOf: dotfile, encoding: .utf8), added)
        // Each file's text is saved once, and a file that did not exist has nothing to save.
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude/CLAUDE.warden-backup.md"), encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".claude-work/CLAUDE.warden-backup.md"), encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.warden-backup.md").path))

        // Text the owner wrote after the section since stays.
        try (added + "\nUse uv.\n").write(to: claude, atomically: true, encoding: .utf8)
        try TrainGuardInstructions.remove(from: [claude, codex, work])
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), original + "\nUse uv.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.path))
        XCTAssertEqual(try String(contentsOf: dotfile, encoding: .utf8), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: work.path), dotfile.path)

        // A file that is not UTF-8 text is never taken for an empty one.
        let latin = try XCTUnwrap("Réponds en français.\n".data(using: .isoLatin1))
        try latin.write(to: codex)
        XCTAssertNil(TrainGuardInstructions.text(of: codex))
        XCTAssertThrowsError(try TrainGuardInstructions.add(to: [codex]))
        XCTAssertEqual(try Data(contentsOf: codex), latin)

        // An owner who wrote their own train-guard instructions keeps them as they are.
        let own = "Run long jobs under `train-guard run --name <job> -- <command>`.\n"
        XCTAssertEqual(TrainGuardInstructions.adding(to: own), own)
    }
}
