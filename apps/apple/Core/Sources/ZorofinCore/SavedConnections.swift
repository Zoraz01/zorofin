import Foundation

public extension ServerAddress {
    /// A server is its origin AND installation path, never its display name.
    var storageKey: String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
        return parts.url!.absoluteString
    }
}

public struct SavedAccount: Codable, Identifiable, Sendable {
    public let id: UUID
    public let server: ServerAddress
    public var serverName: String
    public var viewer: Viewer
    public var session: Session?
}

public struct SavedServer: Identifiable, Sendable {
    public let address: ServerAddress
    public let name: String
    public let accounts: [SavedAccount]
    public var id: String { address.storageKey }
}

/// One versioned Keychain payload makes the account list and selection atomic.
/// Passwords and temporary Quick Connect secrets never enter this model.
public struct SavedConnections: Codable, Sendable {
    public private(set) var accounts: [SavedAccount] = []
    public private(set) var activeID: UUID?
    private let schemaVersion = 1
    private enum CodingKeys: String, CodingKey { case schemaVersion, accounts, activeID }

    public init() {}

    public var activeAccount: SavedAccount? { accounts.first { $0.id == activeID } }

    /// The sign-in to reopen at cold launch. A personal device (iPhone/iPad)
    /// reopens the last account. A shared device (Apple TV) asks "Who's
    /// watching?" when its last server has more than one saved viewer.
    public func launchSession(sharedDevice: Bool) -> Session? {
        guard let active = activeAccount, let session = active.session else { return nil }
        if sharedDevice && accounts.filter({ $0.server.storageKey == session.server.storageKey }).count > 1 { return nil }
        return session
    }
    public var servers: [SavedServer] {
        var result: [SavedServer] = []
        for account in accounts where !result.contains(where: { $0.id == account.server.storageKey }) {
            result.append(.init(address: account.server, name: account.serverName,
                accounts: accounts.filter { $0.server.storageKey == account.server.storageKey }))
        }
        return result
    }

    @discardableResult public mutating func remember(_ session: Session, serverName: String) -> UUID {
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? (session.server.url.host ?? "Jellyfin server") : name
        let index = accounts.firstIndex { $0.server.storageKey == session.server.storageKey && $0.viewer.id == session.viewer.id }
        let id = index.map { accounts[$0].id } ?? UUID()
        let account = SavedAccount(id: id, server: session.server, serverName: displayName, viewer: session.viewer, session: session)
        if let index { accounts[index] = account } else { accounts.append(account) }
        for i in accounts.indices where accounts[i].server.storageKey == session.server.storageKey {
            accounts[i].serverName = displayName
        }
        activeID = id
        return id
    }

    public mutating func select(_ id: UUID) throws {
        guard accounts.contains(where: { $0.id == id && $0.session != nil }) else { throw ClientError.missingSession }
        activeID = id
    }

    public mutating func clearSelection() { activeID = nil }

    public mutating func signOut(_ id: UUID) {
        if let index = accounts.firstIndex(where: { $0.id == id }) { accounts[index].session = nil }
        if activeID == id { activeID = nil }
    }

    public mutating func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if !values.contains(.schemaVersion) {
            // Legacy single-session payload: migration is read-only until the next
            // successful atomic Keychain update. A failed write preserves the old login.
            let session = try Session(from: decoder)
            remember(session, serverName: session.server.url.host ?? "Jellyfin server")
            return
        }
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw ClientError.invalidResponse }
        accounts = try values.decode([SavedAccount].self, forKey: .accounts)
        activeID = try values.decodeIfPresent(UUID.self, forKey: .activeID)
        var ids = Set<UUID>(), identities = Set<String>()
        for account in accounts {
            let identity = account.server.storageKey + "\n" + account.viewer.id
            guard ids.insert(account.id).inserted, identities.insert(identity).inserted,
                  account.session.map({ $0.server.storageKey == account.server.storageKey && $0.viewer.id == account.viewer.id }) ?? true
            else { throw ClientError.invalidResponse }
        }
        guard activeID == nil || activeAccount?.session != nil else { throw ClientError.invalidResponse }
    }
}
