import CommonCrypto
import CryptoKit
import Foundation

/// Sipeed NanoKVM (and NanoKVM-Pro): JSON login → `nano-kvm-token` cookie, binary HID reports
/// over `/api/ws`, H.265 then H.264 access units over `/api/stream/h26x/direct`, MJPEG as a last resort.
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
    /// Newer firmware ignores the legacy mouse report and wants the input-router envelope.
    private var inputRouter = false
    private var sequence: UInt32 = 0

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
            delegate?.driver(progress: String(localized: "Signing in…"))
            try await login(user: user, password: password)
        }

        delegate?.driver(progress: String(localized: "Connecting keyboard and mouse…"))
        openHID()
        inputRouter = (try? await http.request("/api/hid/pointer-mode"))?.isSuccess == true
        await startDirect(hevc: true)
    }

    /// Older NanoKVM firmware encrypts the password CryptoJS-style; Pro and newer firmware take it
    /// in clear. Try clear first: newer firmware rate-limits failed logins.
    private func login(user: String, password: String) async throws {
        var lastMessage: String?
        for candidate in [password, Self.cryptoJSEncrypt(password)].compactMap({ $0 }) {
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
        throw KVMError.credentialsRequired(lastMessage.map { String(localized: "Connection refused: \($0)") } ?? String(localized: "Invalid credentials."))
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
                self.delegate?.driver(didFail: KVMError.protocolError(String(localized: "NanoKVM session closed: \(error?.localizedDescription ?? "?")")))
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

    /// H.265, falling back to H.264 and then MJPEG when a stream closes or shows nothing for 6 s.
    private func startDirect(hevc: Bool) async {
        let codec = hevc ? "h265" : "h264"
        // Newer firmware only streams in the selected mode (and dropped /api/vm/screen and MJPEG); 404 on older.
        _ = try? await http.request("/api/stream/mode", method: "POST", json: ["mode": "\(codec)-direct"])
        if !hevc {
            // Older firmware: ask for the H.264 encoder (the web UI does this when switching modes).
            _ = try? await http.request("/api/vm/screen", method: "POST", json: ["type": "type", "value": 1])
        }

        let frames = FrameStream()
        delegate?.driver(video: .frames(frames), mode: hevc ? "H.265" : "H.264")
        let socket = WebSocketConnection(task: http.webSocket("/api/stream/\(codec)/direct"))
        socket.onData = { [weak self] message in
            // [isKey u8][timestamp u64 LE][Annex B access unit]
            guard message.count > 9 else { return }
            let accessUnit = message.subdata(in: (message.startIndex + 9)..<message.endIndex)
            if hevc { frames.pushH265(accessUnit, completeFrame: true) } else { frames.pushH264(accessUnit, completeFrame: true) }
            Task { @MainActor in self?.markConnected() }
        }
        let fallBack = { [weak self] (reason: String) in
            guard let self, self.videoSocket === socket else { return }
            self.videoSocket = nil
            socket.close()
            print("[nanokvm] \(codec) stream \(reason), falling back")
            if hevc { Task { await self.startDirect(hevc: false) } } else { self.startMJPEG() }
        }
        socket.onClose = { error in
            Task { @MainActor in fallBack("closed (\(error?.localizedDescription ?? "?"))") }
        }
        videoSocket = socket
        socket.open()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !self.connected else { return }
            fallBack("showed nothing")
        }
    }

    private func startMJPEG() {
        guard mjpeg == nil else { return }
        let frames = FrameStream()
        delegate?.driver(video: .frames(frames), mode: "MJPEG")
        Task { _ = try? await http.request("/api/vm/screen", method: "POST", json: ["type": "type", "value": 0]) }
        let stream = http.stream("/api/stream/mjpeg")
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
    /// Input router: `[0x03, version 1, route 2 (browser pointer), type 3 (absolute), 0, seq LE32, ms LE32]`
    /// then `[buttons, x LE16, y LE16, wheel LE16]` with x/y in 0...65535.
    private func sendMouse(wheel: Int8) {
        if inputRouter {
            sequence &+= 1
            func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
            let scale = { (v: Int) in UInt16(min(max(v, 0), 32767) * 65535 / 32767) }
            hid?.send(Data([0x03, 1, 2, 3, 0] + le(sequence) + le(UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000)))
                           + [UInt8(buttons & 0x1F)] + le(scale(pointer.x)) + le(scale(pointer.y)) + le(Int16(wheel))))
            return
        }
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
