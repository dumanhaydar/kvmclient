import Foundation

/// Minimal Socket.IO v5 / Engine.IO v4 client over a WebSocket: default namespace, events with
/// acks. Enough for TinyPilot's HID channel.
///
/// Framing: Engine.IO packet type digit, then Socket.IO packet: "0" open, "2" ping → "3" pong,
/// "40" connect, "42<id>[event,payload]" event, "43<id>[reply]" ack, "44{...}" connect error.
@MainActor
final class SocketIOClient {
    var onConnect: (() -> Void)?
    var onDisconnect: ((String) -> Void)?

    private let socket: WebSocketConnection
    private var nextAckID = 0
    private var acks: [Int: (Any?) -> Void] = [:]
    private var connected = false

    init(http: HTTPClient, path: String = "/socket.io/") {
        socket = WebSocketConnection(task: http.webSocket(path, query: ["EIO": "4", "transport": "websocket"]))
    }

    func open() {
        socket.onText = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        socket.onClose = { [weak self] error in
            Task { @MainActor in self?.closed(error?.localizedDescription ?? String(localized: "closed")) }
        }
        socket.open()
    }

    func close() {
        connected = false
        socket.close()
    }

    /// Emits an event; `ack` receives the first reply argument.
    func emit(_ event: String, _ payload: Any? = nil, ack: ((Any?) -> Void)? = nil) {
        guard connected else { ack?(nil); return }
        var items: [Any] = [event]
        if let payload { items.append(payload) }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return }
        if let ack {
            nextAckID += 1
            acks[nextAckID] = ack
            socket.send("42\(nextAckID)\(json)")
        } else {
            socket.send("42\(json)")
        }
    }

    func emitAndWait(_ event: String, _ payload: Any? = nil) async -> Any? {
        await withCheckedContinuation { continuation in
            emit(event, payload) { continuation.resume(returning: $0) }
        }
    }

    private func handle(_ packet: String) {
        guard let type = packet.first else { return }
        let body = packet.dropFirst()
        switch type {
        case "0": // Engine.IO open → join the default namespace
            socket.send("40")
        case "2": // server ping
            socket.send("3")
        case "1": // Engine.IO close
            closed(String(localized: "closed by the server"))
        case "4":
            handleSocketIO(body)
        default:
            break
        }
    }

    private func handleSocketIO(_ body: Substring) {
        guard let type = body.first else { return }
        var rest = body.dropFirst()
        switch type {
        case "0":
            connected = true
            onConnect?()
        case "1":
            closed(String(localized: "disconnected"))
        case "4":
            let message = (try? JSONSerialization.jsonObject(with: Data(rest.utf8)) as? [String: Any])?["message"] as? String
            closed(message ?? String(localized: "connection refused"))
        case "3":
            let digits = rest.prefix { $0.isNumber }
            rest = rest.dropFirst(digits.count)
            guard let id = Int(digits), let ack = acks.removeValue(forKey: id) else { return }
            let reply = (try? JSONSerialization.jsonObject(with: Data(rest.utf8)) as? [Any])?.first
            ack(reply)
        default:
            break
        }
    }

    private func closed(_ reason: String) {
        let wasConnected = connected
        connected = false
        let pending = acks
        acks.removeAll()
        pending.values.forEach { $0(nil) }
        onDisconnect?(wasConnected ? String(localized: "Connection lost: \(reason)") : reason)
    }
}
