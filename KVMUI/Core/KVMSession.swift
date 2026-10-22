import Foundation
import Observation

enum ConnectionState: Equatable {
    case idle
    case connecting(String)
    case needsCredentials(error: String?)
    case connected
    case failed(String)
}

/// One live connection to a KVM, whatever its brand. Picks the network route, identifies the
/// firmware if needed, then hands over to the matching `KVMDriver`. Views only talk to this.
@MainActor
@Observable
final class KVMSession {
    private(set) var device: KVMDevice

    private(set) var state: ConnectionState = .idle
    private(set) var video: VideoFeed?
    /// Resolution of the captured HDMI source, as reported by the device.
    private(set) var sourceSize: CGSize = .zero
    /// nil when HDMI is fine; otherwise the device's reason (no_signal, no_lock, out_of_range...).
    private(set) var videoError: String?
    /// The network path in use for the current connection.
    private(set) var activeRoute: Route?
    /// Remote keyboard layout code ("fr-BE", "en_US"...), used to type text.
    private(set) var keyboardLayout: String?

    /// Lets the owner persist what was learned while connecting (detected kind, overlay addresses).
    @ObservationIgnored var onDeviceUpdate: ((KVMDevice) -> Void)?

    @ObservationIgnored private var driver: KVMDriver?
    @ObservationIgnored private var http: HTTPClient?
    @ObservationIgnored private var pendingMouse: (x: Int, y: Int, buttons: Int)?
    @ObservationIgnored private var lastMouseButtons = 0
    @ObservationIgnored private var mouseFlushScheduled = false
    @ObservationIgnored private var typingTask: Task<Void, Never>?

    init(device: KVMDevice) {
        self.device = device
        keyboardLayout = device.keyboardLayout
    }

    var kind: DeviceKind? { device.kind }

    // MARK: - Lifecycle

    func connect(credentials: Credentials) async {
        disconnect()
        if device.isDemo { return await connectDemo() }
        state = .connecting(String(localized: "Looking for the KVM…"))
        guard let http = await reachableClient() else {
            let tried = device.routes.map { "\($0.kind.title) (\($0.host))" }.joined(separator: ", ")
            var message = String(localized: "No address answers: \(tried).")
            if device.routes.contains(where: { $0.kind != .local }) {
                message += String(localized: " Check that Tailscale or ZeroTier is running on this device.")
            }
            return fail(message)
        }
        self.http = http.client
        activeRoute = http.route

        do {
            let kind: DeviceKind
            if let known = device.kind {
                kind = known
            } else {
                state = .connecting(String(localized: "Identifying the KVM…"))
                guard let detected = await DeviceDetector.detect(http.client) else { throw KVMError.unsupportedDevice }
                kind = detected
                updateDevice { $0.kind = detected }
            }

            state = .connecting(String(localized: "Connecting to \(kind.shortTitle) via \(http.route.kind.title)…"))
            let driver = Self.makeDriver(kind, http: http.client)
            driver.delegate = self
            self.driver = driver
            var credentials = credentials
            if kind.usesUsername, credentials.username?.isEmpty ?? true {
                credentials.username = device.username ?? kind.defaultUsername
            }
            try await driver.connect(credentials: credentials)
            if kind.usesUsername, let username = credentials.username, username != device.username {
                updateDevice { $0.username = username }
            }
        } catch KVMError.credentialsRequired(let message) {
            disconnect()
            state = .needsCredentials(error: message)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func connectDemo() async {
        state = .connecting(String(localized: "Opening the demo…"))
        let driver = DemoDriver(keyboardLayout: keyboardLayout)
        driver.delegate = self
        self.driver = driver
        try? await driver.connect(credentials: Credentials())
    }

    private static func makeDriver(_ kind: DeviceKind, http: HTTPClient) -> KVMDriver {
        switch kind {
        case .jetKVM: JetKVMDriver(http: http)
        case .piKVM: PiKVMDriver(http: http)
        case .nanoKVM: NanoKVMDriver(http: http)
        case .tinyPilot: TinyPilotDriver(http: http)
        }
    }

    /// Probes every route at once and keeps the most preferred one that answers
    /// (local network first, then Tailscale, then ZeroTier).
    private func reachableClient() async -> (client: HTTPClient, route: Route)? {
        let candidates = device.routes.map {
            (client: HTTPClient(baseURL: device.baseURL(for: $0), trustSelfSigned: device.useHTTPS), route: $0)
        }
        let reachable = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { (index, await candidate.client.probe()) }
            }
            var results: [Int: Bool] = [:]
            for await (index, ok) in group {
                results[index] = ok
                // Stop waiting as soon as nothing better than the best success can still answer.
                if let best = results.filter(\.value).keys.min(),
                   (0..<best).allSatisfy({ results[$0] != nil }) { break }
            }
            group.cancelAll()
            return results.filter(\.value).keys.min()
        }
        for (index, candidate) in candidates.enumerated() where index != reachable {
            candidate.client.invalidate()
        }
        return reachable.map { candidates[$0] }
    }

