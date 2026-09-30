import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Choose the sound for each kind of alert, listen to every bundled sound, and add your own.
struct SoundSettings: View {
    @ObservedObject var sounds: SoundLibrary
    @State private var rejected: [String] = []

    var body: some View {
        Form {
            Section("Alert Sounds") {
                ForEach(VoiceLine.allCases) { line in
                    HStack {
                        Picker(selection: selection(for: line)) {
                            Text("Silent").tag(SoundLibrary.silent)
                            Section("Suggested") {
                                ForEach(options(for: line)) { sound in
                                    Text("\(sound.label) · \(sound.pack?.title ?? "")").tag(sound.id)
                                }
                            }
                            if !sounds.added.isEmpty {
                                Section("Your Sounds") {
                                    ForEach(sounds.added) { sound in Text(sound.label).tag(sound.id) }
                                }
                            }
                        } label: {
                            SettingLabel(line.title, detail: line.detail)
                        }
                        playButton(sounds.choice(for: line))
                            .disabled(sounds.choice(for: line) == SoundLibrary.silent)
                    }
                }
                Text("These play when the alert style includes Voice; see Alert Style in General. Choosing a sound plays it.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore Defaults") { sounds.restoreDefaults() }
            }

            Section("Your Sounds") {
                ForEach(sounds.added) { sound in
                    HStack {
                        playButton(sound.id)
                        Text(sound.label)
                        Spacer()
                        useFor(sound)
                        Button { sounds.remove(sound) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove this sound")
                    }
                }
                Button("Add Sounds…", action: addSounds)
                if !rejected.isEmpty {
                    Text("These files cannot be played: \(rejected.joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Section("Sound Bank") {
                ForEach(SoundPack.allCases) { pack in
                    DisclosureGroup {
                        ForEach(Sound.bank.filter { $0.pack == pack }) { sound in
                            HStack {
                                playButton(sound.id)
                                Text(sound.label)
                                Spacer()
                                useFor(sound)
                            }
                        }
                    } label: {
                        SettingLabel(pack.title, detail: pack.credit)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Sounds suited to this alert, plus the current choice if it came from elsewhere in the bank.
    private func options(for line: VoiceLine) -> [Sound] {
        let suggested = Sound.bank.filter { $0.fits.contains(line) }
        guard let chosen = Sound.bank.first(where: { $0.id == sounds.choice(for: line) }),
              !suggested.contains(chosen) else { return suggested }
        return suggested + [chosen]
    }

    private func selection(for line: VoiceLine) -> Binding<String> {
        Binding(get: { sounds.choice(for: line) }, set: { id in
            sounds.choose(id, for: line)
            sounds.preview(id)
        })
    }

    private func playButton(_ id: String) -> some View {
        Button { sounds.preview(id) } label: { Image(systemName: "play.circle") }
            .buttonStyle(.borderless)
            .help("Play")
    }

    /// The alerts that use this sound. Unchecking one restores its default.
    private func useFor(_ sound: Sound) -> some View {
        Menu("Use For") {
            ForEach(VoiceLine.allCases) { line in
                Toggle(line.title, isOn: Binding(
                    get: { sounds.choice(for: line) == sound.id },
                    set: { sounds.choose($0 ? sound.id : line.standard, for: line) }
                ))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func addSounds() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose sounds for Warden's alerts. Warden keeps its own copy."
        guard panel.runModal() == .OK else { return }
        rejected = sounds.add(panel.urls)
    }
}
