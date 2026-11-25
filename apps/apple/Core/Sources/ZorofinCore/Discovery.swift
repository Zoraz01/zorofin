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
    var pending: [MediaItem] = []
    var pages = 0
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
    private var shownIDs: Set<String> = []
    private var shownTitles: Set<String> = []
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
        // One shelf per category/visit. Page only to fill a substantial shelf;
        // movie genres reflect the permitted movie library rather than TV-only tags.
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
        // Keep highly rated near the start, then vary movie-first categories
        // with shows interleaved. Broad categories cannot repeat or starve others.
        lanes.shuffle(using: &random)
        let rated = lanes.first { $0.minimumRating != nil }!
        var movies = lanes.filter { $0.type == "Movie" && $0.minimumRating == nil }
        var shows = lanes.filter { $0.type == "Series" }
        lanes = [rated]
        while !movies.isEmpty || !shows.isEmpty {
            for _ in 0..<min(3, movies.count) { lanes.append(movies.removeFirst()) }
            if !shows.isEmpty { lanes.append(shows.removeFirst()) }
        }
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
            let blocked = excluding.union(shownIDs)
            let title: String
            let page: ItemPage
            var seedID: String?
            var category: DiscoveryLane?
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
                lane.pages += 1
                category = lane
                title = lane.title
            }
            requests += 1
            var seen = blocked
            if let seedID { seen.insert(seedID) }
            let available = ((category?.pending ?? []) + page.items).filter { item in
                guard item.type == "Movie" || item.isSeries,
                      category == nil || item.type == category?.type,
                      !item.id.isEmpty, seen.insert(item.id).inserted else { return false }
                if category?.minimumRating != nil {
                    guard let rating = item.communityRating, rating.isFinite, rating >= 7 else { return false }
                }
                return true
            }
            if available.count < 6 {
                if var lane = category, lane.cursor.hasMore, lane.pages < 4 {
                    lane.pending = available
                    lanes.insert(lane, at: 0)
                }
                continue
            }
            let titleKey = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            guard shownTitles.insert(titleKey).inserted else { continue }
            let items = Array(available.prefix(20))
            shownIDs.formUnion(items.map(\.id))
            serial += 1
            result.append(DiscoveryRow(id: "discovery-\(serial)", title: title, items: items))
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
        try await request(ItemPage.self, path: ["Genres"], query: discoveryQuery().filter { $0.name != "limit" } + [
            .init(name: "limit", value: "100"),
            .init(name: "includeItemTypes", value: "Movie"), .init(name: "sortBy", value: "SortName"),
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
