import Foundation
import CryptoKit

/// Local to one server/account on this device. Cached history is never an
/// authorization grant: opening a title still resolves its current permissions.
public struct NotificationHistory: Codable, Sendable {
    public var requestsInitialized = false
    public var requests: [RequestAvailabilityNotice] = []
    public var readRequestIDs: Set<Int> = []
    public var hiddenReplies: [SupportReply] = []
    public var seenReplyKeys: Set<String> = []
    public init() {}
}

public extension SupportReply {
    /// A later response on the same ticket is a new notification, even when
    /// a server supplies the same timestamp for two different messages.
    var notificationKey: String {
        SHA256.hash(data: Data((id + "\n" + updatedAt + "\n" + message).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public actor NotificationHistoryStore {
    private let root: URL?
    private let defaults: UserDefaults?
    private static let prefix = "ZorofinNotificationHistory-v1."
    public init(root: URL? = nil) {
        #if os(tvOS)
        self.root = root; defaults = root == nil ? .standard : nil
        #else
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZorofinNotificationHistory-v1", isDirectory: true)
        defaults = nil
        #endif
    }
    init(defaultsSuiteName: String) { root = nil; defaults = UserDefaults(suiteName: defaultsSuiteName)! }
    private func key(_ server: ServerAddress, _ viewerID: String) -> String {
        Self.prefix + SHA256.hash(data: Data((server.storageKey + "\n" + viewerID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    public func load(server: ServerAddress, viewerID: String) throws -> NotificationHistory {
        let key = key(server, viewerID), data: Data
        if let defaults {
            guard let saved = defaults.data(forKey: key) else { return .init() }
            data = saved
        } else if let root {
            let url = root.appendingPathComponent(key + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1024 else { throw SettingsError.storageFull }
            data = try Data(contentsOf: url)
        } else { throw SettingsError.invalidInput }
        guard data.count <= 256 * 1024 else { throw SettingsError.storageFull }
        let state = try JSONDecoder().decode(NotificationHistory.self, from: data)
        guard state.requests.count <= 100, state.hiddenReplies.count <= 30,
              state.readRequestIDs.count <= 20_000, state.readRequestIDs.allSatisfy({ $0 > 0 }),
              state.seenReplyKeys.count <= 1000 else { throw SettingsError.invalidInput }
        return state
    }
    /// Call only after a complete successful availability check. The first
    /// snapshot is history, including migration from older unread-only builds.
    public func receiveRequests(_ notices: [RequestAvailabilityNotice], legacyReadIDs: Set<Int> = [],
                                server: ServerAddress, viewerID: String) throws -> NotificationHistory {
        var state = try load(server: server, viewerID: viewerID)
        state.readRequestIDs.formUnion(legacyReadIDs)
        if !state.requestsInitialized {
            state.readRequestIDs.formUnion(notices.map(\.id))
            state.requestsInitialized = true
        }
        let incoming = Set(notices.map(\.id))
        let safe = notices.map { notice in
            RequestAvailabilityNotice(id: notice.id, kind: notice.kind, titleID: notice.titleID,
                title: String(notice.title.prefix(500)),
                posterURL: RequestArtwork.url(absolute: notice.posterURL)?.absoluteString, is4K: notice.is4K)
        }
        state.requests = Array((safe + state.requests.filter { !incoming.contains($0.id) }).prefix(100))
        try save(state, server: server, viewerID: viewerID)
        return state
    }
    public func seeRequest(_ id: Int, server: ServerAddress, viewerID: String) throws -> Set<Int> {
        guard id > 0 else { throw SettingsError.invalidInput }
        var state = try load(server: server, viewerID: viewerID)
        state.readRequestIDs.insert(id)
        try save(state, server: server, viewerID: viewerID)
        return state.readRequestIDs
    }
    public func seeReply(_ reply: SupportReply, server: ServerAddress, viewerID: String) throws -> NotificationHistory {
        var state = try load(server: server, viewerID: viewerID)
        // Refuse oversized payloads rather than truncating a message's identity.
        guard reply.message.utf8.count <= 16_384, reply.issueType.utf8.count <= 512,
              (reply.affectedMedia?.utf8.count ?? 0) <= 1024 else { throw SettingsError.invalidInput }
        state.seenReplyKeys.insert(reply.notificationKey)
        state.hiddenReplies.removeAll { $0.notificationKey == reply.notificationKey }
        state.hiddenReplies.insert(reply, at: 0)
        state.hiddenReplies = Array(state.hiddenReplies.prefix(30))
        try save(state, server: server, viewerID: viewerID)
        return state
    }
    private func save(_ state: NotificationHistory, server: ServerAddress, viewerID: String) throws {
        guard state.readRequestIDs.count <= 20_000, state.seenReplyKeys.count <= 1000 else { throw SettingsError.storageFull }
        let data = try JSONEncoder().encode(state), key = key(server, viewerID)
        guard data.count <= 256 * 1024 else { throw SettingsError.storageFull }
        if let defaults {
            let otherBytes = defaults.dictionaryRepresentation().reduce(0) { total, pair in
                total + (pair.key.hasPrefix(Self.prefix) && pair.key != key ? (pair.value as? Data)?.count ?? 0 : 0)
            }
            guard otherBytes + data.count <= 384 * 1024 else { throw SettingsError.storageFull }
            defaults.set(data, forKey: key)
        } else if let root {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root.appendingPathComponent(key + ".json")
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        } else { throw SettingsError.invalidInput }
    }
}
