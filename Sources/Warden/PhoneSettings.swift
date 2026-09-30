import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import WardenCore

/// Settings for the phone companion: turning it on, trusting Warden's certificate on the phone, pairing, and the
/// paired phones.
struct PhoneSettings: View {
    @ObservedObject var phone: PhoneCompanion
    @State private var confirmRenew = false

    var body: some View {
        Form {
            Section {
                if RemotePhone.relayURL != nil {
                    Picker("Connection", selection: Binding(get: { phone.usesRelay }, set: { phone.setMode($0) })) {
                        Text("Anywhere").tag(true)
                        Text("Local network").tag(false)
                    }.pickerStyle(.segmented)
                }
                Toggle(isOn: Binding(get: { phone.enabled }, set: { phone.setEnabled($0) })) {
                    SettingLabel("Answer from your phone",
                                 detail: phone.usesRelay
                                    ? "See sessions and answer supported prompts from a paired phone. Commands and replies are encrypted between your devices."
                                    : "Connect your phone and Mac to the same local network. See sessions and answer supported prompts over an encrypted connection.")
                }
                if phone.enabled { Text(phone.usesRelay ? phone.remote.status : statusText).font(.caption).foregroundStyle(statusIsProblem ? .red : .secondary) }
            }
            if phone.usesRelay {
                remoteSettings
            } else if phone.enabled, let certificate = phone.certificate {
                trust(certificate)
                pairing
                paired
            }
            Section {
                Text("Only devices you pair can read pending commands and questions. Unpair a device here to revoke its access. Monitoring and history stay on the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Make new certificates?", isPresented: $confirmRenew) {
            Button("Make New Certificates") { phone.issueCertificate() }
        } message: {
            Text("Paired phones stay paired, but each needs the new profile installed and trusted before it can open Warden again.")
        }
    }

    @ViewBuilder private var remoteSettings: some View {
        Section("Connect from anywhere") {
            Text("Works over Wi-Fi and mobile data. No VPN or certificate profile to install. Warden's relay passes encrypted messages between this Mac and your phone.")
            Text("On iPhone, add Warden to the Home Screen to receive notifications while the phone is locked. Enable notifications from the phone after pairing.")
        }.font(.callout)
        if phone.enabled {
            Section("Pair your phone") {
                if let pending = phone.remote.pending, let link = phone.remote.pairingURL {
                    HStack(alignment: .top, spacing: 16) {
                        if let image = Self.qrCode(link.absoluteString) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 176, height: 176)
                                .accessibilityLabel("QR code to pair this phone securely")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Scan with your phone's camera. Warden confirms the connection here.")
                            Text("For a Home Screen app, paste the pairing link into its pairing page.").font(.caption).foregroundStyle(.secondary)
                            Button("Copy Pairing Link") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.absoluteString, forType: .string)
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("Expires in \(max(0, Int(pending.expiresAt.timeIntervalSince(context.date)))) seconds")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Button("Cancel") { phone.remote.cancelPairing() }
                        }
                    }.padding(.vertical, 6)
                } else {
                    Button("Pair a Phone…") { phone.remote.openPairing() }
                    Text("Keep the pairing link private. It gives one phone access; it expires after five minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !phone.remote.devices.isEmpty {
                Section("Paired phones") {
                    ForEach(phone.remote.devices) { device in
                        LabeledContent(device.name) { Button("Unpair") { phone.remote.unpair(device.id) } }
                    }
                    Button("Send Test Phone Notification") { phone.remote.notify() }
                    Text("Notifications must first be enabled on the phone.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        switch phone.status {
        case .failed(let message): return message
        case .listening:
            let network = phone.interface == .wiredEthernet ? "Ethernet" : "Wi-Fi"
            return "Serving \(phone.url?.absoluteString ?? "") on \(network)."
        case .stopped:
            if phone.interface == nil { return "Waiting for a Wi-Fi or Ethernet connection." }
            return phone.devices.isEmpty ? "Not listening until you pair a phone." : "Starting…"
        }
    }

    private var statusIsProblem: Bool {
        if case .failed = phone.status { return true }
        return phone.hostChanged
    }

    private func trust(_ certificate: PhoneCertificate) -> some View {
        Section("1. Trust Warden on the phone") {
            Text("The phone checks Warden's certificate as it would a website's. Send it this Mac's profile once, install it in Settings → Profile Downloaded, then turn on Warden in Settings → General → About → Certificate Trust Settings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Send with AirDrop…") { phone.sendProfileWithAirDrop() }
                Button("Save Profile…") { phone.saveProfile() }
            }
            if phone.hostChanged {
                Text("This Mac's network name changed since the certificate was made, so phones cannot reach it. Make new certificates and send the new profile.")
                    .font(.caption).foregroundStyle(.red)
            }
            LabeledContent {
                Text(PhoneCertificate.fingerprint(certificate.root))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
            } label: {
                SettingLabel("SHA-256", detail: "Matches the fingerprint the phone shows under the profile's More Details.")
            }
            LabeledContent {
                Button("Make New…") { confirmRenew = true }
            } label: {
                SettingLabel("Valid for \(certificate.host.lowercased())",
                             detail: certificate.expiresAt.map { "Until \($0.formatted(date: .abbreviated, time: .omitted)). It can vouch for no other site." }
                                ?? "It can vouch for no other site.")
            }
        }
    }

    private var pairing: some View {
        Section("2. Pair the phone") {
            if let window = phone.pairing, let link = phone.pairingURL {
                HStack(alignment: .top, spacing: 16) {
                    if let image = Self.qrCode(link.absoluteString) {
                        Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150)
                            .accessibilityLabel("QR code to pair a phone")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan this code with the phone's camera and open the link.")
                        Text("In Warden added to the Home Screen, type \(window.code.prefix(3)) \(window.code.suffix(3)) instead.")
                            .foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, window.expiresAt.timeIntervalSince(context.date))
                            Text("Expires in \(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Button("Cancel") { phone.endPairing() }
                    }
                    .font(.callout)
                }
                .padding(.vertical, 4)
            } else {
                LabeledContent {
                    Button("Pair a Phone…") { phone.openPairing() }
                        .disabled(phone.interface == nil)
                } label: {
                    SettingLabel("Pair a phone", detail: "Shows a code that pairs one phone within five minutes. Five wrong tries close it.")
                }
                if let device = phone.justPaired {
                    Text("Paired \(device.name). Add the page to its Home Screen from the Share menu to open it like an app.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if phone.pairingFailed {
                    Text("The pairing closed after wrong tries. Pair again if that was you.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var paired: some View {
        if !phone.devices.isEmpty {
            Section("Paired phones") {
                ForEach(phone.devices) { device in
                    LabeledContent {
                        Button("Unpair") { phone.unpair(device) }
                    } label: {
                        SettingLabel(device.name, detail: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted)), last seen \(device.lastSeen.formatted(.relative(presentation: .named)))")
                    }
                }
            }
        }
    }

    /// A QR code, drawn with square pixels at any size.
    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
