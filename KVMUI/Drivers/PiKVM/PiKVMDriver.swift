import Foundation
import WebRTC

/// PiKVM `kvmd` (also BliKVM, Geekworm and other PiKVM-based devices): form login → `auth_token`
/// cookie, JSON events over `/api/ws` for HID and state, video via Janus H.264 or MJPEG.
@MainActor
final class PiKVMDriver: KVMDriver {
    weak var delegate: KVMDriverDelegate?

    private let http: HTTPClient
    private var socket: WebSocketConnection?
    private var ping: Task<Void, Never>?
    private var janus: JanusStream?
    private var mjpeg: Task<Void, Never>?
    private var frames: FrameStream?
    private var keys = KeyTransitionTracker()
    private var buttons = 0
    private var supportsH264: Bool?
    private var connected = false

    init(http: HTTPClient) {
        self.http = http
    }

    /// `/api/auth/check` answers with kvmd's `{"ok": ..., "result": ...}` envelope, auth or not.
    static func detect(_ http: HTTPClient) async -> Bool {
        guard let response = try? await http.request("/api/auth/check", timeout: 3),
              let json = response.json as? [String: Any] else { return false }
        return json["ok"] is Bool && json["result"] is [String: Any]
    }

    // MARK: Lifecycle

    func connect(credentials: Credentials) async throws {
        if try await http.request("/api/auth/check").status != 200 {
            guard let user = credentials.username, let password = credentials.password, !password.isEmpty else {
                throw KVMError.credentialsRequired(nil)
            }
            delegate?.driver(progress: String(localized: "Signing in…"))
            // With 2FA enabled, kvmd expects the TOTP code appended to the password.
            let login = try await http.request("/api/auth/login", method: "POST",
                                               form: ["user": user, "passwd": password, "expire": "0"])
            guard login.isSuccess else {
                throw KVMError.credentialsRequired(login.status == 403
                    ? String(localized: "Invalid credentials (with 2FA, append the 6-digit code to the password).")
                    : Self.errorMessage(login))
            }
        }

        delegate?.driver(progress: String(localized: "Opening the session…"))
        openSocket()
        // The first "streamer" event tells whether H.264 is available; don't wait forever for it.
        for _ in 0..<30 where supportsH264 == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if supportsH264 == true {
            startJanus()
        } else {
            startMJPEG()
        }
    }

    func disconnect() {
        ping?.cancel()
        socket?.close()
        socket = nil
        janus?.stop()
        janus = nil
        mjpeg?.cancel()
        mjpeg = nil
        frames = nil
        connected = false
    }

    private static func errorMessage(_ response: HTTPClient.Response) -> String {
        let result = (response.json as? [String: Any])?["result"] as? [String: Any]
        return result?["error_msg"] as? String ?? String(localized: "Connection refused (HTTP \(response.status)).")
    }

    private func markConnected() {
        guard !connected else { return }
        connected = true
        delegate?.driverDidConnect()
    }

    // MARK: Events socket (also keeps the streamer running)

    private func openSocket() {
        let socket = WebSocketConnection(task: http.webSocket("/api/ws", query: ["stream": "1"]))
        socket.onText = { [weak self] text in
            Task { @MainActor in self?.handleEvent(text) }
        }
        socket.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                self.delegate?.driver(didFail: KVMError.protocolError(String(localized: "PiKVM session closed: \(error?.localizedDescription ?? "?")")))
            }
        }
        self.socket = socket
        socket.open()
        ping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.send("ping", [:])
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["event_type"] as? String,
              let event = json["event"] as? [String: Any] else { return }
        guard type == "streamer" else { return }
        if let features = event["features"] as? [String: Any], let h264 = features["h264"] as? Bool {
            supportsH264 = h264
        }
        // Partial updates omit unchanged keys; only react to what's present.
        if event.keys.contains("streamer") {
            let source = (event["streamer"] as? [String: Any])?["source"] as? [String: Any]
            if let resolution = source?["resolution"] as? [String: Any],
               let width = resolution["width"] as? Double, let height = resolution["height"] as? Double, width > 0 {
                delegate?.driver(sourceSize: CGSize(width: width, height: height))
            }
            if let online = source?["online"] as? Bool {
                delegate?.driver(videoError: online ? nil : "no_signal")
            }
        }
    }

    private func send(_ type: String, _ event: [String: Any]) {
        socket?.sendJSON(["event_type": type, "event": event])
    }

    // MARK: Video

    private func startJanus() {
        delegate?.driver(progress: String(localized: "Starting the H.264 stream…"))
        let janus = JanusStream(http: http,
                                watchParams: ["orientation": 0, "audio": false, "mic": false, "camera": false],
                                queryFeatures: true)
        janus.onTrack = { [weak self] track in self?.delegate?.driver(video: .webRTC(track)) }
        janus.onConnected = { [weak self] in self?.markConnected() }
        janus.onFailure = { [weak self] message in
            guard let self else { return }
            print("[pikvm] Janus failed (\(message)), falling back to MJPEG")
            self.janus = nil
            self.startMJPEG()
        }
        self.janus = janus
        janus.start()
        // Some setups never deliver H.264 (no Janus); don't hang on it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !self.connected, self.janus === janus else { return }
            janus.stop()
            self.janus = nil
            self.startMJPEG()
        }
    }

    private func startMJPEG() {
        guard mjpeg == nil else { return }
        let frames = FrameStream()
        self.frames = frames
        delegate?.driver(video: .frames(frames))
        let stream = http.stream("/streamer/stream", query: ["key": UUID().uuidString, "advance_headers": "1"])
        mjpeg = Task { [weak self] in
            do {
                for try await chunk in stream {
                    frames.pushMJPEG(chunk)
                    self?.markConnected()
                }
                self?.delegate?.driver(didFail: KVMError.protocolError(String(localized: "Video stream ended.")))
            } catch is CancellationError {
            } catch {
                self?.delegate?.driver(didFail: error)
            }
        }
    }

    // MARK: HID

    func sendKeyboard(keys report: [UInt8], modifier: UInt8) {
        let changes = keys.update(keys: report, modifier: modifier)
        for usage in changes.released { sendKey(usage, down: false) }
        for usage in changes.pressed { sendKey(usage, down: true) }
    }

    private func sendKey(_ usage: UInt8, down: Bool) {
        guard let code = WebKeyCodes.code(for: usage) else { return }
        send("key", ["key": code, "state": down])
    }

    func sendAbsoluteMouse(x: Int, y: Int, buttons newButtons: Int) {
        // kvmd's absolute range is -32768...32767.
        let px = x * 65535 / 32767 - 32768, py = y * 65535 / 32767 - 32768
        send("mouse_move", ["to": ["x": px, "y": py]])
        for (bit, name) in [(1, "left"), (2, "right"), (4, "middle")] where (buttons ^ newButtons) & bit != 0 {
            send("mouse_button", ["button": name, "state": newButtons & bit != 0])
        }
        buttons = newButtons
    }

    func sendWheel(_ delta: Int) {
        send("mouse_wheel", ["delta": ["x": 0, "y": max(-127, min(127, delta))]])
    }
}
