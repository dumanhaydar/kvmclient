import Foundation
import WebRTC

/// H.264 video from a uStreamer Janus plugin (PiKVM, TinyPilot) over the Janus WebSocket API.
/// The server is the offerer: create session → attach plugin → "watch" → answer its offer with "start".
@MainActor
final class JanusStream {
    var onTrack: ((RTCVideoTrack) -> Void)?
    var onConnected: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let http: HTTPClient
    private let watchParams: [String: Any]
    private let queryFeatures: Bool
    private var socket: WebSocketConnection?
    private var sessionID: Int?
    private var handleID: Int?
    private var transactions: [String: ([String: Any]) -> Void] = [:]
    private var keepalive: Task<Void, Never>?
    private var peer: RTCPeerConnection?
    private var peerDelegate: JanusPeerDelegate?
    private var iceServers: [RTCIceServer] = []
    private var watchDeadline = Date.distantFuture
    private var finished = false

    init(http: HTTPClient, watchParams: [String: Any], queryFeatures: Bool) {
        self.http = http
        self.watchParams = watchParams
        self.queryFeatures = queryFeatures
    }

    func start() {
        let socket = WebSocketConnection(task: http.webSocket("/janus/ws", protocols: ["janus-protocol"]))
        socket.onText = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        socket.onClose = { [weak self] error in
            Task { @MainActor in self?.failed(String(localized: "Janus closed: \(error?.localizedDescription ?? "?")")) }
        }
        self.socket = socket
        socket.open()
        send(["janus": "create"]) { [weak self] reply in
            guard let self, let id = (reply["data"] as? [String: Any])?["id"] as? Int else {
                self?.failed(String(localized: "Janus session refused."))
                return
            }
            self.sessionID = id
            self.startKeepalive()
            self.attach()
        }
    }

    func stop() {
        finished = true
        keepalive?.cancel()
        if let sessionID { socket?.sendJSON(["janus": "destroy", "session_id": sessionID, "transaction": Self.transaction()]) }
        socket?.close()
        socket = nil
        peer?.close()
        peer = nil
    }

    private func failed(_ message: String) {
        guard !finished else { return }
        stop()
        onFailure?(message)
    }

    // MARK: Janus messages

    private static func transaction() -> String {
        String(UUID().uuidString.prefix(12))
    }

    private func send(_ message: [String: Any], reply: (([String: Any]) -> Void)? = nil) {
        var message = message
        let transaction = Self.transaction()
        message["transaction"] = transaction
        if let sessionID, message["session_id"] == nil, message["janus"] as? String != "create" {
            message["session_id"] = sessionID
        }
        if let reply { transactions[transaction] = reply }
        socket?.sendJSON(message)
    }

    private func sendToPlugin(_ body: [String: Any], jsep: [String: Any]? = nil) {
        guard let handleID else { return }
        var message: [String: Any] = ["janus": "message", "handle_id": handleID, "body": body]
        if let jsep { message["jsep"] = jsep }
        send(message)
    }

    private func startKeepalive() {
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.send(["janus": "keepalive"])
            }
        }
    }

    private func attach() {
        send(["janus": "attach", "plugin": "janus.plugin.ustreamer",
              "opaque_id": "kvmclient-\(Self.transaction())"]) { [weak self] reply in
            guard let self, let id = (reply["data"] as? [String: Any])?["id"] as? Int else {
                self?.failed(String(localized: "uStreamer plugin unavailable."))
                return
            }
            self.handleID = id
            if self.queryFeatures {
                self.sendToPlugin(["request": "features"])
            } else {
                self.watch()
            }
        }
    }

    private func watch() {
        if watchDeadline == .distantFuture { watchDeadline = Date().addingTimeInterval(60) }
        sendToPlugin(["request": "watch", "params": watchParams])
    }

    private func handle(_ text: String) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let kind = json["janus"] as? String else { return }
        if let transaction = json["transaction"] as? String, kind == "success" || kind == "error",
           let reply = transactions.removeValue(forKey: transaction) {
            if kind == "error" {
                failed((json["error"] as? [String: Any])?["reason"] as? String ?? String(localized: "Janus error."))
            } else {
                reply(json)
            }
            return
        }
        switch kind {
        case "event":
            let data = (json["plugindata"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
            handlePluginEvent(data, jsep: json["jsep"] as? [String: Any])
        case "webrtcup":
            onConnected?()
        case "hangup":
            failed(String(localized: "H.264 stream interrupted."))
        default:
            break
        }
    }

    private func handlePluginEvent(_ data: [String: Any], jsep: [String: Any]?) {
        if let code = data["error_code"] as? Int {
            // 503: the stream is still starting; the web UIs retry for a while.
            if code == 503, Date() < watchDeadline {
                Task { try? await Task.sleep(for: .seconds(1)); self.watch() }
            } else {
                failed(data["error"] as? String ?? String(localized: "uStreamer error \(code)."))
            }
            return
        }
        let result = data["result"] as? [String: Any] ?? [:]
        if result["status"] as? String == "features" {
            if let url = ((result["features"] as? [String: Any])?["ice"] as? [String: Any])?["url"] as? String, !url.isEmpty {
                iceServers = [RTCIceServer(urlStrings: [url])]
            }
            watch()
            return
        }
        if let jsep, jsep["type"] as? String == "offer", let sdp = jsep["sdp"] as? String {
            Task { await answer(offerSDP: sdp) }
        }
    }

    // MARK: WebRTC

    private func answer(offerSDP: String) async {
        peer?.close()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = iceServers
        let delegate = JanusPeerDelegate(stream: self)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = WebRTCFactory.shared.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            return failed(String(localized: "Couldn't create the WebRTC connection."))
        }
        self.peer = peer
        peerDelegate = delegate
        do {
            try await peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offerSDP))
            for transceiver in peer.transceivers {
                // Refuse any audio the server offers anyway: receiving audio would start WebRTC's
                // audio device module and with it the microphone.
                transceiver.setDirection(transceiver.mediaType == .audio ? .inactive : .recvOnly, error: nil)
                if let track = transceiver.receiver.track as? RTCVideoTrack { onTrack?(track) }
            }
            let answer = try await peer.answer(for: RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "false"],
                optionalConstraints: nil))
            try await peer.setLocalDescription(answer)
            sendToPlugin(["request": "start"], jsep: ["type": "answer", "sdp": answer.sdp])
        } catch {
            failed(String(localized: "H.264 negotiation failed: \(error.localizedDescription)"))
        }
    }

    fileprivate func localCandidate(_ candidate: RTCIceCandidate?) {
        guard let handleID else { return }
        var payload: [String: Any] = ["completed": true]
        if let candidate {
            payload = ["candidate": candidate.sdp, "sdpMLineIndex": candidate.sdpMLineIndex]
            if let mid = candidate.sdpMid { payload["sdpMid"] = mid }
        }
        send(["janus": "trickle", "handle_id": handleID, "candidate": payload])
    }

    fileprivate func peerStateChanged(_ state: RTCPeerConnectionState) {
        switch state {
        case .connected: onConnected?()
        case .failed: failed(String(localized: "H.264 connection failed."))
        default: break
        }
    }

    fileprivate func receivedTrack(_ track: RTCVideoTrack) {
        onTrack?(track)
    }
}

private final class JanusPeerDelegate: NSObject, RTCPeerConnectionDelegate {
    weak var stream: JanusStream?

    init(stream: JanusStream) { self.stream = stream }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in stream?.peerStateChanged(newState) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in stream?.localCandidate(candidate) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in stream?.localCandidate(nil) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in stream?.receivedTrack(track) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
