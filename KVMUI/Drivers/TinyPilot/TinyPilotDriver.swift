import Foundation
import WebRTC

/// TinyPilot: optional login (CSRF-protected) → Flask `session` cookie, HID over Socket.IO
/// ("keystroke" / "mouse-event"), video via MJPEG or Janus H.264 when enabled in its settings.
@MainActor
final class TinyPilotDriver: KVMDriver {
    weak var delegate: KVMDriverDelegate?

    private let http: HTTPClient
    private var socket: SocketIOClient?
    private var janus: JanusStream?
    private var mjpeg: Task<Void, Never>?
    private var keys = KeyTransitionTracker()
    private var lastPointer: (x: Double, y: Double) = (0.5, 0.5)
    private var buttons = 0
    private var connected = false

    init(http: HTTPClient) {
        self.http = http
    }

    /// `/api/status` → `{}` and `/api/version` → `{"version"}` or a `{"message","code"}` error.
    static func detect(_ http: HTTPClient) async -> Bool {
        guard let status = try? await http.request("/api/status", timeout: 3), status.isSuccess,
              let json = status.json as? [String: Any], json.isEmpty,
              let version = try? await http.request("/api/version", timeout: 3),
              let info = version.json as? [String: Any] else { return false }
        return info["version"] is String || info["message"] is String
    }

    // MARK: Lifecycle

    func connect(credentials: Credentials) async throws {
        if try await http.request("/api/version").status == 401 {
            guard let user = credentials.username, !user.isEmpty,
                  let password = credentials.password, !password.isEmpty else {
                throw KVMError.credentialsRequired(nil)
            }
            delegate?.driver(progress: String(localized: "Signing in…"))
            try await login(user: user, password: password)
        }

        delegate?.driver(progress: String(localized: "Connecting keyboard and mouse…"))
        try await openSocket()

        // The page only loads the WebRTC player when H.264 is selected in TinyPilot's settings.
        let page = try? await http.request("/")
        let usesH264 = page.map { String(decoding: $0.data, as: UTF8.self).contains("webrtc-video") } ?? false
        if usesH264 { startJanus() } else { startMJPEG() }
    }

    private func login(user: String, password: String) async throws {
        // Flask-WTF: the CSRF token lives in the login page and is bound to its session cookie.
        let page = try await http.request("/login")
        let html = String(decoding: page.data, as: UTF8.self)
        guard let token = Self.csrfToken(in: html) else {
            throw KVMError.protocolError(String(localized: "CSRF token not found on the TinyPilot login page."))
        }
        let response = try await http.request("/api/auth", method: "POST", json: ["username": user, "password": password],
                                              headers: ["X-CSRFToken": token])
        guard response.isSuccess else {
            let message = (response.json as? [String: Any])?["message"] as? String
            throw KVMError.credentialsRequired(response.status == 429 ? String(localized: "Too many attempts, try again in a minute.") : message)
        }
    }

    private static func csrfToken(in html: String) -> String? {
        guard let meta = html.range(of: #"<meta name="csrf-token" content=""#) else { return nil }
        let rest = html[meta.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    func disconnect() {
        socket?.close()
        socket = nil
        janus?.stop()
        janus = nil
        mjpeg?.cancel()
        mjpeg = nil
        connected = false
    }

    private func markConnected() {
        guard !connected else { return }
        connected = true
        delegate?.driverDidConnect()
    }

    // MARK: Socket.IO

    private func openSocket() async throws {
        let socket = SocketIOClient(http: http)
        self.socket = socket
        let result: String? = await withCheckedContinuation { continuation in
            var resumed = false
            socket.onConnect = {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
            socket.onDisconnect = { [weak self] reason in
                if !resumed {
                    resumed = true
                    continuation.resume(returning: reason)
                } else if self?.socket === socket {
                    self?.delegate?.driver(didFail: KVMError.protocolError(reason))
                }
            }
            socket.open()
        }
        if let result { throw KVMError.credentialsRequired(String(localized: "TinyPilot refused the connection: \(result)")) }
    }

    // MARK: Video

    private func startJanus() {
        delegate?.driver(progress: String(localized: "Starting the H.264 stream…"))
        let janus = JanusStream(http: http, watchParams: ["audio": false], queryFeatures: false)
        janus.onTrack = { [weak self] track in self?.delegate?.driver(video: .webRTC(track)) }
        janus.onConnected = { [weak self] in self?.markConnected() }
        janus.onFailure = { [weak self] message in
            print("[tinypilot] Janus failed (\(message)), falling back to MJPEG")
            self?.janus = nil
            self?.startMJPEG()
        }
        self.janus = janus
        janus.start()
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
        delegate?.driver(video: .frames(frames))
        let stream = http.stream("/stream", query: ["advance_headers": "1"])
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
    //
    // TinyPilot types a non-modifier key as press + immediate release, holds modifiers, and
    // "keyRelease" lets go of everything. There's no key hold / auto-repeat.

    func sendKeyboard(keys report: [UInt8], modifier: UInt8) {
        let changes = keys.update(keys: report, modifier: modifier)
        if changes.released.contains(where: KeyboardState.isModifier) {
            socket?.emit("keyRelease")
        }
        for usage in changes.pressed {
            emitKeystroke(usage, modifier: modifier)
        }
    }

    func sendKeyboardAndWait(keys report: [UInt8], modifier: UInt8) async {
        let changes = keys.update(keys: report, modifier: modifier)
        if changes.released.contains(where: KeyboardState.isModifier) {
            socket?.emit("keyRelease")
        }
        for usage in changes.pressed {
            _ = await socket?.emitAndWait("keystroke", keystroke(usage, modifier: modifier))
        }
    }

    private func emitKeystroke(_ usage: UInt8, modifier: UInt8) {
        guard let payload = keystroke(usage, modifier: modifier) else { return }
        socket?.emit("keystroke", payload)
    }

    private func keystroke(_ usage: UInt8, modifier: UInt8) -> [String: Any]? {
        guard let code = WebKeyCodes.code(for: usage) else { return nil }
        func bit(_ index: UInt8) -> Bool { modifier & (1 << index) != 0 }
        return [
            "ctrlLeft": bit(0), "shiftLeft": bit(1), "altLeft": bit(2), "metaLeft": bit(3),
            "ctrlRight": bit(4), "shiftRight": bit(5), "altRight": bit(6), "metaRight": bit(7),
            "key": code, "code": code,
        ]
    }

    func sendAbsoluteMouse(x: Int, y: Int, buttons: Int) {
        lastPointer = (Double(x) / 32767, Double(y) / 32767)
        self.buttons = buttons
        emitMouse(wheel: 0)
    }

    func sendWheel(_ delta: Int) {
        // TinyPilot takes the sign of the DOM deltaY (positive = down); ours is positive = up.
        emitMouse(wheel: delta > 0 ? -1 : 1)
    }

    private func emitMouse(wheel: Int) {
        socket?.emit("mouse-event", [
            "buttons": buttons,
            "relativeX": lastPointer.x,
            "relativeY": lastPointer.y,
            "verticalWheelDelta": wheel,
            "horizontalWheelDelta": 0,
        ])
    }
}
