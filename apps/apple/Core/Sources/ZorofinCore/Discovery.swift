import Foundation

/// Advances by server results, not the number of cards left after de-duplication.
/// Stops servers that ignore startIndex from creating a repeated-page loop.
public struct LibraryPageCursor: Sendable {
    public private(set) var offset = 0
    public private(set) var hasMore = true
    private var previousIDs: [String] = []
    public init() {}
    public mutating func accept(_ page: ItemPage, limit: Int) {
        let ids = page.items.map(\.id)
        guard !ids.isEmpty, ids != previousIDs else { hasMore = false; return }
        previousIDs = ids
        offset += page.items.count
        hasMore = page.totalRecordCount.map { offset < $0 } ?? (page.items.count >= limit)
    }
}

public struct DiscoveryRow: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [MediaItem]
}

struct WatchedSeed: Sendable {
    let id: String
    let title: String
    static func make(_ items: [MediaItem]) -> [Self] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard item.userData?.played == true else { return nil }
            let id: String, title: String
            if item.isEpisode, let series = item.seriesId, let name = item.seriesName {
                id = series; title = name
            } else if item.type == "Movie" || item.isSeries {
                id = item.id; title = item.name
            } else { return nil }
            guard !id.isEmpty, !title.isEmpty, seen.insert(id).inserted else { return nil }
            return Self(id: id, title: title)
        }
    }
}

private struct DiscoveryLane: Sendable {
    let title: String
    let type: String
    var genre: String?
    var years: String?
    var minimumRating: String?
    var unplayed = false
    var sort = "CommunityRating,SortName"
    var cursor = LibraryPageCursor()
}

/// A value snapshot belongs to one Home/account visit. The view only commits a
/// completed batch if its account and refresh revision still match.
public struct DiscoveryFeed: Sendable {
    public private(set) var hasMore = true
    private var lanes: [DiscoveryLane] = []
    private var seeds: [WatchedSeed] = []
    private var initialized = false
    private var serial = 0
    private var ordinarySinceRecommendation = 0
    private var recentIDs: [[String]] = []
    private var random: HomeRandom
    public init(seed: UInt64 = .random(in: .min ... .max)) { random = HomeRandom(seed: seed) }

    private mutating func prepare(_ client: JellyfinClient) async throws {
        // Independent optional metadata: a server without history/genres still
        // gets ordinary catalogue rows. Authentication failures remain visible.
        async let genresResult = optionalMetadata(client.discoveryGenres)
        async let historyResult = optionalMetadata(client.discoveryHistory)
        let (genres, history) = try await (genresResult, historyResult)
        seeds = Array(WatchedSeed.make(history.items).prefix(8))
        lanes = [
            DiscoveryLane(title: "Highly rated movies", type: "Movie", minimumRating: "7"),
            DiscoveryLane(title: "Shows to discover", type: "Series", unplayed: true),
            DiscoveryLane(title: "Movies you haven't watched", type: "Movie", unplayed: true, sort: "PremiereDate,SortName")
        ]
        var seen: Set<String> = []
        let names = genres.items.map(\.name).filter {
            !$0.isEmpty && $0.count <= 80 && !$0.contains("|") && seen.insert($0.lowercased()).inserted
        }
        // One stable order per visit. Interleave formats instead of a separate
        // personalization section, and keep pageable broad lanes as a fallback.
        for (index, name) in names.enumerated() {
            lanes.append(DiscoveryLane(title: "\(name) movies", type: "Movie", genre: name))
            lanes.append(DiscoveryLane(title: "\(name) shows", type: "Series", genre: name, sort: "PremiereDate,SortName"))
            if index < 4 {
                let decade = 2020 - index * 10
                lanes.append(DiscoveryLane(title: "Movies from the \(decade)s", type: "Movie",
                    years: (decade..<(decade + 10)).map(String.init).joined(separator: ",")))
            }
        }
        lanes += [DiscoveryLane(title: "More movies to explore", type: "Movie", sort: "SortName"),
                  DiscoveryLane(title: "More shows to explore", type: "Series", sort: "SortName")]
        // Randomize lane order once per visit; retain each lane's deterministic
        // item sort/cursor and rotate fairly so a broad lane cannot starve others.
        lanes.shuffle(using: &random)
        initialized = true
    }

