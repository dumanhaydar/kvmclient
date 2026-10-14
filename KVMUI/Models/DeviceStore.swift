import Foundation
import Observation

@Observable
final class DeviceStore {
    private static let defaultsKey = "devices"

    private(set) var devices: [KVMDevice] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
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

    func delete(_ device: KVMDevice) {
        devices.removeAll { $0.id == device.id }
        Keychain.deletePassword(for: device.id)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
