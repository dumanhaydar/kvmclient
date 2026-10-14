import SwiftUI

struct DeviceListView: View {
    @Environment(DeviceStore.self) private var store
    @State private var selection: KVMDevice.ID?
    @State private var editing: KVMDevice?
    @State private var isAdding = false
    @State private var isDiscovering = false
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                ForEach(store.devices) { device in
                    NavigationLink(value: device.id) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                HStack(spacing: 4) {
                                    Text(device.host)
                                    ForEach(device.routes.dropFirst(), id: \.self) { route in
                                        Image(systemName: route.kind.systemImage)
                                            .help("\(route.kind.title) : \(route.host)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "display")
                        }
                    }
                    .contextMenu {
                        Button("Modifier…") { editing = device }
                        Button("Supprimer", role: .destructive) { store.delete(device) }
                    }
                }
            }
            .navigationTitle("KVM")
            .toolbar {
                ToolbarItem {
                    Button("Rechercher sur le réseau", systemImage: "dot.radiowaves.left.and.right") { isDiscovering = true }
                }
                ToolbarItem {
                    Button("Ajouter", systemImage: "plus") { isAdding = true }
                }
            }
            .overlay {
                if store.devices.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun KVM", systemImage: "display")
                    } actions: {
                        Button("Rechercher sur le réseau") { isDiscovering = true }
                            .buttonStyle(.borderedProminent)
                        Button("Ajouter à la main") { isAdding = true }
                    }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            #endif
        } detail: {
            if let device = store.devices.first(where: { $0.id == selection }) {
                SessionView(device: device, columnVisibility: $columnVisibility)
                    .id(device.id)
            } else {
                ContentUnavailableView("Sélectionne un KVM", systemImage: "cursorarrow.rays")
            }
        }
        .sheet(isPresented: $isAdding) {
            DeviceEditorView(device: nil) { device, password in
                store.save(device, password: password)
                selection = device.id
            }
        }
        .sheet(isPresented: $isDiscovering) {
            DiscoveryView { device, password in
                store.save(device, password: password)
                selection = device.id
            }
        }
        .sheet(item: $editing) { device in
            DeviceEditorView(device: device) { device, password in
                store.save(device, password: password)
            }
        }
    }
}
