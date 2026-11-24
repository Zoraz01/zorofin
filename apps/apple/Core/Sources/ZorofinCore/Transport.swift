import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession delivers chunks on its delegate queue. Appending whole chunks
/// avoids an async iterator hop for every byte of JSON and artwork.
private final class BoundedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>
        var response: HTTPURLResponse?
        var data = Data()
        init(continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) { self.continuation = continuation }
    }
    private let server: ServerAddress
    private let limit: Int
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    init(server: ServerAddress, limit: Int) { self.server = server; self.limit = limit }
    func register(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) {
        lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation) }
    }
    private func finish(_ task: URLSessionTask, error: (any Error)? = nil) {
        guard let value = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error { value.continuation.resume(throwing: error) }
        else if let response = value.response { value.continuation.resume(returning: (value.data, response)) }
        else { value.continuation.resume(throwing: ClientError.invalidResponse) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            finish(dataTask, error: ClientError.invalidResponse); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            finish(dataTask, error: ClientError.responseTooLarge); completionHandler(.cancel); return
        }
        lock.withLock { pending[dataTask.taskIdentifier]?.response = response }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            guard let value = pending[dataTask.taskIdentifier] else { return false }
            guard data.count <= limit - value.data.count else { return true }
            value.data.append(data)
            return false
        }
        if oversized { finish(dataTask, error: ClientError.responseTooLarge); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = error as? URLError, error.code == .cancelled { finish(task, error: CancellationError()) }
        else { finish(task, error: error == nil ? nil : ClientError.network) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(server.contains) == true ? request : nil)
    }
}

private final class RequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func start(_ task: URLSessionTask) {
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() } else { task.resume() }
        }
    }
    func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
}

public final class URLSessionTransport: HTTPTransport, Sendable {
    private let session: URLSession
    private let delegate: BoundedDataDelegate
    public convenience init(server: ServerAddress) {
        self.init(server: server, configuration: .ephemeral)
    }
    // Internal injection allows URLProtocol tests of limits and cancellation.
    init(server: ServerAddress, configuration: URLSessionConfiguration, limit: Int = 12 * 1024 * 1024) {
        let config = configuration
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.urlCache = nil // Authenticated caching is explicitly account-scoped.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        delegate = BoundedDataDelegate(server: server, limit: limit)
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let cancellation = RequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, continuation: continuation)
                cancellation.start(task)
            }
        } onCancel: { cancellation.cancel() }
    }
    deinit { session.invalidateAndCancel() }
}

public struct ClientIdentity: Sendable {
    public let deviceID: String
    public let deviceName: String
    public let version: String
    public init(deviceID: String, deviceName: String, version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0") {
        self.deviceID = deviceID; self.deviceName = deviceName; self.version = version
    }
    public func authorization(token: String? = nil) -> String {
        // Quoted header values must never inject delimiters or control characters.
        func safe(_ value: String) -> String {
            String(value.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 && $0 != "\"" && $0 != "\\" })
        }
        var fields = [("Client", "Zorofin"), ("Device", deviceName), ("DeviceId", deviceID), ("Version", version)]
        if let token { fields.append(("Token", token)) }
        return "MediaBrowser " + fields.map { "\($0.0)=\"\(safe($0.1))\"" }.joined(separator: ", ")
    }
}
