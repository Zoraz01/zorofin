import Foundation
import Testing
@testable import ZorofinCore

private actor HomeTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let response: String
    init(_ response: String) { self.response = response }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
private func homeClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let address = try ServerAddress("https://media.example/jellyfin")
    return JellyfinClient(server: address, identity: .init(deviceID: "fixture", deviceName: "Test"),
        session: .init(server: address, viewer: .init(id: "viewer", name: "Viewer"), token: "viewer-token", deviceID: "fixture"), transport: transport)
}
@Suite("Personal Home rows") struct HomeRowsTests {
    @Test func homeCrestsAreOptionalValidatedAndAnonymous() async throws {
        let path = "Zorofin/Web/ui/live-tv-logos/art/sports-0123456789abcdef01234567-89abcdef.png"
        var raw: [String: Any] = ["id": "program", "item": ["Id": "channel", "Name": "Sports", "Type": "TvChannel"], "subtitle": "Game", "badges": ["Starting soon"]]
        func read(_ raw: [String: Any]) throws -> HomeRowCard {
            try Wire.decoder().decode(HomeRowCard.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        #expect(try read(raw).game == nil)
        raw["matchup"] = ["Wizards", "Celtics"]
        raw["crests"] = [path, path.replacingOccurrences(of: ".png", with: ".jpg")]
        #expect(try read(raw).game?.title == "Wizards vs Celtics")
        for bad in [[path], [path, "https://other.example/a.png"], [path, path + "\n"]] {
            raw["crests"] = bad
            #expect(try read(raw).game == nil)
        }
        raw["crests"] = 4
        #expect(try read(raw).game == nil)
        let transport = HomeTransport("fixture")
        let client = try homeClient(transport)
        _ = try await client.homeCrestData(path: path)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/jellyfin/" + path)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func preferenceLimits() {
        var value = HomePreferences()
        #expect(value.isValid)
        value.teams = ["NY"]
        #expect(!value.isValid)
        value.teams = ["New York Knicks"]
        #expect(value.isValid)
        value.hiddenRows = ["invented"]
        #expect(!value.isValid)
    }
    @Test func feedDecodesJellyfinItemsAndOwnSessionHeaders() async throws {
        let transport = HomeTransport(#"{"schemaVersion":1,"generatedAt":"2026-10-17T18:00:00Z","preferences":{"hiddenRows":[],"teams":[],"minutes":90,"theme":"automatic"},"rows":[{"id":"showcase","title":"4K / HDR showcase","description":"Source format","state":"ready","message":null,"cards":[{"id":"film","item":{"Id":"film","Name":"Fixture","Type":"Movie","ImageTags":{"Primary":"tag"}},"subtitle":"Source format","badges":["4K"]}]}]}"#)
        let feed = try await homeClient(transport).homeFeed()
        #expect(feed.rows[0].cards[0].item.id == "film")
        #expect(feed.rows[0].cards[0].item.imageTags?["Primary"] == "tag")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/jellyfin/support/home/rows")
        #expect(request.value(forHTTPHeaderField: "X-Jellyfin-Token") == "viewer-token")
        #expect(request.url?.query == nil)
    }
    @Test func savingUsesLowercaseContractAndPut() async throws {
        let transport = HomeTransport(#"{"hiddenRows":[],"teams":["Boston Celtics"],"minutes":60,"theme":"comfort"}"#)
        var prefs = HomePreferences(); prefs.teams = ["Boston Celtics"]; prefs.minutes = 60; prefs.theme = "comfort"
        #expect(try await homeClient(transport).saveHomePreferences(prefs) == prefs)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "PUT")
        let body = try JSONDecoder().decode(HomePreferences.self, from: #require(request.httpBody))
        #expect(body == prefs)
        #expect(!String(data: request.httpBody!, encoding: .utf8)!.contains("viewer-token"))
    }
    @Test func invalidInputDoesNotSend() async throws {
        let transport = HomeTransport("{}")
        var prefs = HomePreferences(); prefs.teams = [String(repeating: "x", count: 65)]
        await #expect(throws: ClientError.invalidResponse) { try await homeClient(transport).saveHomePreferences(prefs) }
        #expect(await transport.requests.isEmpty)
    }
    @Test func expiredGuideProgramsDisappearAtTheirEndTime() throws {
        let data = Data(#"{"id":"p","item":{"Id":"channel","Name":"Sport","Type":"TvChannel"},"subtitle":"Match","badges":["Live"],"startsAt":"2026-10-17T18:00:00.000Z","endsAt":"2026-10-17T20:00:00Z"}"#.utf8)
        let card = try Wire.decoder().decode(HomeRowCard.self, from: data)
        #expect(!card.isExpired(at: try #require(HomeRowCard.date("2026-10-17T19:59:59Z"))))
        #expect(card.isExpired(at: try #require(HomeRowCard.date("2026-10-17T20:00:00Z"))))
    }
}

private actor HomeSequenceTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, Data)]
    init(_ responses: [(Int, Data)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw ClientError.invalidResponse }
        let (status, data) = responses.removeFirst()
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Automatic native Home") struct AutomaticHomeTests {
    private func feed(_ prefs: HomePreferences) throws -> Data {
        try JSONEncoder().encode(HomeFeed(generatedAt: "2026-10-17T18:00:00Z", preferences: prefs, rows: []))
    }
    private func setup(_ responses: [(Int, Data)]) throws -> (JellyfinClient, HomeSequenceTransport) {
        let server = try ServerAddress("https://home.example/jellyfin")
        let transport = HomeSequenceTransport(responses)
        let cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let client = JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "viewer-token", deviceID: "fixture"),
            transport: transport, responseCache: cache)
        return (client, transport)
    }
    @Test func automaticAccountsKeepWarmCacheWithoutPreferenceWrites() async throws {
        var prefs = HomePreferences(); prefs.teams = ["Boston Celtics"]
        let (client, transport) = try setup([(200, feed(prefs))])
        #expect(try await client.automaticHomeFeed().preferences == prefs)
        #expect(try await client.automaticHomeFeed().preferences == prefs)
        #expect(await transport.requests.count == 1)
    }
    @Test func restoresAllRowsAndPreservesFreshTeamsInsteadOfCachedTeams() async throws {
        var old = HomePreferences(); old.hiddenRows = ["sports", "popular"]; old.minutes = 30; old.theme = "eid"; old.teams = ["Old Team"]
        var current = old; current.teams = ["Boston Celtics", "New York Knicks"]
        let automatic = current.automatic
        let (client, transport) = try setup([(200, feed(old)), (200, JSONEncoder().encode(current)),
            (200, JSONEncoder().encode(automatic)), (200, feed(automatic))])
        _ = try await client.homeFeed() // Persisted or warm legacy feed must not overwrite newer teams.
        #expect(try await client.automaticHomeFeed().preferences == automatic)
        #expect(try await client.automaticHomeFeed().preferences == automatic)
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "GET", "PUT", "GET"])
        #expect(requests.map { $0.url!.path } == ["/jellyfin/support/home/rows", "/jellyfin/support/home/preferences", "/jellyfin/support/home/preferences", "/jellyfin/support/home/rows"])
        let body = try JSONDecoder().decode(HomePreferences.self, from: #require(requests[2].httpBody))
        #expect(body.teams == current.teams)
        #expect(body.hiddenRows.isEmpty && body.minutes == 90 && body.theme == "automatic")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Jellyfin-Token") == "viewer-token" })
    }
    @Test func alreadyMigratedAccountRefreshesStaleFeedWithoutWritingAgain() async throws {
        var old = HomePreferences(); old.hiddenRows = ["showcase"]
        var current = HomePreferences(); current.teams = ["Boston Celtics"]
        let (client, transport) = try setup([(200, feed(old)), (200, JSONEncoder().encode(current)), (200, feed(current))])
        #expect(try await client.automaticHomeFeed().preferences == current)
        #expect(await transport.requests.map(\.httpMethod) == ["GET", "GET", "GET"])
    }
    @Test func failedPreferenceSaveDoesNotPretendMigrationSucceeded() async throws {
        var old = HomePreferences(); old.hiddenRows = ["showcase"]
        let (client, transport) = try setup([(200, feed(old)), (200, JSONEncoder().encode(old)), (503, Data())])
        await #expect(throws: ClientError.unavailable(503)) { try await client.automaticHomeFeed() }
        #expect(await transport.requests.count == 3)
    }
    @Test func snapshotReadsNeverStartMigrationOrNetworkTraffic() async throws {
        var old = HomePreferences(); old.hiddenRows = ["showcase"]
        let (client, transport) = try setup([(200, feed(old))])
        _ = try await client.homeFeed()
        #expect(try await client.readingCache().homeFeed().preferences == old)
        await #expect(throws: LibraryCacheMiss.missing) { try await client.readingCache().automaticHomeFeed() }
        #expect(await transport.requests.count == 1)
    }
    @Test func serverIgnoringDefaultsFailsWithoutUnboundedRetry() async throws {
        var old = HomePreferences(); old.minutes = 180
        let (client, transport) = try setup([(200, feed(old)), (200, JSONEncoder().encode(old)),
            (200, JSONEncoder().encode(old)), (200, feed(old))])
        await #expect(throws: ClientError.invalidResponse) { try await client.automaticHomeFeed() }
        #expect(await transport.requests.count == 4)
    }
}

@Suite("Home card metadata enrichment") struct HomeMetadataTests {
    private func feed(_ items: [MediaItem]) -> HomeFeed {
        HomeFeed(generatedAt: "2026-10-17T18:00:00Z", preferences: .init(), rows: [
            HomeRow(id: "curated", title: "Spooky season", description: "Seasonal titles",
                cards: items.map { HomeRowCard(id: $0.id, item: $0, subtitle: "Spooky season") })])
    }
    private func client(_ transport: HomeSequenceTransport, cache: LibraryResponseCache? = nil) throws -> JellyfinClient {
        let server = try ServerAddress("https://media.example/jellyfin")
        return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture", deviceID: "fixture"),
            transport: transport, responseCache: cache)
    }
    @Test func restoresBadgesFromOneViewerScopedBatchAndKeepsRowIdentity() async throws {
        let page = Data(#"{"Items":[{"Id":"film","Name":"New name","Type":"Movie","CommunityRating":8.2,"MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"Height":1600,"VideoRangeType":"HDR10"}]}]}"#.utf8)
        let transport = HomeSequenceTransport([(200,page)])
        let source = feed([MediaItem(id: "film", name: "Film")])
        let result = try await client(transport).enrichHomeFeed(source)
        let card = try #require(result.rows.first?.cards.first)
        #expect(card.item.communityRating == 8.2)
        #expect(card.item.quality().thumbnailBadges == ["4K","HDR10"])
        #expect(card.id == "film" && card.item.name == "Film" && card.subtitle == "Spooky season")
        let request = try #require(await transport.requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(request.url?.path == "/jellyfin/Items")
        #expect(query.contains(.init(name: "userId", value: "viewer")))
        #expect(query.contains(.init(name: "ids", value: "film")))
        #expect(query.contains(.init(name: "fields", value: "MediaStreams")))
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture") == true)
        #expect(request.value(forHTTPHeaderField: "X-Jellyfin-Token") == nil)
    }
    @Test func batchesDeduplicateTitlesAndRemainBounded() async throws {
        let transport = HomeSequenceTransport(Array(repeating: (200, Data(#"{"Items":[]}"#.utf8)), count: 3))
        let items = (0..<160).map { MediaItem(id: "film-\($0)", name: "Film") }
        _ = try await client(transport).enrichHomeFeed(feed(items + [items[0]]))
        let requests = await transport.requests
        #expect(requests.count == 3)
        let groups = requests.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "ids" }!.value!.split(separator: ",")
        }
        #expect(groups.map(\.count) == [50,50,40])
        #expect(Set(groups.flatMap { $0 }).count == 140)
    }
    @Test func noMetadataMeansNoInventedRatingOrFormatAndNoLostCard() async throws {
        for response in [(200, Data(#"{"Items":[]}"#.utf8)), (503, Data())] {
            let transport = HomeSequenceTransport([response])
            let result = try await client(transport).enrichHomeFeed(feed([MediaItem(id: "unknown", name: "Unknown")]))
            let item = try #require(result.rows.first?.cards.first?.item)
            #expect(item.id == "unknown" && item.communityRating == nil && item.quality().thumbnailBadges.isEmpty)
        }
    }
    @Test func completeCardsAndLiveChannelsDoNotTriggerExtraReads() async throws {
        let item = try Wire.decoder().decode(MediaItem.self, from: Data(#"{"Id":"film","Name":"Film","Type":"Movie","CommunityRating":7,"MediaStreams":[{"Index":0,"Type":"Video","Width":1920,"Height":1080}]}"#.utf8))
        let transport = HomeSequenceTransport([])
        _ = try await client(transport).enrichHomeFeed(feed([item, MediaItem(id: "live", name: "Live", type: "TvChannel")]))
        #expect(await transport.requests.isEmpty)
    }
    @Test func cachedEnrichmentSurvivesRelaunchWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerAddress("https://media.example/jellyfin")
        let transport = HomeSequenceTransport([(200, Data(#"{"Items":[{"Id":"film","Name":"Film","Type":"Movie","CommunityRating":8,"MediaStreams":[{"Index":0,"Type":"Video","Width":1920,"Height":1080}],"MediaSources":[{"TranscodingUrl":"secret-url","OpenToken":"secret-token"}]}]}"#.utf8))])
        let source = feed([MediaItem(id: "film", name: "Film")])
        let first = try client(transport, cache: .init(server: server, viewerID: "viewer", root: root))
        _ = try await first.enrichHomeFeed(source)
        _ = try await first.enrichHomeFeed(source)
        let restored = try client(transport, cache: .init(server: server, viewerID: "viewer", root: root))
        let result = try await restored.readingCache().enrichHomeFeed(source)
        #expect(result.rows[0].cards[0].item.communityRating == 8)
        #expect(result.rows[0].cards[0].item.quality().thumbnailBadges == ["1080p"])
        #expect(await transport.requests.count == 1)
        let differentViewer = LibraryResponseCache(server: server, viewerID: "another", root: root)
        let otherClient = try client(transport, cache: differentViewer).readingCache()
        #expect(try await otherClient.enrichHomeFeed(source).rows[0].cards[0].item.communityRating == nil)
        #expect(await transport.requests.count == 1)
    }
    @Test func rejectsForeignItemsAndPropagatesAuthorizationFailure() async throws {
        let foreign = HomeSequenceTransport([(200, Data(#"{"Items":[{"Id":"other","Name":"Other","CommunityRating":10}]}"#.utf8))])
        let source = feed([MediaItem(id: "film", name: "Film")])
        #expect(try await client(foreign).enrichHomeFeed(source).rows[0].cards[0].item.communityRating == nil)
        let denied = HomeSequenceTransport([(403,Data())])
        await #expect(throws: ClientError.forbidden) { try await client(denied).enrichHomeFeed(source) }
    }
}
