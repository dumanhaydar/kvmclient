import Foundation

/// WebSocket at `/webrtc/signaling/client`. Messages are `{"type": ..., "data": ...}` JSON,
/// plus a plain-text "ping"/"pong" heartbeat.
final class SignalingChannel {
    var onMessage: ((_ type: String, _ data: Any?) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let task: URLSessionWebSocketTask
    private var heartbeat: Task<Void, Never>?
    private var closed = false

    init(url: URL, session: URLSession) {
        task = session.webSocketTask(with: url)
    }

    func open() {
        task.resume()
        receive()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                self?.task.send(.string("ping")) { _ in }
            }
        }
    }

    func send(type: String, data: Any) {
        let payload: [String: Any] = ["type": type, "data": data]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        task.send(.string(text)) { error in
            if let error { print("[signaling] send failed:", error) }
        }
    }

    func close() {
        closed = true
        heartbeat?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(text)
                self.receive()
            case .success(.data(let data)):
                self.handle(String(decoding: data, as: UTF8.self))
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.heartbeat?.cancel()
                self.onClose?(error)
            }
        }
    }

    private func handle(_ text: String) {
        guard text != "pong",
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        onMessage?(type, json["data"])
    }
}
