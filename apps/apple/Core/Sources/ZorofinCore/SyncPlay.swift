import Foundation

/// Jellyfin's built-in group contract. No server extension is required.
public struct SyncPlayGroup: Codable, Sendable, Identifiable, Equatable {
    public var groupId: String
    public var groupName: String
    public var state: String?
    public var participants: [String]
    public var id: String { groupId }
}

public struct SyncPlayQueue: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var itemId: String
        public var playlistItemId: String
    }
    public var reason: String
    public var lastUpdate: String
    public var playlist: [Item]
    public var playingItemIndex: Int
    public var startPositionTicks: Int64
    public var isPlaying: Bool
    public var current: Item? {
        playlist.indices.contains(playingItemIndex) ? playlist[playingItemIndex] : nil
    }
}

public struct SyncPlayCommand: Codable, Sendable {
    public var groupId: String
    public var playlistItemId: String?
    public var when: String
    public var positionTicks: Int64?
    public var command: String
    public var emittedAt: String
}

public struct SyncPlayMessage: Decodable, Sendable {
    public var messageType: String
    public var data: JSONValue?
    public func payload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data else { throw ClientError.invalidResponse }
        return try Wire.decoder().decode(type, from: JSONEncoder().encode(data))
    }
}

public struct SyncPlayUpdate: Decodable, Sendable {
    public var groupId: String
    public var type: String
    public var data: JSONValue?
    public func payload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data else { throw ClientError.invalidResponse }
        return try Wire.decoder().decode(type, from: JSONEncoder().encode(data))
    }
}

public enum SyncPlayTime {
    public static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public extension JellyfinClient {
    func syncPlayGroups() async throws -> [SyncPlayGroup] {
        try await request([SyncPlayGroup].self, path: ["SyncPlay", "List"])
    }
    func syncPlayGroup(_ id: String) async throws -> SyncPlayGroup {
        try await request(SyncPlayGroup.self, path: ["SyncPlay", id])
    }
    func createSyncPlayGroup(name: String) async throws -> SyncPlayGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw ClientError.invalidResponse }
        return try await request(SyncPlayGroup.self, path: ["SyncPlay", "New"], method: "POST",
            body: JSONEncoder().encode(["GroupName": name]))
    }
    func syncPlay(_ action: String, body: [String: JSONValue]? = nil) async throws {
        let allowed: Set<String> = ["Join", "Leave", "Pause", "Unpause", "Stop", "Seek", "Ready",
            "Buffering", "Ping", "SetIgnoreWait", "SetNewQueue", "NextItem"]
        guard allowed.contains(action) else { throw ClientError.invalidResponse }
        _ = try await requestData(["SyncPlay", action], method: "POST",
                                 body: try body.map { try JSONEncoder().encode($0) })
    }
    func syncPlayClock() async throws -> (offset: TimeInterval, roundTrip: TimeInterval) {
        struct Clock: Decodable, Sendable {
            var requestReceptionTime: String
            var responseTransmissionTime: String
        }
        let start = Date()
        let clock = try await request(Clock.self, path: ["GetUtcTime"])
        let end = Date()
        guard let received = SyncPlayTime.date(clock.requestReceptionTime),
              let sent = SyncPlayTime.date(clock.responseTransmissionTime) else { throw ClientError.invalidResponse }
        return ((received.timeIntervalSince(start) + sent.timeIntervalSince(end)) / 2,
                max(0, end.timeIntervalSince(start) - sent.timeIntervalSince(received)))
    }
}

/// A same-server authenticated socket. Credentials never appear in the URL or logs.
/// Reject redirects rather than forwarding the Authorization header to another host.
private final class SyncPlaySocketDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor SyncPlaySocket {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    public init() {}
    public func connect(client: JellyfinClient) async throws {
        close()
        guard let viewer = client.session, viewer.server == client.server else { throw ClientError.missingSession }
        let endpoint = try client.server.endpoint(["socket"], query: [.init(name: "deviceId", value: client.identity.deviceID)])
        guard var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: true) else { throw ClientError.unsafeURL }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        guard let url = parts.url else { throw ClientError.unsafeURL }
        var request = URLRequest(url: url)
        request.setValue(client.identity.authorization(token: viewer.token), forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: config, delegate: SyncPlaySocketDelegate(), delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1024 * 1024
        self.session = session; task = socket
        socket.resume()
        do { try await ping() } catch { close(); throw ClientError.network }
    }
    public func ping() async throws {
        guard let task else { throw ClientError.network }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if error != nil { result.resume(throwing: ClientError.network) }
                else { result.resume() }
            }
        }
    }
    public func receive() async throws -> SyncPlayMessage {
        guard let task else { throw ClientError.network }
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let bytes): data = bytes
        case .string(let text): data = Data(text.utf8)
        @unknown default: throw ClientError.invalidResponse
        }
        return try Wire.decoder().decode(SyncPlayMessage.self, from: data)
    }
    public func keepAlive() async throws {
        guard let task else { return }
        try await task.send(.string("{\"MessageType\":\"KeepAlive\"}"))
    }
    public func close() {
        task?.cancel(with: .goingAway, reason: nil); task = nil
        session?.invalidateAndCancel(); session = nil
    }
}
