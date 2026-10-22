import Foundation
import Observation

@Observable
final class DeviceStore {
    private static let defaultsKey = "devices"

    private(set) var devices: [KVMDevice] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([KVMDevice].self, from: data) {
            devices = decoded
        }
    }

    func save(_ device: KVMDevice, password: String?) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        if let password {
            Keychain.setPassword(password, for: device.id)
        }
        persist()
    }

    /// Merges an address reported by the device. Hand-entered names (e.g. MagicDNS) are kept;
    /// empty fields and stale IPs are replaced.
    static func merge(_ current: String?, _ reported: String?) -> String? {
        guard let reported else { return current }
        guard let current, !current.isEmpty else { return reported }
        return isIPAddress(current) ? reported : current
    }

    private static func isIPAddress(_ host: String) -> Bool {
        host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
            || host.contains(":") && host.allSatisfy { $0.isHexDigit || $0 == ":" }
    }

    /// Saves what a session learned (detected kind, user name, overlay addresses, layout)
    /// without touching the password.
    func update(_ device: KVMDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }), devices[index] != device else { return }
        devices[index] = device
        persist()
    }

    /// Adds the demo device unless it's already there; returns it.
    @discardableResult
    func addDemo() -> KVMDevice {
        if let demo = devices.first(where: \.isDemo) { return demo }
        let demo = KVMDevice.demo()
        save(demo, password: nil)
        return demo
    }

    func delete(_ device: KVMDevice) {
        devices.removeAll { $0.id == device.id }
        Keychain.deletePassword(for: device.id)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
