import Foundation
import WebRTC

/// JetKVM and its forks (Luckfox PicoKVM): cookie auth, WebSocket signaling (or the legacy
/// HTTP offer/answer), then WebRTC with H.264 video and a JSON-RPC data channel ("rpc") for HID.
@MainActor
final class JetKVMDriver: KVMDriver {
    weak var delegate: KVMDriverDelegate?
    var storesKeyboardLayout: Bool { true }

    private let http: HTTPClient
    private var signaling: SignalingChannel?
    private var peer: RTCPeerConnection?
    private var peerDelegate: PeerDelegate?
    private var rpcChannel: RTCDataChannel?
    private var diskChannel: RTCDataChannel?
    private var rpcDelegate: RPCChannelDelegate?
    private var nextRPCID = 0
    private var pendingRPC: [Int: (Result<Any?, Error>) -> Void] = [:]
    private var receivedDeviceMetadata = false
    private var iceGatheringComplete: CheckedContinuation<Void, Never>?
    private var connected = false

    init(http: HTTPClient) {
        self.http = http
    }

    /// `/device/status` → `{"isSetup": bool}` is specific to this firmware family.
    static func detect(_ http: HTTPClient) async -> Bool {
        guard let response = try? await http.request("/device/status", timeout: 3), response.isSuccess,
              let json = response.json as? [String: Any] else { return false }
        return json["isSetup"] is Bool
    }

    // MARK: Lifecycle

    func connect(credentials: Credentials) async throws {
        let status = try await http.request("/device/status")
        guard (status.json as? [String: Any])?["isSetup"] as? Bool == true else { throw KVMError.notSetUp }

        // GET /device answers 401 until logged in; "noPassword" devices answer 200 right away.
        if try await http.request("/device").status == 401 {
            guard let password = credentials.password, !password.isEmpty else {
                throw KVMError.credentialsRequired(nil)
            }
            delegate?.driver(progress: "Authentification…")
            let login = try await http.request("/auth/login-local", method: "POST", json: ["password": password])
            guard login.isSuccess else {
                let message = (login.json as? [String: Any])?["error"] as? String
                throw KVMError.credentialsRequired(message ?? "Mot de passe invalide.")
            }
        }
        delegate?.driver(progress: "Ouverture de la signalisation…")
        openSignaling()
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
        receivedDeviceMetadata = false
        iceGatheringComplete?.resume()
        iceGatheringComplete = nil
        connected = false
        let pending = pendingRPC
        pendingRPC.removeAll()
        pending.values.forEach { $0(.failure(CancellationError())) }
    }

    private func fail(_ message: String) {
        delegate?.driver(didFail: KVMError.protocolError(message))
    }

    // MARK: Signaling

    private func openSignaling() {
        let channel = SignalingChannel(task: http.webSocket("/webrtc/signaling/client"))
        channel.onMessage = { [weak self] type, data in
            Task { @MainActor in self?.handleSignaling(type: type, data: data) }
        }
        channel.onClose = { [weak self] error in
            Task { @MainActor in
                guard let self, self.signaling === channel, !self.connected else { return }
                // Old firmware has no signaling WebSocket at all: fall back to the HTTP offer/answer exchange.
                if !self.receivedDeviceMetadata, self.peer == nil {
                    print("[jetkvm] WebSocket unavailable, using legacy signaling")
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
                print("[jetkvm] device version", version)
                Task { await setupPeerConnection(legacy: false) }
            } else {
                // Legacy firmware: offer/answer go through POST /webrtc/session once ICE gathering is done.
                print("[jetkvm] legacy device, switching to HTTP signaling")
                signaling?.close()
                signaling = nil
                Task { await setupPeerConnection(legacy: true) }
            }
        case "answer":
            guard let encoded = data as? String, let sdp = Self.decodeSDP(encoded) else { return }
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
                if let error { print("[jetkvm] addIceCandidate failed:", error) }
            }
        default:
            print("[jetkvm] unhandled signaling message", type)
        }
    }

    // MARK: WebRTC

