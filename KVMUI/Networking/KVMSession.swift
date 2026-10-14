import Foundation
import Observation
import WebRTC

enum ConnectionState: Equatable {
    case idle
    case connecting(String)
    case needsPassword(error: String?)
    case connected
    case failed(String)
}

/// One live connection to a PicoKVM: HTTP auth, WebSocket signaling, then a WebRTC peer
/// connection carrying H.264 video and a JSON-RPC data channel ("rpc") for HID input.
@MainActor
@Observable
final class KVMSession {
    let device: KVMDevice

    private(set) var state: ConnectionState = .idle
    private(set) var videoTrack: RTCVideoTrack?
    /// Resolution of the captured HDMI source, as reported by the device.
    private(set) var sourceSize: CGSize = .zero
    /// nil when HDMI is fine; otherwise the device's reason (no_signal, no_lock, out_of_range...).
    private(set) var videoError: String?
    /// The network path in use for the current connection.
    private(set) var activeRoute: Route?
    /// Called when the device reports its Tailscale / ZeroTier addresses, so they can be saved
    /// and used next time the local network isn't reachable.
    @ObservationIgnored var onOverlayAddresses: ((_ tailscale: String?, _ zeroTier: String?) -> Void)?
    /// Remote keyboard layout code ("fr-BE", "en_US"...), as configured on the device.
    private(set) var keyboardLayout: String?

    @ObservationIgnored private var api: KVMAPI?
    @ObservationIgnored private var signaling: SignalingChannel?
    @ObservationIgnored private var peer: RTCPeerConnection?
    @ObservationIgnored private var peerDelegate: PeerDelegate?
    @ObservationIgnored private var rpcChannel: RTCDataChannel?
    @ObservationIgnored private var diskChannel: RTCDataChannel?
    @ObservationIgnored private var rpcDelegate: RPCChannelDelegate?
    @ObservationIgnored private var nextRPCID = 0
    @ObservationIgnored private var pendingRPC: [Int: (Result<Any?, Error>) -> Void] = [:]
    @ObservationIgnored private var pendingMouse: (x: Int, y: Int, buttons: Int)?
    @ObservationIgnored private var lastMouseButtons = 0
    @ObservationIgnored private var mouseFlushScheduled = false
    @ObservationIgnored private var typingTask: Task<Void, Never>?
    @ObservationIgnored private var receivedDeviceMetadata = false
    @ObservationIgnored private var iceGatheringComplete: CheckedContinuation<Void, Never>?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    init(device: KVMDevice) {
        self.device = device
    }

    // MARK: - Lifecycle

