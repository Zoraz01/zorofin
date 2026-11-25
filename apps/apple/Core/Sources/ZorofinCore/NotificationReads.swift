import Foundation

/// Account state is fetched, never used as authorization for an item or ticket.
public struct NotificationReadState: Codable, Sendable, Equatable {
    public var initialized: Bool
    public var requests: Set<Int>
    public var replies: Set<String>
    public init(initialized: Bool = false, requests: Set<Int> = [], replies: Set<String> = []) {
        self.initialized = initialized; self.requests = requests; self.replies = replies
    }
    static func decode(_ data: Data) throws -> Self {
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.requests.count <= 2000, state.replies.count <= 500,
              state.requests.allSatisfy({ $0 > 0 }), state.replies.allSatisfy({ $0.contains("|") }) else { throw ClientError.invalidResponse }
        return state
    }
    public func merging(_ other: Self) -> Self {
        .init(initialized: initialized || other.initialized, requests: requests.union(other.requests), replies: replies.union(other.replies))
    }
}

public extension SupportReply {
    /// Preserve updatedAt exactly as delivered. Local message hashes stay local.
    var accountReadKey: String { id + "|" + updatedAt }
}

public extension JellyfinClient {
    func notificationReads() async throws -> NotificationReadState {
        let data = try await requestData(["Zorofin", "Notifications", "Read"], extensionToken: true, expectedStatus: 200)
        return try NotificationReadState.decode(data)
    }
    func markNotificationReads(requests: [Int] = [], replies: [SupportReply] = [], initialize: Bool = false) async throws -> NotificationReadState {
        struct Reply: Encodable { let id: String; let updatedAt: String }
        struct Payload: Encodable { let requests: [Int]; let replies: [Reply]; let initialize: Bool }
        let ids = Array(Set(requests)).sorted()
        guard ids.allSatisfy({ $0 > 0 }) else { throw ClientError.invalidResponse }
        let messages = replies.filter { !$0.isAnnouncement }.map { Reply(id: $0.id, updatedAt: $0.updatedAt) }
        var batches: [Payload] = []
        for offset in stride(from: 0, to: ids.count, by: 500) {
            batches.append(.init(requests: Array(ids[offset..<min(ids.count, offset + 500)]), replies: [], initialize: false))
        }
        for offset in stride(from: 0, to: messages.count, by: 500) {
            batches.append(.init(requests: [], replies: Array(messages[offset..<min(messages.count, offset + 500)]), initialize: false))
        }
        if batches.isEmpty { batches = [.init(requests: [], replies: [], initialize: false)] }
        var state = NotificationReadState()
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            let body = Payload(requests: batch.requests, replies: batch.replies, initialize: initialize && index == batches.count - 1)
            let data = try await requestData(["Zorofin", "Notifications", "Read"], method: "POST", body: JSONEncoder().encode(body), extensionToken: true, expectedStatus: 200)
            state = state.merging(try NotificationReadState.decode(data))
        }
        return state
    }
}
