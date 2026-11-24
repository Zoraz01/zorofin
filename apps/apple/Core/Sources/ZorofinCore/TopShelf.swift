import Foundation

/// Only opaque account/item identifiers enter Home Screen actions. Never a server URL or token.
public struct TopShelfLink: Hashable, Sendable {
    public enum Action: String, Sendable { case play, details }
    public let accountID: UUID
    public let itemID: String
    public let action: Action
    public init?(accountID: UUID, itemID: String, action: Action) {
        guard Self.validItemID(itemID) else { return nil }
        self.accountID = accountID; self.itemID = itemID; self.action = action
    }
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "zorofin", parts.host == "top-shelf", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.fragment == nil,
              let query = parts.queryItems, query.count == 1, query[0].name == "action",
              let rawAction = query[0].value, let action = Action(rawValue: rawAction) else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, let account = UUID(uuidString: String(path[1])) else { return nil }
        self.init(accountID: account, itemID: String(path[2]), action: action)
    }
    public var url: URL {
        URL(string: "zorofin://top-shelf/\(accountID.uuidString)/\(itemID)?action=\(action.rawValue)")!
    }
    public static func validItemID(_ value: String) -> Bool {
        value.range(of: "^(?:[a-fA-F0-9]{32}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})$", options: .regularExpression) != nil
    }
}

public struct TopShelfEntry: Codable, Sendable {
    public let itemID: String
    public let title: String
    public let context: String
    public let summary: String
    public let genre: String?
    public let duration: Double
    public let imageName: String
    public init(item: MediaItem, continuing: Bool, imageName: String) {
        itemID = item.id; title = Self.clean(item.displayTitle, limit: 120)
        context = continuing ? "Continue Watching" : "From your library"
        summary = Self.clean([item.isEpisode ? item.episodeLabel : nil, item.overview].compactMap { $0 }.joined(separator: " · "), limit: 600)
        genre = item.genres?.first.map { Self.clean($0, limit: 60) }
        duration = max(0, min(Double(item.runTimeTicks ?? 0) / 10_000_000, 86_400))
        self.imageName = imageName
    }
    private static func clean(_ text: String, limit: Int) -> String {
        String(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(limit))
    }
    public var isValid: Bool {
        TopShelfLink.validItemID(itemID) && !title.isEmpty && title.count <= 120 && summary.count <= 600 &&
        ["Continue Watching", "From your library"].contains(context) && (genre?.count ?? 0) <= 60 &&
        duration.isFinite && (0...86_400).contains(duration) && Self.validImageName(imageName)
    }
    public static func validImageName(_ name: String) -> Bool {
        name.hasSuffix(".jpg") && name.count == 40 && UUID(uuidString: String(name.dropLast(4))) != nil
    }
}

public struct TopShelfSnapshot: Codable, Sendable {
    public static let appGroup = "group.org.zorofin.app.tv.shared"
    public static let lifetime: TimeInterval = 6 * 60 * 60
    public let version: Int
    public let revision: UUID
    public let accountID: UUID
    public let createdAt: Date
    public let entries: [TopShelfEntry]
    public init(accountID: UUID, entries: [TopShelfEntry], now: Date = .now) {
        version = 1; revision = UUID(); self.accountID = accountID; createdAt = now; self.entries = entries
    }
    public func isValid(at now: Date = .now) -> Bool {
        version == 1 && now.timeIntervalSince(createdAt) >= -60 && now.timeIntervalSince(createdAt) < Self.lifetime &&
        !entries.isEmpty && entries.count <= 8 && entries.allSatisfy(\.isValid) &&
        Set(entries.map(\.itemID)).count == entries.count && Set(entries.map(\.imageName)).count == entries.count
    }
}

/// Single app writer, extension reader. The manifest is the commit point; images are immutable.
/// No credentials, server addresses or raw API responses are stored here.
public struct TopShelfStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    private var manifest: URL { root.appendingPathComponent("snapshot.json") }
    public func imageURL(_ entry: TopShelfEntry) -> URL { root.appendingPathComponent(entry.imageName) }
    public func load(now: Date = .now) -> TopShelfSnapshot? {
        guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024,
              let data = try? Data(contentsOf: manifest), let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data),
              snapshot.isValid(at: now), snapshot.entries.allSatisfy({ entry in
                  guard let values = try? imageURL(entry).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                        values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else { return false }
                  return (1...3 * 1024 * 1024).contains(size)
              }) else { return nil }
        return snapshot
    }
    public func save(_ snapshot: TopShelfSnapshot, images: [String: Data], now: Date = .now) throws {
        guard snapshot.isValid(at: now), Set(images.keys) == Set(snapshot.entries.map(\.imageName)),
              images.values.allSatisfy({ !$0.isEmpty && $0.count <= 3 * 1024 * 1024 }) else { throw ClientError.invalidResponse }
        let previous = load(now: now)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, data) in images { try data.write(to: root.appendingPathComponent(name), options: .atomic) }
        try JSONEncoder().encode(snapshot).write(to: manifest, options: .atomic)
        // Keep one older image set for an extension that is finishing a read during replacement.
        let keep = Set(snapshot.entries.map(\.imageName) + (previous?.entries.map(\.imageName) ?? []) + ["snapshot.json"])
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
    public func clear() {
        // Removing the manifest first prevents a partial cache from being published.
        try? FileManager.default.removeItem(at: manifest)
        try? FileManager.default.removeItem(at: root)
    }
}

public enum TopShelfSelection {
    /// Four Continue Watching titles, then featured movies. The input may include
    /// unstarted Next Up episodes from the combined Home shelf.
    public static func candidates(resume: [MediaItem], movies: [MediaItem]) -> [(item: MediaItem, continuing: Bool)] {
        var result: [(MediaItem, Bool)] = [], seen = Set<String>(), series = Set<String>()
        for item in resume where result.count < 4 {
            guard (item.type == "Movie" || item.isEpisode),
                  item.resumeTicks > 0 || (item.isEpisode && item.userData?.played != true),
                  TopShelfLink.validItemID(item.id), !seen.contains(item.id) else { continue }
            if let id = item.seriesId, item.isEpisode, !series.insert(id).inserted { continue }
            seen.insert(item.id); result.append((item, true))
        }
        // Extra candidates allow an absent/corrupt backdrop to be skipped without an empty shelf.
        for item in movies where result.count < 12 {
            guard item.type == "Movie", TopShelfLink.validItemID(item.id), seen.insert(item.id).inserted else { continue }
            result.append((item, false))
        }
        return result
    }
}