    func connect(password: String?) async {
        disconnect()
        state = .connecting("Recherche du KVM…")
        guard let api = await reachableAPI() else {
            let tried = device.routes.map { "\($0.kind.title) (\($0.host))" }.joined(separator: ", ")
            var message = "Aucune adresse ne répond : \(tried)."
            if device.routes.contains(where: { $0.kind != .local }) {
                message += " Vérifie que Tailscale ou ZeroTier est actif sur cet appareil."
            }
            return fail(message)
        }
        self.api = api
        activeRoute = api.route
        state = .connecting("Connexion via \(api.route.kind.title)…")
        do {
            guard try await api.status().isSetup else { throw KVMError.notSetUp }
            if try await api.deviceInfo() == nil {
                guard let password, !password.isEmpty else {
                    state = .needsPassword(error: nil)
                    return
                }
                state = .connecting("Authentification…")
                do {
                    try await api.login(password: password)
                } catch KVMError.loginFailed(let message) {
                    state = .needsPassword(error: message)
                    return
                }
            }
            state = .connecting("Ouverture de la signalisation…")
            openSignaling(api: api)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// Probes every route at once and keeps the most preferred one that answers
    /// (local network first, then Tailscale, then ZeroTier).
    private func reachableAPI() async -> KVMAPI? {
        let candidates = device.routes.map { KVMAPI(device: device, route: $0) }
        let reachable = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, api) in candidates.enumerated() {
                group.addTask { (index, await api.probe()) }
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
        for (index, api) in candidates.enumerated() where index != reachable {
            api.invalidate()
        }
        return reachable.map { candidates[$0] }
    }

    func disconnect() {
        signaling?.close()
        signaling = nil
        rpcChannel?.close()
        diskChannel?.close()
        rpcChannel = nil
        diskChannel = nil
        peer?.close()
        peer = nil
        api?.invalidate()
        api = nil
        videoTrack = nil
        typingTask?.cancel()
        typingTask = nil
        receivedDeviceMetadata = false
        iceGatheringComplete?.resume()
        iceGatheringComplete = nil
        failPendingRPC()
        activeRoute = nil
        if case .connected = state { state = .idle }
        if case .connecting = state { state = .idle }
    }

    private func fail(_ message: String) {
        guard state != .failed(message) else { return }
        disconnect()
        state = .failed(message)
    }

    // MARK: - Signaling

    private func openSignaling(api: KVMAPI) {
        let channel = SignalingChannel(url: device.signalingURL(for: api.route), session: api.session)
        channel.onMessage = { [weak self] type, data in
            Task { @MainActor in self?.handleSignaling(type: type, data: data) }
        }
        channel.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self, self.signaling === channel else { return }
                if case .connected = self.state { return } // signaling is no longer needed once connected
                // Old firmware has no signaling WebSocket at all: fall back to the HTTP offer/answer exchange.
                if !self.receivedDeviceMetadata, self.peer == nil {
                    print("[signaling] WebSocket unavailable, using legacy signaling")
                    self.signaling = nil
                    Task { await self.setupPeerConnection(legacy: true) }
                    return
                }
                self.fail("Signalisation interrompue : \(error?.localizedDescription ?? "fermée")")
            }
        }
        signaling = channel
        channel.open()
    }