    private func setupPeerConnection(legacy: Bool) async {
        guard peer == nil else { return }
        delegate?.driver(progress: legacy ? "Négociation WebRTC (firmware ancien)…" : "Négociation WebRTC…")

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        config.iceServers = await iceServers()

        let delegate = PeerDelegate(driver: self)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = WebRTCFactory.shared.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            return fail("Impossible de créer la connexion WebRTC.")
        }
        self.peer = peer
        peerDelegate = delegate

        let recvOnly = RTCRtpTransceiverInit()
        recvOnly.direction = .recvOnly
        let video = peer.addTransceiver(of: .video, init: recvOnly)
        peer.addTransceiver(of: .audio, init: recvOnly)
        // Recent JetKVM firmware switches to H.265 when the offer allows it; H.264 decodes everywhere.
        let codecs = WebRTCFactory.shared.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
            .filter { !["H265", "HEVC"].contains($0.name.uppercased()) }
        _ = try? video?.setCodecPreferences(codecs, error: ())
        if let track = video?.receiver.track as? RTCVideoTrack { self.delegate?.driver(video: .webRTC(track)) }

        let rpcDelegate = RPCChannelDelegate(driver: self)
        self.rpcDelegate = rpcDelegate
        rpcChannel = peer.dataChannel(forLabel: "rpc", configuration: RTCDataChannelConfiguration())
        rpcChannel?.delegate = rpcDelegate
        // The web UI always opens a "disk" channel too (virtual media); mirror it so the device sees a normal client.
        diskChannel = peer.dataChannel(forLabel: "disk", configuration: RTCDataChannelConfiguration())

