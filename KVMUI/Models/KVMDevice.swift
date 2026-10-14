import Foundation

/// A saved PicoKVM. The password lives in the Keychain, never in this struct.
struct KVMDevice: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Host or host:port, e.g. "10.1.0.16" or "picokvm.local".
    var host: String
    var useHTTPS = false

    var baseURL: URL {
        URL(string: "\(useHTTPS ? "https" : "http")://\(host)")!
    }

    var signalingURL: URL {
        URL(string: "\(useHTTPS ? "wss" : "ws")://\(host)/webrtc/signaling/client")!
    }
}