    /// At most two rows / eight page requests per demand signal. An empty batch
    /// with hasMore=true requires another user gesture; it must not spin in UI.
    public mutating func next(client: JellyfinClient, excluding: Set<String> = []) async throws -> [DiscoveryRow] {
        try Task.checkCancellation()
        if !initialized { try await prepare(client) }
        var result: [DiscoveryRow] = []
        var requests = 0
        while result.count < 2 && requests < 8 && !lanes.isEmpty {
            try Task.checkCancellation()
            let blocked = excluding.union(recentIDs.flatMap { $0 })
            let title: String
            let page: ItemPage
            var seedID: String?
            if ordinarySinceRecommendation >= 5, let seed = seeds.first {
                page = try await client.discoverySimilar(seed.id)
                seeds.removeFirst()
                seedID = seed.id
                title = "Because you watched \(seed.title)"
            } else {
                var lane = lanes[0]
                page = try await client.discoveryItems(lane)
                lanes.removeFirst()
                lane.cursor.accept(page, limit: 24)
                if lane.cursor.hasMore { lanes.append(lane) }
                title = lane.title
            }
            requests += 1
            var seen = blocked
            if let seedID { seen.insert(seedID) }
            let items = page.items.filter {
                ($0.type == "Movie" || $0.isSeries) && !$0.id.isEmpty && seen.insert($0.id).inserted
            }
            guard !items.isEmpty else { continue }
            serial += 1
            result.append(DiscoveryRow(id: "discovery-\(serial)", title: title, items: items))
            recentIDs.append(items.map(\.id))
            if recentIDs.count > 6 { recentIDs.removeFirst() }
            if seedID != nil { ordinarySinceRecommendation = 0 }
            else { ordinarySinceRecommendation += 1 }
        }
        hasMore = !lanes.isEmpty
        return result
    }
}

private func optionalMetadata(_ fetch: @Sendable () async throws -> ItemPage) async throws -> ItemPage {
    do { return try await fetch() }
    catch is CancellationError { throw CancellationError() }
    catch ClientError.unauthorized { throw ClientError.unauthorized }
    catch ClientError.forbidden { throw ClientError.forbidden }
    catch { return ItemPage(items: []) }
}

extension JellyfinClient {
    private func discoveryQuery(includeStreams: Bool = false) throws -> [URLQueryItem] {
        guard let session else { throw ClientError.missingSession }
        return [.init(name: "userId", value: session.viewer.id), .init(name: "recursive", value: "true"),
                .init(name: "limit", value: "24"), .init(name: "fields", value: includeStreams ? "Overview,Genres,MediaStreams" : "Overview,Genres"),
                .init(name: "enableUserData", value: "true"), .init(name: "enableTotalRecordCount", value: "true"),
                .init(name: "imageTypeLimit", value: "1"), .init(name: "excludeLocationTypes", value: "Virtual"),
                .init(name: "isPlaceHolder", value: "false")]
    }
    fileprivate func discoveryGenres() async throws -> ItemPage {
        try await request(ItemPage.self, path: ["Genres"], query: discoveryQuery() + [
            .init(name: "includeItemTypes", value: "Movie,Series"), .init(name: "sortBy", value: "SortName"),
            .init(name: "enableImages", value: "false")], cachePolicy: .library)
    }
    fileprivate func discoveryHistory() async throws -> ItemPage {
        try await request(ItemPage.self, path: ["Items"], query: discoveryQuery() + [
            .init(name: "includeItemTypes", value: "Movie,Episode"), .init(name: "isPlayed", value: "true"),
            .init(name: "sortBy", value: "DatePlayed,SortName"), .init(name: "sortOrder", value: "Descending")], cachePolicy: .activity)
    }
    fileprivate func discoverySimilar(_ id: String) async throws -> ItemPage {
        try await request(ItemPage.self, path: ["Items", id, "Similar"], query: discoveryQuery(includeStreams: true), cachePolicy: .library)
    }
    fileprivate func discoveryItems(_ lane: DiscoveryLane) async throws -> ItemPage {
        var query = try discoveryQuery(includeStreams: true) + [.init(name: "includeItemTypes", value: lane.type),
            .init(name: "startIndex", value: String(lane.cursor.offset)), .init(name: "sortBy", value: lane.sort),
            .init(name: "sortOrder", value: lane.sort == "SortName" ? "Ascending" : "Descending")]
        if let genre = lane.genre { query.append(.init(name: "genres", value: genre)) }
        if let years = lane.years { query.append(.init(name: "years", value: years)) }
        if let rating = lane.minimumRating { query.append(.init(name: "minCommunityRating", value: rating)) }
        if lane.unplayed { query.append(.init(name: "isPlayed", value: "false")) }
        return try await request(ItemPage.self, path: ["Items"], query: query, cachePolicy: .library)
    }
}
