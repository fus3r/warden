import AppKit
import Carbon

/// A global keyboard shortcut from a short list. Carbon hot keys need no Accessibility permission.
struct Shortcut: Hashable, Identifiable {
    let id: String
    let keyCode: UInt32
    let modifiers: UInt32
    let title: String

    /// Choices for each action. Control-Option-Command combinations are rarely taken by other apps.
    static let openChoices = [
        Shortcut(id: "ctrl-opt-cmd-w", keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey | optionKey | cmdKey), title: "⌃⌥⌘W"),
        Shortcut(id: "ctrl-opt-space", keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), title: "⌃⌥Space")
    ]
    static let jumpChoices = [
        Shortcut(id: "ctrl-opt-cmd-j", keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | cmdKey), title: "⌃⌥⌘J"),
        Shortcut(id: "ctrl-opt-cmd-return", keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey | optionKey | cmdKey), title: "⌃⌥⌘↩")
    ]

    static func find(_ id: String?) -> Shortcut? {
        (openChoices + jumpChoices).first { $0.id == id }
    }
}

/// Registers Warden's global shortcuts and runs their actions on the main thread.
@MainActor
final class HotKeys {
    private var references: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    /// Shortcuts another app already holds, so Settings can say so.
    private(set) var taken: Set<String> = []

    /// Replaces the registered shortcuts. Each binding pairs a shortcut with what it does.
    func register(_ bindings: [(Shortcut?, () -> Void)]) {
        for reference in references { UnregisterEventHotKey(reference) }
        references = []
        actions = [:]
        taken = []
        installHandler()
        for (index, (shortcut, action)) in bindings.enumerated() {
            guard let shortcut else { continue }
            let id = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x5744_454E, id: id),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                references.append(reference)
                actions[id] = action
            } else {
                taken.insert(shortcut.id)
            }
        }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard let context else { return noErr }
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            let id = key.id
            DispatchQueue.main.async { MainActor.assumeIsolated { keys.actions[id]?() } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
}
