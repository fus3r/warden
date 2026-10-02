import SwiftUI
import ServiceManagement

struct KeepAwakeSettings: View {
    @ObservedObject var keepAwake: KeepAwake
    @AppStorage("keepAwake") private var enabled = false
    @AppStorage("keepAwakeOnBattery") private var onBattery = false
    @AppStorage("keepAwakeClosedLid") private var closedLid = false
    @AppStorage("sleepWhenAgentsDone") private var sleepWhenDone = false

    var body: some View {
        Form {
            Section("Keep Awake") {
                Toggle(isOn: $enabled) {
                    SettingLabel("Keep the Mac awake for active work",
                                 detail: "Covers working agents, running train-guard jobs and prompts you can answer from a paired phone. The display and screen lock keep their usual settings.")
                }
                .accessibilityLabel("Keep the Mac awake for active work")
                .onChange(of: enabled) { keepAwake.refresh() }
                Label {
                    SettingLabel(keepAwake.status, detail: keepAwake.detail)
                } icon: {
                    Image(systemName: keepAwake.isAwake ? "cup.and.saucer.fill" : "moon.zzz")
                        .foregroundStyle(keepAwake.isAwake ? Color.accentColor : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Section("Power Source") {
                Toggle(isOn: $onBattery) {
                    SettingLabel("Also keep awake on battery",
                                 detail: "Stops at 20% or less. With this off, protection pauses when the power adapter is unplugged.")
                }
                .accessibilityLabel("Also keep awake on battery")
                .disabled(!enabled)
                .onChange(of: onBattery) { keepAwake.refresh() }
            }
            Section("Closed Lid") {
                LabeledContent("Power service", value: serviceDescription)
                Toggle(isOn: Binding(get: { closedLid }, set: { keepAwake.setClosedLid($0) })) {
                    SettingLabel("Keep working with the lid closed",
                                 detail: "Requires administrator approval. Follows the power source choice above. Stays active for running train-guard jobs and prompts awaiting a paired phone, then restores normal sleep when no work needs it.")
                }
                .accessibilityLabel("Keep working with the lid closed")
                .disabled(!enabled || keepAwake.isRemovingHelper)
                Toggle(isOn: $sleepWhenDone) {
                    SettingLabel("Sleep when all prompts are done",
                                 detail: "With the lid closed, put the Mac to sleep after 30 seconds with no working agents, waiting prompts or unfinished train-guard jobs. New activity cancels the countdown.")
                }
                .accessibilityLabel("Sleep when all prompts are done")
                .disabled(!enabled || !closedLid || keepAwake.isRemovingHelper)
                .onChange(of: sleepWhenDone) { keepAwake.refresh() }
                if closedLid || keepAwake.helperStatus == .enabled || keepAwake.helperStatus == .requiresApproval {
                    Text("While active, this also disables Sleep in the Apple menu. Keep the Mac on a ventilated surface; do not put it in a bag while it is working.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("The service restores the previous sleep setting after work, on exit, or if Warden stops responding. A setting already disabled by another app is left unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                    if keepAwake.helperStatus == .requiresApproval {
                        Button("Allow in System Settings…") { keepAwake.openApprovalSettings() }
                    }
                    if closedLid, keepAwake.helperStatus == .notRegistered {
                        Button("Set Up Power Service…") { keepAwake.setClosedLid(true) }
                            .disabled(keepAwake.isRemovingHelper)
                    }
                    if keepAwake.helperStatus == .enabled || keepAwake.helperStatus == .requiresApproval {
                        Button(keepAwake.isRemovingHelper ? "Removing…" : "Remove Power Service") { keepAwake.removeHelper() }
                            .disabled(keepAwake.isRemovingHelper || !keepAwake.canAuthorizeHelper)
                    }
                }
                if let error = keepAwake.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { keepAwake.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in keepAwake.refresh() }
    }

    private var serviceDescription: String {
        switch keepAwake.helperStatus {
        case .enabled: return keepAwake.closedLidActive ? "Active" : "Approved, inactive"
        case .requiresApproval: return "Awaiting administrator approval"
        case .notRegistered: return "Not installed"
        case .notFound: return "Missing from this app"
        @unknown default: return "State unavailable"
        }
    }
}
