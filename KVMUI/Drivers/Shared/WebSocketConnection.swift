import Foundation

/// Thin callback wrapper around URLSessionWebSocketTask with a receive loop.
/// Callbacks arrive on a background queue; hop to the main actor as needed.
final class WebSocketConnection: @unchecked Sendable {
    var onText: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let task: URLSessionWebSocketTask
    private var closed = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func open() {
        task.resume()
        receive()
    }

    func send(_ text: String) {
        task.send(.string(text)) { error in
            if let error { print("[ws] send failed:", error.localizedDescription) }
        }
    }

    func send(_ data: Data) {
        task.send(.data(data)) { error in
            if let error { print("[ws] send failed:", error.localizedDescription) }
        }
    }

    func sendJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text)
    }

    func close() {
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(.string(let text)):
                self.onText?(text)
                self.receive()
            case .success(.data(let data)):
                self.onData?(data)
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.closed = true
                self.onClose?(error)
            }
        }
    }
}
