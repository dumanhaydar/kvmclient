import Foundation
#if os(iOS)
import UIKit
#endif

/// Launch arguments used to stage the App Store screenshots (Debug builds only):
///
///     -screenshots            sample devices in a throwaway store (the real one is untouched)
///     -empty                  start with no devices (empty state)
///     -openDemo               open the demo device right away
///     -orientation landscape  iOS: rotate to landscape (or portrait)
///     -keyboard               iOS: show the virtual keyboard once connected
///     -sidebar                keep the device list visible once connected
///     -demoCommand neofetch   run a command in the demo terminal
enum Screenshots {
    #if DEBUG
    static let isActive = ProcessInfo.processInfo.arguments.contains("-screenshots")
    #else
    static let isActive = false
    #endif

    static var opensDemo: Bool { flag("-openDemo") }
    static var showsKeyboard: Bool { flag("-keyboard") }
    static var keepsSidebar: Bool { flag("-sidebar") }

    static var demoCommand: String? { value("-demoCommand") }

    private static func flag(_ name: String) -> Bool {
        isActive && ProcessInfo.processInfo.arguments.contains(name)
    }

    private static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard isActive, let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func makeStore() -> DeviceStore {
        guard isActive, let defaults = UserDefaults(suiteName: "com.aroneus.kvmclient.screenshots") else { return DeviceStore() }
        defaults.removePersistentDomain(forName: "com.aroneus.kvmclient.screenshots")
        let store = DeviceStore(defaults: defaults)
        if flag("-empty") { return store }
        store.addDemo()
        let samples = [
            KVMDevice(name: String(localized: "NAS Server"), host: "192.168.1.20", kind: .jetKVM, tailscaleHost: "nas-kvm.tail4f2a.ts.net"),
            KVMDevice(name: String(localized: "Workshop"), host: "192.168.1.31", useHTTPS: true, kind: .piKVM, username: "admin"),
            KVMDevice(name: String(localized: "Office Rack"), host: "10.0.0.12", kind: .nanoKVM, zeroTierHost: "10.147.17.5"),
            KVMDevice(name: String(localized: "Living Room PC"), host: "192.168.1.44", kind: .tinyPilot),
        ]
        for device in samples { store.save(device, password: nil) }
        return store
    }

    @MainActor
    static func applyOrientation() {
        #if os(iOS)
        guard let orientation = value("-orientation"),
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        // iPhone only: iPad windows ignore it.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation == "portrait" ? .portrait : .landscapeRight))
        #endif
    }
}
