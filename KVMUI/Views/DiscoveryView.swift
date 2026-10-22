import SwiftUI

/// Sweeps the local network for KVMs and offers to add the ones found.
struct DiscoveryView: View {
    let onAdd: (KVMDevice, String?) -> Void
    /// Offered when nothing is found, so the app can still be tried.
    let onDemo: () -> Void

    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = LANScanner()
    @State private var draft: KVMDevice?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(scanner.found) { found in
                        row(found)
                    }
                } header: {
                    if scanner.isScanning {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recherche sur \(scanner.networks.joined(separator: ", "))…")
                            ProgressView(value: scanner.progress)
                        }
                        .textCase(nil)
                    }
                } footer: {
                    Text("JetKVM, PicoKVM, PiKVM, NanoKVM et TinyPilot sont reconnus. Les KVM joignables uniquement par Tailscale ou ZeroTier s'ajoutent à la main.")
                }
            }
            .overlay {
                if !scanner.isScanning && scanner.found.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun KVM trouvé", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text(scanner.isBlocked
                             ? "L'accès au réseau local est refusé. Autorise KVM Client dans Réglages › Confidentialité et sécurité › Réseau local, puis relance."
                             : scanner.networks.isEmpty
                             ? "Aucun réseau local actif. Connecte-toi au Wi-Fi ou à l'Ethernet du KVM."
                             : "Rien sur \(scanner.networks.joined(separator: ", ")). Vérifie que le KVM est allumé et sur le même réseau.")
                    } actions: {
                        Button("Relancer") { scanner.start() }
                        if !store.devices.contains(where: \.isDemo) {
                            Button("Essayer la démo", action: onDemo)
                        }
                    }
                }
            }
            .navigationTitle("Rechercher des KVM")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Relancer", systemImage: "arrow.clockwise") { scanner.start() }
                        .disabled(scanner.isScanning)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .sheet(item: $draft) { draft in
            DeviceEditorView(device: nil, draft: draft, onSave: onAdd)
        }
    }

    private func row(_ found: LANScanner.Found) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(found.suggestedName)
                    Text("\(found.kind.title) · \(found.hostname ?? found.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "display")
            }
            Spacer()
            if store.devices.contains(where: { $0.routes.contains { $0.host == found.host } }) {
                Text("Déjà ajouté")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Ajouter") {
                    draft = KVMDevice(name: found.suggestedName, host: found.host, useHTTPS: found.useHTTPS, kind: found.kind)
                }
            }
        }
    }
}
