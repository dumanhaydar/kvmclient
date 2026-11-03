import SwiftUI

@main
struct KVMUIApp: App {
    @State private var store = Screenshots.makeStore()
    #if os(macOS)
    @AppStorage("autoHidesToolbar") private var autoHidesToolbar = false
    @FocusedBinding(\.edgeToEdge) private var edgeToEdge
    #endif

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .environment(store)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle("Auto-Hide Toolbar", isOn: $autoHidesToolbar)
                Toggle("Full Screen Using Camera Area",
                       isOn: Binding(get: { edgeToEdge ?? false }, set: { edgeToEdge = $0 }))
                    .keyboardShortcut("f", modifiers: [.option, .command])
                    .disabled(edgeToEdge == nil)
            }
        }
        #endif
    }
}

extension FocusedValues {
    /// macOS: the focused session's screen covers the whole display, around the camera housing.
    @Entry var edgeToEdge: Binding<Bool>?
}
