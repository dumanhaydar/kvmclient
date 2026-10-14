import SwiftUI

@main
struct KVMUIApp: App {
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            DeviceListView()
                .environment(store)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        #endif
    }
}
