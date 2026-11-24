import Foundation
import Testing
@testable import ZorofinCore

private actor DiscoveryTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let feed: String
    let failingPath: String?
    let status: Int
    init(feed: String = #"{"state":"not_ready","items":[]}"#, failingPath: String? = nil, status: Int = 503) {
        self.feed = feed; self.failingPath = failingPath; self.status = status
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        if status == -1 { throw CancellationError() }
        let failed = failingPath.map { path.hasSuffix($0) } == true
        let body = path.hasSuffix("/recommendations") ? feed :
            #"{"results":[{"id":4,"title":"Film","mediaType":"movie"},{"id":4,"name":"Show","mediaType":"tv"},{"id":4,"title":"Duplicate","mediaType":"movie"},{"id":9,"name":"Person","mediaType":"person"}],"totalPages":12}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: failed ? status : 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func discoveryClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"),
        session: .init(server: server, viewer: .init(id: "one", name: "Viewer"), token: "fixture-token", deviceID: "fixture"), transport: transport)
}

@Suite("Request discovery rows") struct RequestDiscoveryTests {
    @Test func rowsUseViewerScopedReadsAndOneFailureDoesNotHideOtherRows() async throws {
        let transport = DiscoveryTransport(failingPath: "/discover/tv")
        let rows = try await discoveryClient(transport).requestDiscovery(includeRecommendations: true)
        #expect(rows.map(\.section) == [.recommended, .trending, .movies, .tv, .upcoming])
        #expect(rows[0].titles.isEmpty && !rows[0].failed)
        #expect(rows[1].titles.map(\.identity) == ["movie-4", "tv-4"])
        #expect(rows[2].titles.count == 2 && !rows[2].failed)
        #expect(rows[3].failed && rows[3].titles.isEmpty)
        #expect(rows[4].titles.count == 2)
        let requests = await transport.requests
        #expect(requests.count == 5)
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "media.example" && $0.url?.path.hasPrefix("/base/") == true })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true && $0.value(forHTTPHeaderField: "X-Emby-Token") == nil })
        let recommendation = try #require(requests.first { $0.url?.path.hasSuffix("/recommendations") == true })
        #expect(recommendation.value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token")
        #expect(recommendation.url?.query == nil)
    }
    @Test func optionalFeedIsNotProbedWithoutSupportCapability() async throws {
        let transport = DiscoveryTransport()
        let rows = try await discoveryClient(transport).requestDiscovery(includeRecommendations: false)
        #expect(rows.count == 4)
        #expect(await transport.requests.allSatisfy { $0.url?.path.contains("/support/") == false })
    }
    @Test func recommendationsRequireReadyFeedAndSafeArtwork() async throws {
        let feed = #"{"state":"ready","items":[{"tmdbId":8,"title":"First","year":2026,"posterUrl":"https://image.tmdb.org/t/p/w500/one.jpg"},{"tmdbId":8,"title":"Duplicate","posterUrl":"https://image.tmdb.org/t/p/w342/one.jpg"},{"tmdbId":9,"title":"Second","year":"2025","posterUrl":"https://image.tmdb.org/t/p/original/two.png"},{"tmdbId":10,"title":"Unsafe","posterUrl":"https://outside.example/t/p/w342/a.jpg"}]}"#
        let titles = try await discoveryClient(DiscoveryTransport(feed: feed)).requestRecommendations()
        #expect(titles.map(\.identity) == ["movie-8", "movie-9"])
        #expect(titles.map(\.year) == ["2026", "2025"])
        #expect(titles.map(\.posterPath) == ["/one.jpg", "/two.png"])
        let unavailable = feed.replacingOccurrences(of: "\"ready\"", with: "\"not_ready\"")
        #expect(try await discoveryClient(DiscoveryTransport(feed: unavailable)).requestRecommendations().isEmpty)
    }
    @Test func missingRecommendationRouteIsOptional() async throws {
        let rows = try await discoveryClient(DiscoveryTransport(failingPath: "/recommendations", status: 404)).requestDiscovery(includeRecommendations: true)
        #expect(rows.first?.titles.isEmpty == true && rows.first?.failed == false)
        #expect(rows.dropFirst().allSatisfy { !$0.failed && !$0.titles.isEmpty })
    }
    @Test func cancellationDoesNotBecomeAnEmptySuccessfulFeed() async throws {
        let client = try discoveryClient(DiscoveryTransport(status: -1))
        await #expect(throws: CancellationError.self) {
            try await client.requestDiscovery(includeRecommendations: true)
        }
    }
}
