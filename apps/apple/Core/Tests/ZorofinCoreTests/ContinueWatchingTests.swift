import Foundation
import Testing
@testable import ZorofinCore

private func activityEpisode(_ id: String, series: String? = "show", position: Int64 = 0, played: Bool = false) -> MediaItem {
    var item = MediaItem(id: id, name: "Episode " + id, type: "Episode",
        userData: .init(playbackPositionTicks: position, played: played))
    item.seriesId = series
    return item
}

private actor ContinueWatchingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var completed = false
    let resumeStatus: Int
    let nextStatus: Int
    let cancelNext: Bool
    init(resumeStatus: Int = 200, nextStatus: Int = 200, cancelNext: Bool = false) {
        self.resumeStatus = resumeStatus; self.nextStatus = nextStatus; self.cancelNext = cancelNext
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        var status = 204, data = Data()
        if path.hasSuffix("/Stopped") { completed = true }
        else if path.hasSuffix("/Resume") {
            status = resumeStatus
            let items = completed ? [] : [activityEpisode("first", position: 120_000_000)]
            data = try Wire.encoder().encode(ItemPage(items: items, totalRecordCount: items.count))
        } else if path.hasSuffix("/NextUp") {
            if cancelNext { throw CancellationError() }
            status = nextStatus
            let items = [activityEpisode(completed ? "second" : "first")]
            data = try Wire.encoder().encode(ItemPage(items: items, totalRecordCount: items.count))
        }
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Continue Watching episode handoff") struct ContinueWatchingTests {
    private let server = try! ServerAddress("https://activity.example/base")
    private func client(_ transport: ContinueWatchingTransport, cache: LibraryResponseCache? = nil, viewer: String = "viewer") -> JellyfinClient {
        JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"),
            session: .init(server: server, viewer: .init(id: viewer, name: "Fixture"), token: "fixture-token", deviceID: "fixture"),
            transport: transport, responseCache: cache)
    }
    @Test func nextEpisodeAppearsWithNoPartiallyWatchedTitles() {
        let next = activityEpisode("second")
        #expect(ContinueWatchingFeed(resume: [], nextUp: [next]).items == [next])
    }
    @Test func resumeWinsOverDuplicateEpisodeOrAnotherEpisodeOfTheSameShow() {
        let unfinished = activityEpisode("first", position: 120_000_000)
        let movie = MediaItem(id: "movie", name: "Movie", userData: .init(playbackPositionTicks: 100))
        let feed = ContinueWatchingFeed(resume: [unfinished, movie], nextUp: [activityEpisode("first"),
            activityEpisode("second"), activityEpisode("other", series: "other-show")])
        #expect(feed.items.map(\.id) == ["first", "movie", "other"])
        #expect(feed.items[0].resumeTicks == 120_000_000)
    }
    @Test func missingSeriesMetadataDoesNotCollapseUnrelatedEpisodes() {
        let feed = ContinueWatchingFeed(resume: [], nextUp: [activityEpisode("one", series: nil),
            activityEpisode("two", series: ""), activityEpisode("three", series: " ")])
        #expect(feed.items.map(\.id) == ["one", "two", "three"])
    }
    @Test func selectionIsBoundedAndDoesNotInventOrRepeatCompletedSuggestions() {
        let invalid = [activityEpisode("", series: nil), activityEpisode("played", played: true),
            MediaItem(id: "series", name: "Show", type: "Series")]
        #expect(ContinueWatchingFeed(resume: [], nextUp: invalid).items.isEmpty)
        #expect(ContinueWatchingFeed(resume: [], nextUp: []).items.isEmpty)
        let episodes = (0..<50).map { activityEpisode(String($0), series: "show-\($0)") }
        #expect(ContinueWatchingFeed(resume: [], nextUp: episodes).items.count == 40)
        #expect(ContinueWatchingFeed(resume: [], nextUp: episodes, limit: -1).items.isEmpty)
    }
    @Test func acknowledgedStopRefreshesWarmActivityCachesBeforeTheNextRead() async throws {
        let transport = ContinueWatchingTransport()
        let cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let client = client(transport, cache: cache)
        #expect(try await client.continueWatching().items.map(\.id) == ["first"])
        #expect(try await client.readingCache().continueWatching().items.map(\.id) == ["first"])
        #expect(await transport.requests.count == 2)
        let info = try Wire.decoder().decode(PlaybackInfo.self, from: Data(#"{"PlaySessionId":"play","MediaSources":[{"Id":"source","SupportsDirectPlay":true}]}"#.utf8))
        let plan = try PlaybackPlan.make(info: info, itemID: "first", client: client, options: .init())
        let reporter = PlaybackReporter(client: client, plan: plan)
        await reporter.start(positionTicks: 120_000_000, canSeek: true)
        await reporter.stop(positionTicks: 1_200_000_000)
        #expect(await reporter.failureCount == 0)
        #expect(try await client.continueWatching().items.map(\.id) == ["second"])
        #expect(try await client.readingCache().continueWatching().items.map(\.id) == ["second"])
        let requests = await transport.requests
        #expect(requests.filter { $0.httpMethod == "GET" }.count == 4)
        let stopIndex = try #require(requests.firstIndex { $0.url!.path.hasSuffix("/Stopped") })
        #expect(requests.suffix(2).allSatisfy { $0.httpMethod == "GET" })
        #expect(stopIndex < requests.count - 2)
        for request in requests.filter({ $0.httpMethod == "GET" }) {
            #expect(["/base/UserItems/Resume", "/base/Shows/NextUp"].contains(request.url!.path))
            #expect(request.url!.query!.contains("userId=viewer"))
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
            #expect(!request.url!.absoluteString.contains("fixture-token"))
        }
    }
    @Test(arguments: [true, false]) func oneUnavailableSourceRetainsTheOtherAndReportsPartial(resumeFails: Bool) async throws {
        let transport = ContinueWatchingTransport(resumeStatus: resumeFails ? 503 : 200, nextStatus: resumeFails ? 200 : 503)
        let result = try await client(transport).continueWatching()
        #expect(result.isPartial)
        #expect(result.items.map(\.id) == ["first"])
    }
    @Test func twoUnavailableSourcesDoNotBecomeASuccessfulEmptyShelf() async {
        let transport = ContinueWatchingTransport(resumeStatus: 503, nextStatus: 503)
        await #expect(throws: ClientError.unavailable(503)) { try await client(transport).continueWatching() }
    }
    @Test(arguments: [401, 403]) func authenticationFailureCannotBeHiddenByTheOtherSource(status: Int) async {
        let transport = ContinueWatchingTransport(nextStatus: status)
        await #expect(throws: status == 401 ? ClientError.unauthorized : .forbidden) { try await client(transport).continueWatching() }
    }
    @Test func cancellationDoesNotPublishAPartialShelf() async {
        let transport = ContinueWatchingTransport(cancelNext: true)
        await #expect(throws: CancellationError.self) { try await client(transport).continueWatching() }
    }
    @Test func cachedActivityRemainsAccountScoped() async throws {
        let transport = ContinueWatchingTransport(), cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        _ = try await client(transport, cache: cache).continueWatching()
        await #expect(throws: LibraryCacheMiss.self) {
            try await client(transport, cache: cache, viewer: "another").readingCache().continueWatching()
        }
        #expect(await transport.requests.count == 2)
    }
}
