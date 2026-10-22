import SwiftUI

struct DeviceEditorView: View {
    let device: KVMDevice?
    /// Prefilled values for a new device (e.g. one found on the network).
    var draft: KVMDevice?
    let onSave: (KVMDevice, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var useHTTPS = false
    @State private var password = ""
    @State private var kind: DeviceKind?
    @State private var username = ""
    @State private var tailscaleHost = ""
    @State private var zeroTierHost = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name, prompt: Text("My KVM"))
                TextField("Address", text: $host, prompt: Text("192.168.1.50 or kvm.local"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Toggle("HTTPS (self-signed certificate)", isOn: $useHTTPS)
                Picker("Type", selection: $kind) {
                    Text("Automatic Detection").tag(DeviceKind?.none)
                    ForEach(DeviceKind.allCases) { kind in
                        Text(kind.title).tag(DeviceKind?.some(kind))
                    }
                }
                if kind?.usesUsername ?? true, kind != .jetKVM {
                    TextField("User Name", text: $username, prompt: Text(kind?.defaultUsername ?? "admin"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                SecureField("Password", text: $password,
                            prompt: device == nil ? Text("Optional") : Text("Unchanged if empty"))

                Section {
                    TextField("Tailscale", text: $tailscaleHost, prompt: Text("100.x.y.z or MagicDNS name"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("ZeroTier", text: $zeroTierHost, prompt: Text("ZeroTier address"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Remote Access")
                } footer: {
                    Text("Filled in automatically after connecting if Tailscale or ZeroTier is enabled on the KVM. The app tries the local network first, then these addresses. Tailscale or ZeroTier must also be running on this device.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(device == nil ? Text("New KVM") : Text("Edit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = device ?? draft ?? KVMDevice(name: "", host: "")
                        saved.name = name.isEmpty ? (kind?.shortTitle ?? "KVM") : name
                        saved.kind = kind
                        saved.username = Self.optional(username)
                        saved.host = host.trimmingCharacters(in: .whitespaces)
                        saved.useHTTPS = useHTTPS
                        saved.tailscaleHost = Self.optional(tailscaleHost)
                        saved.zeroTierHost = Self.optional(zeroTierHost)
                        onSave(saved, password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 460)
        #endif
        .onAppear {
            let device = device ?? draft
            name = device?.name ?? ""
            host = device?.host ?? ""
            useHTTPS = device?.useHTTPS ?? false
            kind = device?.kind
            username = device?.username ?? ""
            tailscaleHost = device?.tailscaleHost ?? ""
            zeroTierHost = device?.zeroTierHost ?? ""
        }
    }

    private static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
