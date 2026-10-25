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
                                    device.isDemo ? Text("Demo device") : Text(device.host)
                                    ForEach(device.routes.dropFirst(), id: \.self) { route in
                                        Image(systemName: route.kind.systemImage)
                                            .help("\(route.kind.title): \(route.host)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: device.isDemo ? "play.display" : "display")
                        }
                    }
                    .contextMenu {
                        Button("Edit…") { editing = device }
                        Button("Delete", role: .destructive) { store.delete(device) }
                    }
                }
            }
            .navigationTitle("KVM")
            .toolbar {
                ToolbarItem {
                    Button("Search the Network", systemImage: "dot.radiowaves.left.and.right") { isDiscovering = true }
                }
                ToolbarItem {
                    Button("Add", systemImage: "plus") { isAdding = true }
                }
            }
            .overlay {
                if store.devices.isEmpty {
                    ContentUnavailableView {
                        Label("No KVMs", systemImage: "display")
                    } description: {
                        Text("No KVM at hand? The demo simulates a server you can control.")
                    } actions: {
                        // Stacked: macOS lays actions out in a row, wider than the sidebar.
                        VStack {
                            Button("Search the Network") { isDiscovering = true }
                                .buttonStyle(.borderedProminent)
                            Button("Add Manually") { isAdding = true }
                            Button("Try the Demo") { selection = store.addDemo().id }
                        }
                    }
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 260, ideal: 280)
            #endif
        } detail: {
            if let device = store.devices.first(where: { $0.id == selection }) {
                SessionView(device: device, columnVisibility: $columnVisibility)
                    .id(device.id)
            } else {
                ContentUnavailableView("Select a KVM", systemImage: "cursorarrow.rays")
            }
        }
        .task {
            Screenshots.applyOrientation()
            if Screenshots.opensDemo { selection = store.devices.first(where: \.isDemo)?.id }
            if Screenshots.keepsSidebar { columnVisibility = .all }
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
            } onDemo: {
                isDiscovering = false
                selection = store.addDemo().id
            }
        }
        .sheet(item: $editing) { device in
            DeviceEditorView(device: device) { device, password in
                store.save(device, password: password)
            }
        }
    }
}
