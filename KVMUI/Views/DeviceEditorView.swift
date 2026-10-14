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
                TextField("Nom", text: $name, prompt: Text("Mon KVM"))
                TextField("Adresse", text: $host, prompt: Text("192.168.1.50 ou kvm.local"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Toggle("HTTPS (certificat auto-signé)", isOn: $useHTTPS)
                Picker("Type", selection: $kind) {
                    Text("Détection automatique").tag(DeviceKind?.none)
                    ForEach(DeviceKind.allCases) { kind in
                        Text(kind.title).tag(DeviceKind?.some(kind))
                    }
                }
                if kind?.usesUsername ?? true, kind != .jetKVM {
                    TextField("Utilisateur", text: $username, prompt: Text(kind?.defaultUsername ?? "admin"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                SecureField("Mot de passe", text: $password,
                            prompt: Text(device == nil ? "Optionnel" : "Inchangé si vide"))

                Section {
                    TextField("Tailscale", text: $tailscaleHost, prompt: Text("100.x.y.z ou nom MagicDNS"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("ZeroTier", text: $zeroTierHost, prompt: Text("Adresse ZeroTier"))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                } header: {
                    Text("Accès à distance")
                } footer: {
                    Text("Remplies automatiquement après une connexion si Tailscale ou ZeroTier est activé sur le KVM. L'app essaie le réseau local en premier, puis ces adresses. Tailscale ou ZeroTier doit aussi tourner sur cet appareil.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(device == nil ? "Nouveau KVM" : "Modifier")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
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
