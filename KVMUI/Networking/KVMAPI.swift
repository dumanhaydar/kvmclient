import Foundation

enum KVMError: LocalizedError {
    case notSetUp
    case unauthorized
    case loginFailed(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notSetUp: "Le KVM n'est pas encore configuré. Termine la configuration via l'interface web."
        case .unauthorized: "Mot de passe requis."
        case .loginFailed(let message): message
        case .badResponse(let code): "Réponse inattendue du KVM (HTTP \(code))."
        }
    }
}

/// HTTP endpoints of the PicoKVM (JetKVM-derived) firmware.
/// Auth is a cookie set by `/auth/login-local`, kept in this client's private cookie store
/// and reused by the signaling WebSocket.
final class KVMAPI: NSObject, URLSessionDelegate {
    let device: KVMDevice
    let route: Route
    let baseURL: URL
    private(set) var session: URLSession!

    init(device: KVMDevice, route: Route) {
        self.device = device
        self.route = route
        baseURL = device.baseURL(for: route)
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    struct Status: Decodable { let isSetup: Bool }
    struct DeviceInfo: Decodable { let authMode: String? }

    func status() async throws -> Status {
        try await get("/device/status")
    }

    /// Quick reachability check used to pick a route; doesn't need auth.
    func probe(timeout: TimeInterval = 2.5) async -> Bool {
        var request = URLRequest(url: url("/device/status"))
        request.timeoutInterval = timeout
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Returns nil when the session isn't authenticated yet.
    func deviceInfo() async throws -> DeviceInfo? {
        let (data, response) = try await session.data(from: url("/device"))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { return nil }
        guard (200..<300).contains(code) else { throw KVMError.badResponse(code) }
        return try JSONDecoder().decode(DeviceInfo.self, from: data)
    }

    func login(password: String) async throws {
        var request = URLRequest(url: url("/auth/login-local"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["password": password])
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw KVMError.loginFailed(message ?? "Mot de passe invalide.")
        }
    }

    struct ICEServer {
        var urls: [String]
        var username: String?
        var credential: String?
    }

    /// Falls back to no ICE servers: on a LAN, host candidates are enough.
    func iceServers() async -> [ICEServer] {
        guard let (data, _) = try? await session.data(from: url("/api/ice-servers")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["iceServers"] as? [[String: Any]] else { return [] }
        return servers.compactMap { server in
            let urls = (server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] }
            guard let urls, !urls.isEmpty else { return nil }
            return ICEServer(urls: urls,
                             username: server["username"] as? String,
                             credential: server["credential"] as? String)
        }
    }

    /// Legacy signaling (firmware without the WebSocket): POST the complete offer, get the answer back.
    /// Both are base64-encoded `{"type", "sdp"}` JSON.
    func legacySession(offer: String) async throws -> String {
        var request = URLRequest(url: url("/webrtc/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["sd": offer])
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw KVMError.unauthorized }
        guard (200..<300).contains(code),
              let answer = try JSONDecoder().decode([String: String].self, from: data)["sd"] else {
            throw KVMError.badResponse(code)
        }
        return answer
    }

    func url(_ path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: url(path))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw KVMError.unauthorized }
        guard (200..<300).contains(code) else { throw KVMError.badResponse(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // The KVM serves HTTPS with a self-signed certificate; trust it for this host only.
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           device.useHTTPS,
           challenge.protectionSpace.host == baseURL.host(),
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}
