import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import WardenCore

/// Reads permission state only while this tab is visible. Checking never requests authorization.
struct AccessSettings: View {
    @ObservedObject var store: WardenStore
    @ObservedObject var keepAwake: KeepAwake
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var bannersEnabled = false
    @State private var requesting = false
    @State private var notificationMessage: String?
    @AppStorage("settingsTab") private var tab = "setup"

    var body: some View {
        Form {
            Section {
                Text("Warden \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Beta")
                    .font(.headline)
                Text("Start a Claude Code or Codex coding session. Warden puts sessions waiting for you at the top of its menu; click a session to return to its work.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Open interactive guide…") { store.openTutorial?() }
                Text("Practice answering a prompt, explore each feature and configure Warden as you go. Your place is saved.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Connect your sessions") {
                ForEach(store.accounts) { account in
                    let count = store.sessions.filter { $0.provider == account.provider && $0.account == account.name }.count
                    let connection = account.name == nil ? store.claudeConnection : store.otherConnections[account.id] ?? .notConnected
                    LabeledContent {
                        if account.provider == .claude, connection != .connected {
                            Button(connection == .needsRepair ? "Repair…" : "Connect…") {
                                store.confirmAndConnectClaude(account)
                            }
                        }
                    } label: {
                        SettingLabel(account.provider.rawValue + (account.name.map { " (\($0))" } ?? ""),
                                     detail: sourceDetail(account, connection: connection, count: count))
                    }
                }
                LabeledContent {
                    Button("Check Again") { store.refresh(usage: false); refresh() }
                } label: {
                    SettingLabel("Activity scan", detail: scanDetail)
                }
                if let message = store.connectionMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Alerts and startup") {
                LabeledContent {
                    if notificationStatus == .notDetermined {
                        Button(requesting ? "Requesting…" : "Allow Notifications…") { requestNotifications() }
                            .disabled(requesting)
                            .accessibilityLabel("Allow Warden notifications")
                    } else if notificationStatus != nil {
                        Button("System Settings…") { openNotificationSettings() }
                            .accessibilityLabel("Open notification settings")
                    }
                } label: {
                    SettingLabel("Notifications", detail: notificationDetail)
                }
                if notificationStatus == .authorized || notificationStatus == .provisional {
                    Button("Send Test Notification") { sendTestNotification() }
                }
                if let notificationMessage {
                    Text(notificationMessage).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent {
                    if store.loginStatus == .requiresApproval {
                        Button("Allow in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    } else {
                        Toggle("Open at login", isOn: Binding(get: { store.launchesAtLogin }, set: {
                            try? store.setLaunchAtLogin($0)
                        })).labelsHidden().accessibilityLabel("Open Warden at login")
                    }
                } label: {
                    SettingLabel("Open at login", detail: loginDetail)
                }
                if let error = store.loginError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Notifications use the system sound by default. Voice alerts are optional in General.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Compatibility and optional tools") {
                    Text("Claude Code hooks add precise context and supported approvals. Codex approvals require a supported terminal session on version 0.157 or later; IDE and desktop sessions have different coverage. Ordinary ChatGPT and Claude chats are not monitored.")
                        .font(.callout).padding(.vertical, 4)
                    LabeledContent {
                        Button("General…") { tab = "general" }
                    } label: {
                        SettingLabel("Long local jobs", detail: "Optional train-guard supervision, in General → Long Jobs. Installs offline with its own runtime.")
                    }
                    LabeledContent {
                        Button("Power…") { tab = "power" }
                    } label: {
                        SettingLabel("Keep Awake", detail: "Covers active jobs and answers awaited from your phone. " + powerDetail)
                    }
                    LabeledContent {
                        Button("Phone…") { tab = "phone" }
                    } label: {
                        SettingLabel("Phone companion", detail: "Pair your phone to answer prompts over an encrypted connection.")
                    }
                    Text("Session monitoring reads no provider credentials and needs no administrator access. Clicking a terminal session may ask macOS for permission to focus its window.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var notificationDetail: String {
        switch notificationStatus {
        case nil: return "Checking macOS permission…"
        case .notDetermined: return "Not requested. Allow notifications to receive alerts outside Warden."
        case .denied: return "Blocked in macOS. Enable Allow Notifications for Warden in System Settings."
        case .authorized:
            return bannersEnabled ? "Allowed by macOS. Focus and Warden's alert settings can still silence alerts."
                : "Allowed, but banners are off. Check the alert style in System Settings."
        case .provisional: return "Quiet delivery only. Enable banners in System Settings for visible alerts."
        default: return "Check Warden's notification options in System Settings."
        }
    }

    private var loginDetail: String {
        switch store.loginStatus {
        case .enabled: return "Enabled in macOS."
        case .requiresApproval: return "Registered; awaiting approval in Login Items."
        case .notRegistered: return "Off. Warden opens when you launch it."
        case .notFound: return "macOS cannot find the app. Keep Warden in Applications and try again."
        @unknown default: return "macOS returned an unknown state. Check Login Items."
        }
    }

    private var powerDetail: String {
        switch keepAwake.helperStatus {
        case .enabled: return "Approved in macOS. " + keepAwake.status + "."
        case .requiresApproval: return "Registered; administrator approval is pending. Closed-lid protection is not active."
        case .notRegistered: return "Not installed. Optional; ordinary Keep Awake needs no administrator access."
        case .notFound: return "The bundled service is missing. Install a complete signed copy of Warden."
        @unknown default: return "Service state unavailable. Check Power settings."
        }
    }

    private var scanDetail: String {
        guard let at = store.scannedAt else { return "No completed scan yet." }
        let age = Date().timeIntervalSince(at)
        return (age < 60 ? "Last scan " : "Scan is out of date: ") + at.formatted(date: .omitted, time: .standard)
            + ". \(store.sessions.count) sessions observed."
    }

    private func sourceDetail(_ account: AgentAccount, connection: ClaudeConnection, count: Int) -> String {
        guard FileManager.default.fileExists(atPath: account.folder.path) else {
            return "Account folder not found. Start the provider's CLI or choose its account folder in General."
        }
        let logs = count == 0 ? "No sessions observed yet." : "\(count) sessions observed locally."
        guard account.provider == .claude else { return logs + " Context is estimated from logs." }
        switch connection {
        case .connected: return "Hooks configured. " + logs
        case .needsRepair: return "Hook configuration needs repair. " + logs
        case .notConnected: return "Hooks not connected. " + logs
        }
    }

    private func refresh() {
        store.refreshLoginStatus()
        keepAwake.refresh()
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                notificationStatus = settings.authorizationStatus
                bannersEnabled = settings.alertSetting == .enabled
            }
        }
    }

    private func requestNotifications() {
        requesting = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            Task { @MainActor in
                requesting = false
                notificationMessage = error?.localizedDescription
                refresh()
            }
        }
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.fus3r.Warden"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Warden notification test"
        content.body = "Notifications can reach you here. Focus may silence banners or sounds."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "warden-notification-test", content: content, trigger: nil)) { error in
            Task { @MainActor in
                notificationMessage = error.map { "Test failed: \($0.localizedDescription)" }
                    ?? "Test submitted to macOS. If no banner appears, check Focus and the notification alert style."
            }
        }
    }
}
