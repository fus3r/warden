import Foundation

/// The only privileged operation exposed by Warden: a fixed pmset setting, with no client-supplied arguments.
public enum PMSet {
    public static func sleepDisabled(in output: String) throws -> Bool {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "SleepDisabled" {
                guard fields.count == 2, ["0", "1"].contains(fields[1]) else {
                    throw PowerError("macOS returned an unreadable SleepDisabled setting.")
                }
                return fields[1] == "1"
            }
        }
        // pmset omits the system-wide section until a system-wide preference has been written.
        guard output.contains("Currently in use:") else { throw PowerError("Could not read macOS power settings.") }
        return false
    }

    public static func readSleepDisabled() throws -> Bool { try sleepDisabled(in: run(["-g"])) }

    public static func writeSleepDisabled(_ value: Bool) throws {
        _ = try run(["-a", "disablesleep", value ? "1" : "0"])
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PowerError("macOS could not update or read its sleep setting (pmset \(process.terminationStatus)).")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
