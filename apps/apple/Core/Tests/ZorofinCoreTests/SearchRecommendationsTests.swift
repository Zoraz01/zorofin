import Foundation
import Testing
@testable import ZorofinCore

private func searchItem(_ id: String, type: String = "Movie", played: Bool = false, rating: Double = 7, art: Bool = true) -> MediaItem {
    var item = MediaItem(id: id, name: "Title " + id, type: type, userData: .init(played: played))
    item.communityRating = rating
    item.imageTags = art ? ["Primary": "poster-" + id] : nil
    return item
}
private actor SearchTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status = 200
    func setStatus(_ status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let term = query.first { $0.name == "searchTerm" }?.value
        let type = query.first { $0.name == "includeItemTypes" }?.value ?? "Movie"
        let page = ItemPage(items: term == nil ? [searchItem(type, type: type)] : [searchItem("actual-match")], totalRecordCount: 1)
        return (try Wire.encoder().encode(page), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Search recommendations and query separation") struct SearchRecommendationsTests {
    private func client(_ transport: SearchTransport, viewer: String = "viewer", cache: LibraryResponseCache? = nil) throws -> JellyfinClient {
        let server = try ServerAddress("https://library.example/base")
        return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
            session: .init(server: server, viewer: .init(id: viewer, name: "Viewer"), token: "test-token", deviceID: "fixture"),
            transport: transport, responseCache: cache)
    }
    @Test func mixesMoviesAndShowsWithRealPosterMetadata() {
        let picks = SearchRecommendations.select(from: [searchItem("m1"), searchItem("m2"), searchItem("s1", type: "Series"), searchItem("s2", type: "Series")])
        #expect(picks.map(\.id) == ["m1", "s1", "m2", "s2"])
        #expect(picks.allSatisfy { $0.imageTags?["Primary"] == "poster-" + $0.id })
    }
    @Test func prioritizesUnwatchedAndPostersThenRatingsWithinEachFormat() {
        let picks = SearchRecommendations.select(from: [searchItem("watched", played: true, rating: 10),
            searchItem("no-poster", rating: 10, art: false), searchItem("lower", rating: 6), searchItem("higher", rating: 9)])
        #expect(picks.map(\.id) == ["higher", "lower", "no-poster", "watched"])
    }
    @Test func boundsAndDeduplicatesWithoutChannelsEpisodesOrInventedCards() {
        let items = (0..<40).map { searchItem(String($0)) }
        let picks = SearchRecommendations.select(from: items + [items[0], searchItem("channel", type: "TvChannel"), searchItem("episode", type: "Episode"), searchItem("")])
        #expect(picks.count == 24)
        #expect(Set(picks.map(\.id)).count == 24)
        #expect(SearchRecommendations.select(from: [], limit: 24).isEmpty)
        #expect(SearchRecommendations.select(from: items, limit: -1).isEmpty)
    }
    @Test func warmHomePagesAndSnapshotsNeedNoAdditionalNetworkReads() async throws {
        let server = try ServerAddress("https://library.example/base")
        let transport = SearchTransport(), cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let client = try client(transport, cache: cache)
        _ = try await client.items(type: "Movie"); _ = try await client.items(type: "Series")
        #expect(try await client.searchRecommendations().map(\.id) == ["Movie", "Series"])
        #expect(try await client.readingCache().searchRecommendations().count == 2)
        #expect(await transport.requests.count == 2)
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url?.path == "/base/Items" && $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.contains("test-token") == true })
        #expect(requests.allSatisfy { $0.url?.query?.contains("userId=viewer") == true && $0.url?.query?.contains("limit=30") == true })
    }
    @Test func typedSearchUsesItsOwnQueryAndCannotReuseRecommendationPage() async throws {
        let server = try ServerAddress("https://library.example/base")
        let transport = SearchTransport(), cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let client = try client(transport, cache: cache)
        _ = try await client.searchRecommendations()
        let result = try await client.items(search: "A & B / C")
        #expect(result.items.map(\.id) == ["actual-match"])
        let request = try #require(await transport.requests.last)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "searchTerm", value: "A & B / C")))
        #expect(query.contains(.init(name: "includeItemTypes", value: "Movie,Series")))
        #expect(query.contains(.init(name: "sortBy", value: "SortName")))
        #expect(try await client.searchRecommendations().map(\.id) == ["Movie", "Series"])
        #expect(await transport.requests.count == 3)
    }
    @Test func mismatchedAccountCannotReadAnotherViewersRecommendations() async throws {
        let server = try ServerAddress("https://library.example/base")
        let transport = SearchTransport(), cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        _ = try await client(transport, cache: cache).searchRecommendations()
        await #expect(throws: LibraryCacheMiss.self) {
            try await client(transport, viewer: "other-viewer", cache: cache).readingCache().searchRecommendations()
        }
        #expect(await transport.requests.count == 2)
    }
    @Test func networkFailureDoesNotBecomeSuccessfulEmptyRecommendations() async throws {
        let transport = SearchTransport(); await transport.setStatus(503)
        await #expect(throws: ClientError.unavailable(503)) { try await client(transport).searchRecommendations() }
    }
}

extension SearchRecommendationsTests {
    @Test func catalogueOptionsReachTheServerAndKeepDefaultCacheSeparate() async throws {
        let server = try ServerAddress("https://library.example/base")
        let transport = SearchTransport(), cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let client = try client(transport, cache: cache)
        _ = try await client.items(type: "Movie")
        _ = try await client.items(type: "Movie", start: 30, favorites: true,
            options: .init(sort: .title, genre: "Science Fiction & Fantasy", unwatched: true))
        let request = try #require(await transport.requests.last)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "sortBy", value: "SortName")))
        #expect(query.contains(.init(name: "sortOrder", value: "Ascending")))
        #expect(query.contains(.init(name: "startIndex", value: "30")))
        #expect(query.contains(.init(name: "genres", value: "Science Fiction & Fantasy")))
        #expect(query.contains(.init(name: "filters", value: "IsFavorite,IsUnplayed")))
        #expect(query.contains(.init(name: "userId", value: "viewer")))
        _ = try await client.readingCache().items(type: "Movie")
        #expect(await transport.requests.count == 2)
    }
    @Test func typedResultTypeAndOffsetArePartOfTheQuery() async throws {
        let transport = SearchTransport()
        _ = try await client(transport).items(type: "Series", search: "Northern", start: 60)
        let request = try #require(await transport.requests.last)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "includeItemTypes", value: "Series")))
        #expect(query.contains(.init(name: "startIndex", value: "60")))
        #expect(query.contains(.init(name: "searchTerm", value: "Northern")))
    }
}
