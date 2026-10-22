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
                            Text("Searching \(scanner.networks.joined(separator: ", "))…")
                            ProgressView(value: scanner.progress)
                        }
                        .textCase(nil)
                    }
                } footer: {
                    Text("JetKVM, PicoKVM, PiKVM, NanoKVM and TinyPilot are recognized. KVMs reachable only through Tailscale or ZeroTier must be added by hand.")
                }
            }
            .overlay {
                if !scanner.isScanning && scanner.found.isEmpty {
                    ContentUnavailableView {
                        Label("No KVMs Found", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        if scanner.isBlocked {
                            Text("Local network access is denied. Allow KVM Client in Settings › Privacy & Security › Local Network, then search again.")
                        } else if scanner.networks.isEmpty {
                            Text("No active local network. Join the KVM's Wi-Fi or Ethernet network.")
                        } else {
                            Text("Nothing on \(scanner.networks.joined(separator: ", ")). Check that the KVM is on and on the same network.")
                        }
                    } actions: {
                        Button("Search Again") { scanner.start() }
                        if !store.devices.contains(where: \.isDemo) {
                            Button("Try the Demo", action: onDemo)
                        }
                    }
                }
            }
            .navigationTitle("Find KVMs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Search Again", systemImage: "arrow.clockwise") { scanner.start() }
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
                Text("Already added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    draft = KVMDevice(name: found.suggestedName, host: found.host, useHTTPS: found.useHTTPS, kind: found.kind)
                }
            }
        }
    }
}