    func disconnect() {
        driver?.disconnect()
        driver = nil
        http?.invalidate()
        http = nil
        video = nil
        typingTask?.cancel()
        typingTask = nil
        activeRoute = nil
        pendingMouse = nil
        lastMouseButtons = 0
        if case .connected = state { state = .idle }
        if case .connecting = state { state = .idle }
    }

    private func fail(_ message: String) {
        guard state != .failed(message) else { return }
        disconnect()
        state = .failed(message)
    }

    private func updateDevice(_ change: (inout KVMDevice) -> Void) {
        var updated = device
        change(&updated)
        guard updated != device else { return }
        device = updated
        onDeviceUpdate?(updated)
    }

    // MARK: - Keyboard layout

    func setKeyboardLayout(_ code: String) {
        keyboardLayout = code
        updateDevice { $0.keyboardLayout = code }
        driver?.setKeyboardLayout(code)
    }

    // MARK: - HID

    func sendKeyboard(keys: [UInt8], modifier: UInt8) {
        driver?.sendKeyboard(keys: keys, modifier: modifier)
    }

    /// Press-and-release each stroke in order, after any typing already queued.
    func enqueueTyping(_ strokes: [(usage: UInt8, modifier: UInt8)]) {
        let previous = typingTask
        typingTask = Task { [weak self] in
            await previous?.value
            for stroke in strokes {
                guard let driver = self?.driver, !Task.isCancelled else { return }
                await driver.sendKeyboardAndWait(keys: [stroke.usage], modifier: stroke.modifier)
                await driver.sendKeyboardAndWait(keys: [], modifier: 0)
            }
        }
    }

    /// Absolute pointer in 0...32767 on both axes. Moves are coalesced to ~120 Hz;
    /// button changes are sent immediately.
    func sendAbsoluteMouse(x: Int, y: Int, buttons: Int) {
        pendingMouse = (x, y, buttons)
        if buttons != lastMouseButtons {
            flushMouse()
            return
        }
        guard !mouseFlushScheduled else { return }
        mouseFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            self?.flushMouse()
        }
    }

    private func flushMouse() {
        mouseFlushScheduled = false
        guard let mouse = pendingMouse else { return }
        pendingMouse = nil
        lastMouseButtons = mouse.buttons
        driver?.sendAbsoluteMouse(x: mouse.x, y: mouse.y, buttons: mouse.buttons)
    }

    /// One wheel notch; positive scrolls up.
    func sendWheel(_ delta: Int) {
        driver?.sendWheel(delta)
    }
}

extension KVMSession: KVMDriverDelegate {
    func driver(progress message: String) {
        if case .connecting = state { state = .connecting(message) }
    }

    func driverDidConnect() {
        state = .connected
    }

    func driver(didFail error: Error) {
        if case KVMError.credentialsRequired(let message) = error {
            disconnect()
            state = .needsCredentials(error: message)
        } else {
            fail(error.localizedDescription)
        }
    }

    func driver(video: VideoFeed?) {
        guard !(video?.isSame(as: self.video) ?? (self.video == nil)) else { return }
        self.video = video
    }

    func driver(sourceSize: CGSize) {
        self.sourceSize = sourceSize
    }

    func driver(videoError: String?) {
        self.videoError = videoError
    }

    func driver(keyboardLayout: String) {
        self.keyboardLayout = keyboardLayout
    }

    func driver(tailscale: String?, zeroTier: String?) {
        updateDevice { device in
            device.tailscaleHost = DeviceStore.merge(device.tailscaleHost, tailscale)
            device.zeroTierHost = DeviceStore.merge(device.zeroTierHost, zeroTier)
        }
    }
}
