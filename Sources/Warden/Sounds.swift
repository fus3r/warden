import AppKit
import AVFoundation
import WardenCore

/// The moments an alert can play a sound for.
enum VoiceLine: String, CaseIterable, Identifiable {
    case question, needsYou, waiting, approval, error, limitReached, done, warning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .question: return "Question"
        case .needsYou: return "Needs You"
        case .waiting: return "Interrupted"
        case .approval: return "Approval"
        case .error: return "Error"
        case .limitReached: return "Limit Reached"
        case .done: return "Finished"
        case .warning: return "Warning"
        }
    }

    /// When the sound plays, shown under its name in Settings.
    var detail: String {
        switch self {
        case .question: return "An agent asks you a question."
        case .needsYou: return "Any other request for your attention."
        case .waiting: return "An agent you interrupt still waits 30 seconds later."
        case .approval: return "An agent needs approval to run a tool."
        case .error: return "An agent stops on an error."
        case .limitReached: return "An agent stops at a usage limit."
        case .done: return "An agent finishes working."
        case .warning: return "High context use, usage limits, and observed resets."
        }
    }

    /// The sound used until you choose another. Warnings use a chime: no recorded line says a limit is only close.
    var standard: String {
        switch self {
        case .question: return "elise/input_required_01"
        case .needsYou: return "elise/input_required_03"
        case .waiting: return "elise/session_start_01"
        case .approval: return "elise/input_required_02"
        case .error: return "elise/task_error_01"
        case .limitReached: return "elise/resource_limit_01"
        case .done: return "elise/task_complete_03"
        case .warning: return "dings/limit"
        }
    }
}

/// Open-source packs whose licenses allow bundling them. Resources/Voice/CREDITS.md lists every file.
enum SoundPack: String, CaseIterable, Identifiable {
    case elise, kenneyFemale = "kenney-female", kenneyMale = "kenney-male", aimee, dings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elise: return "Elise"
        case .kenneyFemale: return "Kenney Voiceover, Female"
        case .kenneyMale: return "Kenney Voiceover, Male"
        case .aimee: return "Aimee Smith Announcer"
        case .dings: return "Minimal Dings"
        }
    }

    var credit: String {
        switch self {
        case .elise: return "Elise sound pack by Doomspork (Utensils), voice generated with ElevenLabs. CC BY 4.0."
        case .kenneyFemale: return "Voiceover Pack by Kenney (kenney.nl), voiced by Giselle. CC0."
        case .kenneyMale: return "Voiceover Pack by Kenney (kenney.nl), voiced by Jeffrey M. Smith. CC0."
        case .aimee: return "Voice clips recorded and performed by Aimee Smith (www.aimeesmithva.com). CC BY 4.0."
        case .dings: return "minimal-dings by iain, synthesized chimes. CC0."
        }
    }
}

struct Sound: Identifiable, Hashable {
    /// "pack/file" for a bundled sound, "custom/file.ext" for one you added.
    let id: String
    let label: String
    let pack: SoundPack?
    let fits: Set<VoiceLine>

