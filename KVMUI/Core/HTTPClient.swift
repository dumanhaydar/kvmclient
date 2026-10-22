import Foundation

enum KVMError: LocalizedError {
    case notSetUp
    case credentialsRequired(String?)
    case badResponse(Int)
    case protocolError(String)
    case unsupportedDevice

    var errorDescription: String? {
        switch self {
        case .notSetUp: String(localized: "The KVM isn't set up yet. Finish its setup in its web interface.")
        case .credentialsRequired(let message): message ?? String(localized: "Credentials required.")
        case .badResponse(let code): String(localized: "Unexpected response from the KVM (HTTP \(code)).")
        case .protocolError(let message): message
        case .unsupportedDevice: String(localized: "Unrecognized KVM type. Choose it by hand in the device settings.")
        }
    }
}

/// One HTTP(S) endpoint of a device: private cookie store (auth), self-signed TLS trust for that
/// host only, JSON helpers, WebSockets and long-lived streaming responses (MJPEG, H.264).
final class HTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let baseURL: URL
    private let trustSelfSigned: Bool
    private(set) var session: URLSession!
    private var streams: [Int: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private let lock = NSLock()

    init(baseURL: URL, trustSelfSigned: Bool) {
        self.baseURL = baseURL
        self.trustSelfSigned = trustSelfSigned
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func url(_ path: String, query: [String: String] = [:]) -> URL {
        var url = baseURL.appending(path: path)
        if !query.isEmpty {
            url.append(queryItems: query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) })
        }
        return url
    }

    /// ws(s):// URL for a path on the same host.
    func webSocketURL(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: url(path, query: query), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    var cookies: [HTTPCookie] {
        session.configuration.httpCookieStorage?.cookies(for: baseURL) ?? []
    }

    func setCookie(name: String, value: String) {
        guard let host = baseURL.host(),
              let cookie = HTTPCookie(properties: [.name: name, .value: value, .domain: host, .path: "/"]) else { return }
        session.configuration.httpCookieStorage?.setCookie(cookie)
    }

    // MARK: Requests

    struct Response {
        let status: Int
        let data: Data
        let headers: [AnyHashable: Any]

        var json: Any? { try? JSONSerialization.jsonObject(with: data) }
        var isSuccess: Bool { (200..<300).contains(status) }
    }

    func request(_ path: String, method: String = "GET", query: [String: String] = [:],
                 json body: Any? = nil, form: [String: String]? = nil,
                 headers: [String: String] = [:], timeout: TimeInterval? = nil) async throws -> Response {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" alone, which form decoding would read as a space.
            request.httpBody = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return Response(status: http?.statusCode ?? 0, data: data, headers: http?.allHeaderFields ?? [:])
    }

    /// Any HTTP answer (even 401/404) means the host is reachable.
    func probe(timeout: TimeInterval = 2.5) async -> Bool {
        var request = URLRequest(url: url("/"))
        request.timeoutInterval = timeout
        return (try? await session.data(for: request)) != nil
    }

    func webSocket(_ path: String, query: [String: String] = [:], protocols: [String] = []) -> URLSessionWebSocketTask {
        let url = webSocketURL(path, query: query)
        return protocols.isEmpty ? session.webSocketTask(with: url) : session.webSocketTask(with: url, protocols: protocols)
    }

    /// Body of a never-ending response (MJPEG, raw H.264), chunk by chunk.
    func stream(_ path: String, query: [String: String] = [:], headers: [String: String] = [:]) -> AsyncThrowingStream<Data, Error> {
        var request = URLRequest(url: url(path, query: query))
        request.timeoutInterval = 15
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.dataTask(with: request)
        return AsyncThrowingStream { continuation in
            lock.withLock { streams[task.taskIdentifier] = continuation }
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async
        -> URLSession.ResponseDisposition {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let continuation = lock.withLock { streams.removeValue(forKey: dataTask.taskIdentifier) }
            continuation?.finish(throwing: status == 401 || status == 403
                                 ? KVMError.credentialsRequired(nil) : KVMError.badResponse(status))
            return .cancel
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let continuation = lock.withLock { streams[dataTask.taskIdentifier] }
        continuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { streams.removeValue(forKey: task.taskIdentifier) }
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }

    // KVMs serve HTTPS with self-signed certificates; trust them for this host only.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           trustSelfSigned,
           challenge.protectionSpace.host == baseURL.host(),
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}
