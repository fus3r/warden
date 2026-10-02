import AppKit
import SwiftUI
import WardenCore

@MainActor
final class ResetReminders: ObservableObject {
    @Published private(set) var items: [ResetReminder]
    private let defaults: UserDefaults
    static let key = "manualResetReminders"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = defaults.string(forKey: Self.key).flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode([ResetReminder].self, from: $0) } ?? []
    }

    func add(account: AgentAccount, expiryDate: Date) {
        // A date-only offer may expire at any hour. Use the start of that date for a conservative reminder.
        items.append(ResetReminder(provider: account.provider, account: account.name,
                                   expiresAt: Calendar.current.startOfDay(for: expiryDate), source: .manual))
        save()
    }

    func remove(_ id: String) { items.removeAll { $0.id == id }; save() }

    func available(plans: [PlanDetails], accounts: [AgentAccount], now: Date = Date()) -> [ResetReminder] {
        (ResetReminder.reported(in: plans) + items)
            .filter { $0.expiresAt > now && Accounts.follows($0.provider, account: $0.account, in: accounts) }
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(items), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.key)
        }
    }
}

struct ResetRemindersSettings: View {
    @ObservedObject var reminders: ResetReminders
    let accounts: [AgentAccount]
    let plans: [PlanDetails]
    @State private var adding = false
    @State private var accountID = ""
    @State private var expiryDate = Date().addingTimeInterval(86_400)

    var body: some View {
        ForEach(ResetReminder.reported(in: plans).filter { $0.expiresAt > Date() }
                + reminders.items.filter { Accounts.follows($0.provider, account: $0.account, in: accounts) }) { reminder in
            LabeledContent {
                HStack {
                    Button("Open Usage") { NSWorkspace.shared.open(reminder.usageURL) }
                    if reminder.source == .manual {
                        Button("Remove") { reminders.remove(reminder.id) }
                            .help("Remove this reminder after using the reset or if the offer is no longer available.")
                    }
                }
                .fixedSize()
            } label: {
                SettingLabel("\(reminder.name): \(reminder.title)", detail: reminder.source == .provider
                    ? "Expires \(reminder.expiresAt.formatted(date: .abbreviated, time: .shortened)). Provider reading at \(reminder.observedAt.formatted(date: .abbreviated, time: .shortened))."
                    : "Expiry date: \(reminder.expiresAt.formatted(date: .abbreviated, time: .omitted)). Entered from Usage; check that the reset is still available.")
            }
        }
        Text("Codex reports banked resets through its CLI. Claude Code's usage response does not include reset offers. Enter the expiry shown on Claude's Usage page; reminders stay on this Mac. Open Usage to redeem a reset.")
            .font(.caption).foregroundStyle(.secondary)
        if adding {
            Picker("Account", selection: $accountID) {
                ForEach(accounts) { account in
                    Text(account.provider.rawValue + (account.name.map { " (\($0))" } ?? "")).tag(account.id)
                }
            }
            DatePicker("Expiry shown in Usage", selection: $expiryDate, in: Date()...,
                       displayedComponents: [.date])
            Text("For a date without a time, Warden reminds you before that date starts. Remove the reminder after redeeming the reset.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Add Reminder") {
                    if let account = accounts.first(where: { $0.id == accountID }) {
                        reminders.add(account: account, expiryDate: expiryDate)
                        adding = false
                    }
                }.disabled(!accounts.contains { $0.id == accountID }
                           || Calendar.current.startOfDay(for: expiryDate) <= Date())
                Button("Cancel") { adding = false }
            }
        } else {
            Button("Add an Expiry from Usage…") {
                accountID = accounts.first(where: { $0.provider == .claude })?.id ?? accounts.first?.id ?? ""
                expiryDate = Date().addingTimeInterval(86_400)
                adding = true
            }.disabled(accounts.isEmpty)
        }
    }
}