    static let bank: [Sound] = {
        func pack(_ pack: SoundPack, _ lines: [(String, String, [VoiceLine])]) -> [Sound] {
            lines.map { Sound(id: "\(pack.rawValue)/\($0.0)", label: $0.1, pack: pack, fits: Set($0.2)) }
        }
        let kenney: [(String, String, [VoiceLine])] = [
            ("ready", "“Ready?”", [.question, .needsYou, .waiting]),
            ("call_for_backup", "“Call for backup!”", [.needsYou, .approval]),
            ("hold", "“Hold!”", [.waiting]),
            ("mission_completed", "“Mission completed.”", [.done]),
            ("objective_achieved", "“Objective achieved.”", [.done]),
            ("congratulations", "“Congratulations!”", [.done]),
            ("mission_failed", "“Mission failed.”", [.error]),
            ("wrong", "“Wrong!”", [.error]),
            ("time_over", "“Time over.”", [.limitReached]),
            ("hurry_up", "“Hurry up!”", [.warning]),
            ("look_out", "“Look out!”", [.warning])
        ]
        return pack(.elise, [
            ("input_required_01", "“I have a question for you.”", [.question, .needsYou]),
            ("input_required_02", "“Could you take a look at this?”", [.approval, .needsYou]),
            ("input_required_03", "“Got a sec? I need your input.”", [.needsYou, .question, .waiting]),
            ("input_required_04", "“Quick question when you're ready.”", [.question]),
            ("task_acknowledge_01", "“Here's the plan, mind reviewing it?”", [.approval]),
            ("task_acknowledge_02", "“I've put together a plan for you.”", [.approval]),
            ("task_acknowledge_03", "“Ready when you are, plan's drafted.”", [.approval]),
            ("task_acknowledge_04", "“Take a look at my plan when you have a moment.”", [.approval]),
            ("session_start_01", "“Ready when you are.”", [.waiting, .needsYou]),
            ("session_start_02", "“Let's get started.”", [.waiting]),
            ("session_start_03", "“Hi, what are we working on?”", [.waiting, .needsYou]),
            ("session_start_04", "“Standing by.”", [.waiting]),
            ("task_error_01", "“Hit a snag, could use your help.”", [.error]),
            ("task_error_02", "“Something went wrong.”", [.error]),
            ("task_error_03", "“Ran into a problem.”", [.error]),
            ("task_error_04", "“Sorry, that didn't work.”", [.error]),
            ("resource_limit_01", "“We've hit the limit.”", [.limitReached]),
            ("resource_limit_02", "“Out of headroom for now.”", [.limitReached]),
            ("resource_limit_03", "“Quota's reached, taking a breather.”", [.limitReached]),
            ("resource_limit_04", "“That's the limit on this one.”", [.limitReached]),
            ("task_complete_01", "“All done!”", [.done]),
            ("task_complete_02", "“Task complete.”", [.done]),
            ("task_complete_03", "“Finished, back to you.”", [.done]),
            ("task_complete_04", "“Wrapped it up.”", [.done])
        ]) + pack(.kenneyFemale, kenney) + pack(.kenneyMale, kenney) + pack(.aimee, [
            ("ready", "“Ready?”", [.question, .needsYou]),
            ("continue", "“Continue?”", [.waiting, .question]),
            ("clear", "“Clear!”", [.done]),
            ("congratulations", "“Congratulations!”", [.done]),
            ("fail", "“Fail!”", [.error]),
            ("try_again", "“Try again!”", [.error]),
            ("time_up", "“Time up!”", [.limitReached])
        ]) + pack(.dings, [
            ("input", "Bing-bong chime", [.question, .needsYou, .approval, .waiting]),
            ("ack", "Single soft tone", [.approval, .needsYou]),
            ("start", "Rising fifth", [.waiting]),
            ("end", "Falling fifth", [.waiting, .done]),
            ("complete", "Rising fourth", [.done]),
            ("error", "Descending triad", [.error]),
            ("limit", "Three steady tones", [.warning, .limitReached]),
            ("spam", "Three short dry tones", [.warning])
        ])
    }()
}

/// Chooses and plays alert sounds: the bundled packs, plus files you add, kept in Warden's support folder.
@MainActor
final class SoundLibrary: ObservableObject {
    static let silent = "none"
    static let folder = WardenPaths.support.appendingPathComponent("Sounds", isDirectory: true)

    @Published private(set) var added: [Sound] = []
    private let queue = AVQueuePlayer()
    private let previewer = AVPlayer()
    private let defaults = UserDefaults.standard

    init() { reload() }

    func choice(for line: VoiceLine) -> String {
        defaults.string(forKey: "sound.\(line.rawValue)") ?? line.standard
    }

    func choose(_ id: String, for line: VoiceLine) {
        if id == line.standard { defaults.removeObject(forKey: "sound.\(line.rawValue)") }
        else { defaults.set(id, forKey: "sound.\(line.rawValue)") }
        objectWillChange.send()
    }

    func restoreDefaults() {
        for line in VoiceLine.allCases { defaults.removeObject(forKey: "sound.\(line.rawValue)") }
        objectWillChange.send()
    }

    /// Plays an alert's sound after any still playing, so two alerts do not talk over each other.
    func play(_ line: VoiceLine) {
        let id = choice(for: line)
        guard id != Self.silent, let url = url(for: id) ?? url(for: line.standard) else { return }
        queue.insert(AVPlayerItem(url: url), after: nil)
        queue.play()
    }

    func preview(_ id: String) {
        guard let url = url(for: id) else { return }
        previewer.replaceCurrentItem(with: AVPlayerItem(url: url))
        previewer.play()
    }

    func url(for id: String) -> URL? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let group = String(id[..<slash]), name = String(id[id.index(after: slash)...])
        if group == "custom" {
            let url = Self.folder.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "Voice/\(group)")
    }

    /// Copies audio files into Warden's folder, so they keep working after the originals move.
    /// Returns the names of the files that cannot be played.
    func add(_ urls: [URL]) -> [String] {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var rejected: [String] = []
        for url in urls {
            guard (try? AVAudioPlayer(contentsOf: url)) != nil else {
                rejected.append(url.lastPathComponent)
                continue
            }
            var target = Self.folder.appendingPathComponent(url.lastPathComponent)
            var copy = 2
            while manager.fileExists(atPath: target.path) {
                target = Self.folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(copy).\(url.pathExtension)")
                copy += 1
            }
            try? manager.copyItem(at: url, to: target)
        }
        reload()
        return rejected
    }

    func remove(_ sound: Sound) {
        if let url = url(for: sound.id) { try? FileManager.default.removeItem(at: url) }
        for line in VoiceLine.allCases where choice(for: line) == sound.id {
            defaults.removeObject(forKey: "sound.\(line.rawValue)")
        }
        reload()
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])) ?? []
        added = files
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Sound(id: "custom/\($0.lastPathComponent)", label: $0.deletingPathExtension().lastPathComponent,
                         pack: nil, fits: Set(VoiceLine.allCases)) }
    }
}
