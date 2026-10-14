import CommonCrypto
import CryptoKit
import Foundation

/// Sipeed NanoKVM (and NanoKVM-Pro): JSON login → `nano-kvm-token` cookie, binary HID reports
/// over `/api/ws`, H.264 access units over `/api/stream/h264/direct` (MJPEG as a fallback).
@MainActor
final class NanoKVMDriver: KVMDriver {
    weak var delegate: KVMDriverDelegate?

    private let http: HTTPClient
    private var hid: WebSocketConnection?
    private var videoSocket: WebSocketConnection?
    private var mjpeg: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pointer: (x: Int, y: Int) = (16384, 16384)
    private var buttons = 0
    private var connected = false

    init(http: HTTPClient) {
        self.http = http
    }

    /// Unauthenticated `/api/vm/info` answers 401 with the bare JSON string "unauthorized";
    /// authenticated (or auth disabled), the `{code, msg, data}` envelope.
    static func detect(_ http: HTTPClient) async -> Bool {
        guard let response = try? await http.request("/api/vm/info", timeout: 3) else { return false }
        let body = String(decoding: response.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if response.status == 401 { return body == "\"unauthorized\"" }
        guard let json = response.json as? [String: Any] else { return false }
        return json["code"] is Int && json["msg"] is String
    }

    // MARK: Lifecycle

    func connect(credentials: Credentials) async throws {
        if try await http.request("/api/vm/info").status == 401 {
            guard let user = credentials.username, !user.isEmpty,
                  let password = credentials.password, !password.isEmpty else {
                throw KVMError.credentialsRequired(nil)
            }
            delegate?.driver(progress: "Authentification…")
            try await login(user: user, password: password)
        }

        delegate?.driver(progress: "Connexion du clavier et de la souris…")
        openHID()
        startH264()
    }

    /// NanoKVM encrypts the password CryptoJS-style; NanoKVM-Pro takes it in clear. Try both.
    private func login(user: String, password: String) async throws {
        var lastMessage: String?
        for candidate in [Self.cryptoJSEncrypt(password), password].compactMap({ $0 }) {
            let response = try await http.request("/api/auth/login", method: "POST", json: ["username": user, "password": candidate])
            let json = response.json as? [String: Any]
            let code = json?["code"] as? Int ?? -1
            if response.isSuccess, code == 0 {
                // Pro returns the token in the body and lets the page set the cookie.
                if let token = (json?["data"] as? [String: Any])?["token"] as? String {
                    http.setCookie(name: "nano-kvm-token", value: token)
                }
                return
            }
            lastMessage = json?["msg"] as? String
            if code == -4 || code == -5 { break } // locked out: don't make it worse
        }
        throw KVMError.credentialsRequired(lastMessage.map { "Connexion refusée : \($0)" } ?? "Identifiants invalides.")
    }

    func disconnect() {
        heartbeat?.cancel()
        hid?.close()
        hid = nil
        videoSocket?.close()
        videoSocket = nil
        mjpeg?.cancel()
        mjpeg = nil
        connected = false
    }

    private func markConnected() {
        guard !connected else { return }
        connected = true
        delegate?.driverDidConnect()
    }

    // MARK: HID socket

    private func openHID() {
        let socket = WebSocketConnection(task: http.webSocket("/api/ws"))
        socket.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self, self.hid === socket else { return }
                self.delegate?.driver(didFail: KVMError.protocolError("Session NanoKVM fermée : \(error?.localizedDescription ?? "?")"))
            }
        }
        hid = socket
        socket.open()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.hid?.send(Data([0x00]))
            }
        }
    }

    // MARK: Video

    private func startH264() {
        let frames = FrameStream()
        delegate?.driver(video: .frames(frames))
        // Ask for the H.264 encoder (the web UI does this when switching modes); harmless if refused.
        Task { _ = try? await http.request("/api/vm/screen", method: "POST", json: ["type": "type", "value": 1]) }

        let socket = WebSocketConnection(task: http.webSocket("/api/stream/h264/direct"))
        socket.onData = { [weak self] message in
            // [isKey u8][timestamp u64 LE][Annex B access unit]
            guard message.count > 9 else { return }
            frames.pushH264(message.subdata(in: (message.startIndex + 9)..<message.endIndex), completeFrame: true)
            Task { @MainActor in self?.markConnected() }
        }
        socket.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self, self.videoSocket === socket else { return }
                self.videoSocket = nil
                print("[nanokvm] H.264 stream closed (\(error?.localizedDescription ?? "?")), falling back to MJPEG")
                self.startMJPEG()
            }
        }
        videoSocket = socket
        socket.open()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !self.connected, self.videoSocket === socket else { return }
            self.videoSocket = nil
            socket.close()
            self.startMJPEG()
        }
    }

    private func startMJPEG() {
        guard mjpeg == nil else { return }
        let frames = FrameStream()
        delegate?.driver(video: .frames(frames))
        Task { _ = try? await http.request("/api/vm/screen", method: "POST", json: ["type": "type", "value": 0]) }
        let stream = http.stream("/api/stream/mjpeg")
        mjpeg = Task { [weak self] in
            do {
                for try await chunk in stream {
                    frames.pushMJPEG(chunk)
                    self?.markConnected()
                }
                self?.delegate?.driver(didFail: KVMError.protocolError("Flux vidéo terminé."))
            } catch is CancellationError {
            } catch {
                self?.delegate?.driver(didFail: error)
            }
        }
    }

    // MARK: HID reports

    func sendKeyboard(keys: [UInt8], modifier: UInt8) {
        var report: [UInt8] = [0x01, modifier, 0x00]
        report += keys.prefix(6)
        report += [UInt8](repeating: 0, count: 9 - report.count)
        hid?.send(Data(report))
    }

    func sendAbsoluteMouse(x: Int, y: Int, buttons: Int) {
        pointer = (x, y)
        self.buttons = buttons
        sendMouse(wheel: 0)
    }

    func sendWheel(_ delta: Int) {
        sendMouse(wheel: Int8(clamping: delta))
    }

    /// `[0x02, buttons, x LE16, y LE16, wheel]`; the web UI's range is 1...32768.
    private func sendMouse(wheel: Int8) {
        let x = UInt16(min(max(pointer.x + 1, 1), 32768)), y = UInt16(min(max(pointer.y + 1, 1), 32768))
        hid?.send(Data([0x02, UInt8(buttons & 0x1F),
                        UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8),
                        UInt8(bitPattern: wheel)]))
    }

    // MARK: CryptoJS.AES.encrypt(password, "nanokvm-sipeed-2024")

    /// OpenSSL "Salted__" format: EVP_BytesToKey(MD5, 1 round) → AES-256-CBC/PKCS7, base64,
    /// then URL-encoded like `encodeURIComponent` (the server unescapes before decrypting).
    static func cryptoJSEncrypt(_ plaintext: String, passphrase: String = "nanokvm-sipeed-2024") -> String? {
        var salt = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { return nil }

        var derived = Data(), block = Data()
        let secret = Data(passphrase.utf8) + Data(salt)
        while derived.count < 48 {
            block = Data(Insecure.MD5.hash(data: block + secret))
            derived += block
        }
        let key = derived.prefix(32), iv = derived.subdata(in: 32..<48)

        let input = Data(plaintext.utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, inp.baseAddress, input.count,
                                out.baseAddress, outputCapacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let payload = Data("Salted__".utf8) + Data(salt) + output.prefix(written)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return payload.base64EncodedString().addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
