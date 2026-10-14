import SwiftUI

struct DeviceEditorView: View {
    let device: KVMDevice?
    let onSave: (KVMDevice, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var useHTTPS = false
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom", text: $name, prompt: Text("PicoKVM"))
                TextField("Adresse", text: $host, prompt: Text("10.1.0.16"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Toggle("HTTPS (certificat auto-signé)", isOn: $useHTTPS)
                SecureField("Mot de passe", text: $password,
                            prompt: Text(device == nil ? "Optionnel" : "Inchangé si vide"))
            }
            .formStyle(.grouped)
            .navigationTitle(device == nil ? "Nouveau KVM" : "Modifier")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        var saved = device ?? KVMDevice(name: "", host: "")
                        saved.name = name.isEmpty ? "PicoKVM" : name
                        saved.host = host.trimmingCharacters(in: .whitespaces)
                        saved.useHTTPS = useHTTPS
                        onSave(saved, password.isEmpty ? nil : password)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 240)
        #endif
        .onAppear {
            name = device?.name ?? ""
            host = device?.host ?? ""
            useHTTPS = device?.useHTTPS ?? false
        }
    }
}