        do {
            let offer = try await peer.offer(for: constraints)
            try await peer.setLocalDescription(offer)
            if legacy {
                try await exchangeLegacyOffer(peer: peer)
            } else {
                signaling?.send(type: "offer", data: ["sd": try Self.encode(offer)])
            }
        } catch {
            fail("Négociation WebRTC impossible : \(error.localizedDescription)")
        }
    }

    /// Falls back to no ICE servers: on a LAN, host candidates are enough.
    private func iceServers() async -> [RTCIceServer] {
        guard let response = try? await http.request("/api/ice-servers", timeout: 3),
              let servers = (response.json as? [String: Any])?["iceServers"] as? [[String: Any]] else { return [] }
        return servers.compactMap { server in
            let urls = (server["urls"] as? [String]) ?? (server["urls"] as? String).map { [$0] }
            guard let urls, !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: server["username"] as? String,
                                credential: server["credential"] as? String)
        }
    }

    /// `{"type", "sdp"}` JSON, base64-encoded: the format both signaling paths use.
    private static func encode(_ description: RTCSessionDescription) throws -> String {
        let type = description.type == .answer ? "answer" : "offer"
        return try JSONSerialization.data(withJSONObject: ["type": type, "sdp": description.sdp]).base64EncodedString()
    }

    private static func decodeSDP(_ encoded: String) -> String? {
        guard let json = Data(base64Encoded: encoded),
              let description = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return description["sdp"] as? String
    }

    private func exchangeLegacyOffer(peer: RTCPeerConnection) async throws {
        delegate?.driver(progress: "Collecte des candidats ICE…")
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
        delegate?.driver(progress: "Envoi de l'offre…")
        let response = try await http.request("/webrtc/session", method: "POST", json: ["sd": try Self.encode(local)])
        if response.status == 401 { throw KVMError.credentialsRequired(nil) }
        guard response.isSuccess,
              let encoded = (response.json as? [String: Any])?["sd"] as? String,
              let sdp = Self.decodeSDP(encoded) else { throw KVMError.badResponse(response.status) }
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
            connected = true
            delegate?.driverDidConnect()
        case .failed:
            fail("Connexion WebRTC échouée.")
        case .disconnected, .closed:
            if connected { fail("Connexion perdue.") }
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
        delegate?.driver(video: .webRTC(track))
    }

    // MARK: JSON-RPC

    private func call(_ method: String, _ params: [String: Any] = [:], completion: ((Result<Any?, Error>) -> Void)? = nil) {
        guard let rpcChannel, rpcChannel.readyState == .open else {
            completion?(.failure(CancellationError()))
            return
        }
        nextRPCID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params, "id": nextRPCID]
        if let completion { pendingRPC[nextRPCID] = completion }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        rpcChannel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    @discardableResult
    private func callAndWait(_ method: String, _ params: [String: Any] = [:]) async -> Result<Any?, Error> {
        await withCheckedContinuation { continuation in
            call(method, params) { continuation.resume(returning: $0) }
        }
    }

    fileprivate func rpcChannelOpened() {
        call("getVideoState") { [weak self] result in
            if case .success(let state as [String: Any]) = result { self?.applyVideoState(state) }
        }
        call("getKeyboardLayout") { [weak self] result in
            if case .success(let layout as String) = result { self?.delegate?.driver(keyboardLayout: layout) }
        }
        Task {
            async let tailscale = callAndWait("getTailScaleSettings")
            async let zeroTier = callAndWait("getZeroTierSettings")
            let addresses = (Self.overlayIP(await tailscale), Self.overlayIP(await zeroTier))
            if addresses.0 != nil || addresses.1 != nil {
                delegate?.driver(tailscale: addresses.0, zeroTier: addresses.1)
            }
        }
    }

    /// `{"state": ..., "ip": "100.x.y.z/32"}` → "100.x.y.z" when joined.
    private static func overlayIP(_ result: Result<Any?, Error>) -> String? {
        guard case .success(let value as [String: Any]) = result,
              let ip = value["ip"] as? String, !ip.isEmpty else { return nil }
        let address = ip.split(separator: "/").first.map(String.init) ?? ip
        return address.isEmpty ? nil : address
    }

    fileprivate func rpcMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = json["id"] as? Int, let completion = pendingRPC.removeValue(forKey: id) {
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "RPC error"
                completion(.failure(KVMError.protocolError(message)))
            } else {
                completion(.success(json["result"]))
            }
            return
        }
        guard let method = json["method"] as? String else { return }
        switch method {
        case "videoInputState":
            if let state = json["params"] as? [String: Any] { applyVideoState(state) }
        case "otherSessionConnected":
            fail("Une autre session s'est connectée à ce KVM.")
        default:
            break
        }
    }

    private func applyVideoState(_ state: [String: Any]) {
        let ready = state["ready"] as? Bool ?? false
        let error = state["error"] as? String
        delegate?.driver(videoError: ready ? nil : (error?.isEmpty == false ? error : "no_signal"))
        if let width = state["width"] as? Double, let height = state["height"] as? Double, width > 0, height > 0 {
            delegate?.driver(sourceSize: CGSize(width: width, height: height))
        }
    }

    // MARK: HID

    func sendKeyboard(keys: [UInt8], modifier: UInt8) {
        call("keyboardReport", ["keys": keys.map(Int.init), "modifier": Int(modifier)])
    }

    func sendKeyboardAndWait(keys: [UInt8], modifier: UInt8) async {
        await callAndWait("keyboardReport", ["keys": keys.map(Int.init), "modifier": Int(modifier)])
    }

    func sendAbsoluteMouse(x: Int, y: Int, buttons: Int) {
        call("absMouseReport", ["x": x, "y": y, "buttons": buttons])
    }

    func sendWheel(_ delta: Int) {
        // Current JetKVM requires wheelX; older firmware (PicoKVM) ignores unknown parameters.
        call("wheelReport", ["wheelY": max(-127, min(127, delta)), "wheelX": 0, "mouseMode": "absolute"])
    }

    func setKeyboardLayout(_ code: String) {
        call("setKeyboardLayout", ["layout": code])
    }
}

// MARK: - Delegates (called on WebRTC's signaling thread)

private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
    weak var driver: JetKVMDriver?

    init(driver: JetKVMDriver) { self.driver = driver }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in driver?.peerStateChanged(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in driver?.localCandidate(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in driver?.receivedVideoTrack(track) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in driver?.iceGatheringChanged(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private final class RPCChannelDelegate: NSObject, RTCDataChannelDelegate {
    weak var driver: JetKVMDriver?

    init(driver: JetKVMDriver) { self.driver = driver }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        Task { @MainActor in driver?.rpcChannelOpened() }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        Task { @MainActor in driver?.rpcMessage(data) }
    }
}