    private func handleSignaling(type: String, data: Any?) {
        switch type {
        case "device-metadata":
            receivedDeviceMetadata = true
            let version = (data as? [String: Any])?["deviceVersion"] as? String
            if let version, !version.isEmpty {
                print("[signaling] device version", version)
                Task { await setupPeerConnection(legacy: false) }
            } else {
                // Legacy firmware: offer/answer go through POST /webrtc/session once ICE gathering is done.
                print("[signaling] legacy device, switching to HTTP signaling")
                signaling?.close()
                signaling = nil
                Task { await setupPeerConnection(legacy: true) }
            }
        case "answer":
            guard let encoded = data as? String,
                  let json = Data(base64Encoded: encoded),
                  let answer = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let sdp = answer["sdp"] as? String else { return }
            peer?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.fail("Réponse SDP refusée : \(error.localizedDescription)") }
            }
        case "new-ice-candidate":
            guard let info = data as? [String: Any],
                  let sdp = info["candidate"] as? String, !sdp.isEmpty else { return }
            let candidate = RTCIceCandidate(sdp: sdp,
                                            sdpMLineIndex: Int32(info["sdpMLineIndex"] as? Int ?? 0),
                                            sdpMid: info["sdpMid"] as? String)
            peer?.add(candidate) { error in
                if let error { print("[webrtc] addIceCandidate failed:", error) }
            }
        default:
            print("[signaling] unhandled message", type)
        }
    }

    // MARK: - WebRTC

    private func setupPeerConnection(legacy: Bool) async {
        guard let api, peer == nil else { return }
        state = .connecting(legacy ? "Négociation WebRTC (firmware ancien)…" : "Négociation WebRTC…")

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        config.iceServers = await api.iceServers().map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }

        let delegate = PeerDelegate(session: self)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            return fail("Impossible de créer la connexion WebRTC.")
        }
        self.peer = peer
        peerDelegate = delegate

        let recvOnly = RTCRtpTransceiverInit()
        recvOnly.direction = .recvOnly
        let video = peer.addTransceiver(of: .video, init: recvOnly)
        peer.addTransceiver(of: .audio, init: recvOnly)
        videoTrack = video?.receiver.track as? RTCVideoTrack

        let rpcDelegate = RPCChannelDelegate(session: self)
        self.rpcDelegate = rpcDelegate
        rpcChannel = peer.dataChannel(forLabel: "rpc", configuration: RTCDataChannelConfiguration())
        rpcChannel?.delegate = rpcDelegate
        // The web UI always opens a "disk" channel too (virtual media); mirror it so the device sees a normal client.
        diskChannel = peer.dataChannel(forLabel: "disk", configuration: RTCDataChannelConfiguration())

        do {
            let offer = try await peer.offer(for: constraints)
            try await peer.setLocalDescription(offer)
            if legacy {
                try await exchangeLegacyOffer(peer: peer, api: api)
            } else {
                signaling?.send(type: "offer", data: ["sd": try Self.encode(offer)])
            }
        } catch {
            fail("Négociation WebRTC impossible : \(error.localizedDescription)")
        }
    }

    /// `{"type", "sdp"}` JSON, base64-encoded: the format both signaling paths use.
    private static func encode(_ description: RTCSessionDescription) throws -> String {
        let type = description.type == .answer ? "answer" : "offer"
        let json = try JSONSerialization.data(withJSONObject: ["type": type, "sdp": description.sdp])
        return json.base64EncodedString()
    }

    private func exchangeLegacyOffer(peer: RTCPeerConnection, api: KVMAPI) async throws {
        state = .connecting("Collecte des candidats ICE…")
        if peer.iceGatheringState != .complete {
            await withCheckedContinuation { continuation in
                iceGatheringComplete = continuation
                // Don't wait forever if a STUN server is unreachable; host candidates are enough on a LAN.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.iceGatheringComplete?.resume()
                    self?.iceGatheringComplete = nil
                }
            }
        }
        guard self.peer === peer, let local = peer.localDescription else { return }
        state = .connecting("Envoi de l'offre…")
        let encodedAnswer = try await api.legacySession(offer: try Self.encode(local))
        guard let json = Data(base64Encoded: encodedAnswer),
              let answer = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let sdp = answer["sdp"] as? String else { throw KVMError.badResponse(200) }
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    fileprivate func iceGatheringChanged(_ newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        iceGatheringComplete?.resume()
        iceGatheringComplete = nil
    }

    fileprivate func peerStateChanged(_ newState: RTCPeerConnectionState) {
        switch newState {
        case .connected:
            state = .connected
        case .failed:
            fail("Connexion WebRTC échouée.")
        case .disconnected, .closed:
            if case .connected = state { fail("Connexion perdue.") }
        default:
            break
        }
    }

    fileprivate func localCandidate(_ candidate: RTCIceCandidate) {
        guard let signaling else { return } // legacy: candidates travel inside the offer
        var payload: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": candidate.sdpMLineIndex]
        if let mid = candidate.sdpMid { payload["sdpMid"] = mid }
        signaling.send(type: "new-ice-candidate", data: payload)
    }

    fileprivate func receivedVideoTrack(_ track: RTCVideoTrack) {
        videoTrack = track
    }

    // MARK: - JSON-RPC

    func call(_ method: String, _ params: [String: Any] = [:], completion: ((Result<Any?, Error>) -> Void)? = nil) {
        guard let rpcChannel, rpcChannel.readyState == .open else { return }
        nextRPCID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params, "id": nextRPCID]
        if let completion { pendingRPC[nextRPCID] = completion }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        rpcChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    fileprivate func rpcChannelOpened() {
        call("getVideoState") { [weak self] result in
            if case .success(let state as [String: Any]) = result { self?.applyVideoState(state) }
        }
        call("getKeyboardLayout") { [weak self] result in
            if case .success(let layout as String) = result { self?.keyboardLayout = layout }
        }
        fetchOverlayAddresses()
    }

    /// Asks the device for its Tailscale and ZeroTier IPs (the web UI's network settings).
    private func fetchOverlayAddresses() {
        Task {
            async let tailscale = callAndWait("getTailScaleSettings")
            async let zeroTier = callAndWait("getZeroTierSettings")
            let addresses = (Self.overlayIP(await tailscale), Self.overlayIP(await zeroTier))
            if addresses.0 != nil || addresses.1 != nil {
                onOverlayAddresses?(addresses.0, addresses.1)
            }
        }
    }

    /// `{"state": "connected"|"logined"|..., "ip": "100.x.y.z/32"}` → "100.x.y.z" when joined.
    private static func overlayIP(_ result: Result<Any?, Error>) -> String? {
        guard case .success(let value as [String: Any]) = result,
              let ip = value["ip"] as? String, !ip.isEmpty else { return nil }
        let address = ip.split(separator: "/").first.map(String.init) ?? ip
        return address.isEmpty ? nil : address
    }

    func setKeyboardLayout(_ code: String) {
        keyboardLayout = code
        call("setKeyboardLayout", ["layout": code])
    }

    /// Sends an RPC and waits for the device's reply (or the connection going away).
    @discardableResult
    func callAndWait(_ method: String, _ params: [String: Any] = [:]) async -> Result<Any?, Error> {
        await withCheckedContinuation { continuation in
            guard rpcChannel?.readyState == .open else {
                return continuation.resume(returning: .failure(CancellationError()))
            }
            call(method, params) { continuation.resume(returning: $0) }
        }
    }

    fileprivate func rpcMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = json["id"] as? Int, let completion = pendingRPC.removeValue(forKey: id) {
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "RPC error"
                completion(.failure(NSError(domain: "KVMRPC", code: error["code"] as? Int ?? -1,
                                            userInfo: [NSLocalizedDescriptionKey: message])))
            } else {
                completion(.success(json["result"]))
            }
            return
        }
        guard let method = json["method"] as? String else { return }
        let params = json["params"]
        switch method {
        case "videoInputState":
            if let state = params as? [String: Any] { applyVideoState(state) }
        case "otherSessionConnected":
            fail("Une autre session s'est connectée à ce KVM.")
        default:
            break
        }
    }

    private func applyVideoState(_ state: [String: Any]) {
        let ready = state["ready"] as? Bool ?? false
        let error = state["error"] as? String
        videoError = ready ? nil : (error?.isEmpty == false ? error : "no_signal")
        if let width = state["width"] as? Double, let height = state["height"] as? Double, width > 0, height > 0 {
            sourceSize = CGSize(width: width, height: height)
        }
    }

    private func failPendingRPC() {
        let pending = pendingRPC
        pendingRPC.removeAll()
        for completion in pending.values {
            completion(.failure(CancellationError()))
        }
    }

    // MARK: - HID

    func sendKeyboard(keys: [UInt8], modifier: UInt8) {
        call("keyboardReport", ["keys": keys.map(Int.init), "modifier": Int(modifier)])
    }

    /// Press-and-release each stroke in order, after any typing already queued.
    func enqueueTyping(_ strokes: [(usage: UInt8, modifier: UInt8)]) {
        let previous = typingTask
        typingTask = Task { [weak self] in
            await previous?.value
            for stroke in strokes {
                guard let self, !Task.isCancelled else { return }
                await self.callAndWait("keyboardReport", ["keys": [Int(stroke.usage)], "modifier": Int(stroke.modifier)])
                await self.callAndWait("keyboardReport", ["keys": [], "modifier": 0])
            }
        }
    }

    /// Absolute pointer in the device's 0...32767 range on both axes. Moves are coalesced to ~120 Hz;
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
        call("absMouseReport", ["x": mouse.x, "y": mouse.y, "buttons": mouse.buttons])
    }

    /// One wheel notch; positive scrolls up.
    func sendWheel(_ delta: Int) {
        call("wheelReport", ["wheelY": max(-127, min(127, delta)), "mouseMode": "absolute"])
    }
}

// MARK: - Delegates (called on WebRTC's signaling thread)

private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
    weak var session: KVMSession?

    init(session: KVMSession) { self.session = session }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in session?.peerStateChanged(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in session?.localCandidate(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in session?.receivedVideoTrack(track) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in session?.iceGatheringChanged(newState) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private final class RPCChannelDelegate: NSObject, RTCDataChannelDelegate {
    weak var session: KVMSession?

    init(session: KVMSession) { self.session = session }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        Task { @MainActor in session?.rpcChannelOpened() }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor in session?.rpcMessage(data) }
    }
}
