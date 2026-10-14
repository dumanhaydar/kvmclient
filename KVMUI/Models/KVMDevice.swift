import Foundation

/// A saved KVM. The password lives in the Keychain, never in this struct.
struct KVMDevice: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Local network host or host:port, e.g. "10.1.0.16" or "picokvm.local".
    var host: String
    var useHTTPS = false
    /// nil until detected on first connection (or chosen by hand).
    var kind: DeviceKind?
    /// For firmwares with user accounts (PiKVM, NanoKVM, TinyPilot).
    var username: String?
    /// Remote keyboard layout used for typing text, when the device doesn't store it itself.
    var keyboardLayout: String?
    /// Address on the tailnet (100.x.y.z or MagicDNS name). Filled in automatically from the device.
    var tailscaleHost: String?
    /// Address on the ZeroTier network. Filled in automatically from the device.
    var zeroTierHost: String?

    /// Every configured way to reach the device, most preferred first.
    var routes: [Route] {
        [Route(kind: .local, host: host),
         tailscaleHost.map { Route(kind: .tailscale, host: $0) },
         zeroTierHost.map { Route(kind: .zeroTier, host: $0) }]
            .compactMap { $0 }
            .filter { !$0.host.isEmpty }
    }

    func baseURL(for route: Route) -> URL {
        URL(string: "\(useHTTPS ? "https" : "http")://\(route.host)")!
    }

}

/// One network path to a device.
struct Route: Hashable {
    enum Kind: String {
        case local, tailscale, zeroTier

        var title: String {
            switch self {
            case .local: "Réseau local"
            case .tailscale: "Tailscale"
            case .zeroTier: "ZeroTier"
            }
        }

        var systemImage: String {
            switch self {
            case .local: "wifi"
            case .tailscale: "point.3.connected.trianglepath.dotted"
            case .zeroTier: "network"
            }
        }
    }

    let kind: Kind
    let host: String
}
