import Foundation
import Testing
@testable import ZorofinCore

private actor DiscoveryTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let small: Bool
    let metadataStatus: Int
    let delay: Duration
    init(small: Bool = false, metadataStatus: Int = 200, delay: Duration = .zero) {
        self.small = small; self.metadataStatus = metadataStatus; self.delay = delay
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        let url = request.url!
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let history = query["isPlayed"] == "true"
        let genres = url.lastPathComponent == "Genres"
        let status = (history || genres) ? metadataStatus : 200
        let page: ItemPage
        if genres {
            page = .init(items: [MediaItem(id: "genre", name: "Drama & Adventure", type: "Genre")])
        } else if history {
            var episode = MediaItem(id: "episode", name: "Pilot", type: "Episode", userData: .init(played: true))
            episode.seriesId = "watched-series"; episode.seriesName = "A real watched show"
            page = .init(items: [episode, episode,
                MediaItem(id: "unplayed", name: "Not watched", userData: .init(played: false)),
                MediaItem(id: "watched-movie", name: "A real watched movie", userData: .init(played: true))])
        } else if url.lastPathComponent == "Similar" {
            let seed = url.deletingLastPathComponent().lastPathComponent
            page = .init(items: [MediaItem(id: seed, name: "Self"), MediaItem(id: "fixed", name: "Already at top"),
                MediaItem(id: "similar-\(seed)", name: "Recommendation"), MediaItem(id: "similar-\(seed)", name: "Duplicate"),
                MediaItem(id: "similar-\(seed)-2", name: "Recommendation 2"), MediaItem(id: "similar-\(seed)-3", name: "Recommendation 3"),
                MediaItem(id: "similar-\(seed)-4", name: "Recommendation 4"), MediaItem(id: "similar-\(seed)-5", name: "Recommendation 5"),
                MediaItem(id: "similar-\(seed)-6", name: "Recommendation 6"),
                MediaItem(id: "episode-result", name: "Episode", type: "Episode")], totalRecordCount: 10)
        } else if small {
            page = .init(items: [MediaItem(id: "fixed", name: "Only title")], totalRecordCount: 1)
        } else {
            let prefix = [query["includeItemTypes"], query["sortBy"], query["genres"], query["years"], query["isPlayed"], query["minCommunityRating"]].compactMap { $0 }.joined(separator: "-")
            let offset = Int(query["startIndex"] ?? "0") ?? 0
            page = .init(items: (offset..<(offset + 24)).map {
                var item = MediaItem(id: "\(prefix)-\($0)", name: "Title \($0)", type: query["includeItemTypes"] ?? "Movie")
                item.communityRating = 8
                return item
            }, totalRecordCount: 2400)
        }
        return (try Wire.encoder().encode(page), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private func discoveryClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://library.example/base")
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture"), transport: transport)
}

@Suite("Continuous native discovery") struct DiscoveryTests {
    @Test func laneOrderVariesBetweenVisitsButIsStableForTheSameSeed() async throws {
        func titles(seed: UInt64) async throws -> [String] {
            var feed = DiscoveryFeed(seed: seed)
            let client = try discoveryClient(DiscoveryTransport())
            var titles: [String] = []
            for _ in 0..<4 { titles += try await feed.next(client: client).map(\.title) }
            return titles
        }
        let first = try await titles(seed: 17)
        #expect(try await titles(seed: 17) == first)
        #expect(try await titles(seed: 28) != first)
        #expect(first[5].hasPrefix("Because you watched"))
    }
    @Test func cursorUsesRawCountAndHonorsEnd() {
        var cursor = LibraryPageCursor()
        cursor.accept(.init(items: [MediaItem(id: "a", name: "A"), MediaItem(id: "a", name: "A")], totalRecordCount: 3), limit: 2)
        #expect(cursor.offset == 2)
        #expect(cursor.hasMore)
        cursor.accept(.init(items: [MediaItem(id: "b", name: "B")], totalRecordCount: 3), limit: 2)
        #expect(cursor.offset == 3)
        #expect(!cursor.hasMore)
    }
    @Test func missingTotalsAndIgnoredOffsetsDoNotLoop() {
        var cursor = LibraryPageCursor()
        let page = ItemPage(items: [MediaItem(id: "a", name: "A")])
        cursor.accept(page, limit: 1)
        #expect(cursor.hasMore)
        cursor.accept(page, limit: 1)
        #expect(!cursor.hasMore)
        #expect(cursor.offset == 1)
        var short = LibraryPageCursor()
        short.accept(page, limit: 24)
        #expect(!short.hasMore)
        var empty = LibraryPageCursor()
        empty.accept(.init(items: [], totalRecordCount: 999), limit: 24)
        #expect(!empty.hasMore)
    }
    @Test func recommendationsUsePlayedHistoryAndCategoriesEndWithoutRepeating() async throws {
        let transport = DiscoveryTransport()
        let client = try discoveryClient(transport)
        var feed = DiscoveryFeed()
        var rows: [DiscoveryRow] = []
        for _ in 0..<18 { rows += try await feed.next(client: client, excluding: ["fixed"]) }
        let recommendations = rows.enumerated().filter { $0.element.title.hasPrefix("Because you watched") }
        #expect(recommendations.map(\.offset) == [5])
        #expect(recommendations.map(\.element.title) == ["Because you watched A real watched show"])
        #expect(recommendations.allSatisfy { $0.element.items.count >= 6 })
        #expect(!rows.isEmpty && rows.count < 20)
        #expect(!feed.hasMore)
        #expect(Set(rows.map(\.title)).count == rows.count)
        #expect(rows.allSatisfy { (6...20).contains($0.items.count) })
        #expect(rows.first?.title == "Highly rated movies")
        #expect(Set(rows.map(\.id)).count == rows.count)
        // LazyVStack flattens sibling ForEach IDs. Never collide with the fixed
        // integer shelf IDs or the named server-provided Home rows.
        #expect(rows.allSatisfy { $0.id.hasPrefix("discovery-") })
        let requests = await transport.requests
        #expect(requests.filter { $0.url?.query?.contains("minCommunityRating=7") == true }.count == 1)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "library.example" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true })
        #expect(requests.allSatisfy { $0.url?.absoluteString.contains("fixture-token") == false })
        #expect(requests.allSatisfy { $0.url?.query?.contains("userId=viewer") == true })
        #expect(requests.contains { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "genres", value: "Drama & Adventure")) == true })
    }
    @Test func sparseFirstPageFillsTheSameCategoryWithoutCreatingAnotherShelf() async throws {
        let transport = DiscoveryTransport()
        var feed = DiscoveryFeed(seed: 3)
        let client = try discoveryClient(transport)
        let excluded = Set((0..<22).map { "Movie-CommunityRating,SortName-Drama & Adventure-\($0)" })
        var rows: [DiscoveryRow] = []
        for _ in 0..<16 { rows += try await feed.next(client: client, excluding: excluded) }
        let genre = rows.filter { $0.title == "Drama & Adventure movies" }
        #expect(genre.count == 1)
        #expect(genre.first?.items.count == 20)
        let requests = await transport.requests
        #expect(requests.contains { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return query.contains(.init(name: "genres", value: "Drama & Adventure")) &&
                query.contains(.init(name: "startIndex", value: "24"))
        })
        let ids = rows.flatMap { $0.items.map(\.id) }
        #expect(Set(ids).count == ids.count)
    }
    @Test func duplicateOnlyLibraryEndsWithBoundedRequests() async throws {
        let transport = DiscoveryTransport(small: true)
        var feed = DiscoveryFeed()
        let rows = try await feed.next(client: discoveryClient(transport), excluding: ["fixed"])
        #expect(rows.isEmpty)
        #expect(!feed.hasMore)
        #expect(await transport.requests.count <= 10) // two metadata + at most eight pages
    }
    @Test func missingOptionalMetadataStillBrowses() async throws {
        let transport = DiscoveryTransport(metadataStatus: 503)
        var feed = DiscoveryFeed()
        let rows = try await feed.next(client: discoveryClient(transport))
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { !$0.title.hasPrefix("Because") })
    }
    @Test func expiredSessionDoesNotBecomeEmptyHistory() async throws {
        var feed = DiscoveryFeed()
        await #expect(throws: ClientError.unauthorized) {
            try await feed.next(client: discoveryClient(DiscoveryTransport(metadataStatus: 401)))
        }
    }
    @Test func cancelledFeedCannotPublishResults() async throws {
        let transport = DiscoveryTransport(delay: .seconds(5))
        let client = try discoveryClient(transport)
        let task = Task {
            var feed = DiscoveryFeed()
            return try await feed.next(client: client)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func adjacentRowsDoNotRepeatTitles() async throws {
        var feed = DiscoveryFeed()
        let client = try discoveryClient(DiscoveryTransport())
        var previous: Set<String> = []
        for _ in 0..<8 {
            for row in try await feed.next(client: client) {
                let ids = Set(row.items.map(\.id))
                #expect(ids.count == row.items.count)
                #expect(ids.isDisjoint(with: previous))
                previous = ids
            }
        }
    }
}
