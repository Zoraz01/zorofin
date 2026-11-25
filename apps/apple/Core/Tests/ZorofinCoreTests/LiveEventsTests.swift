import Foundation
import Testing
@testable import ZorofinCore

private let liveNow = ISO8601DateFormatter().date(from: "2026-10-12T18:00:00Z")!
struct ParityFile: Decodable {
    struct Scenario: Decodable, Sendable, CustomTestStringConvertible {
        var testDescription: String { name }
        struct Expected: Decodable, Equatable, Sendable { let id: String; let title: String; let sport: LiveSport; let competition: String }
        let name: String
        let channels: [MediaItem]
        let expected: [Expected]
    }
    let cases: [Scenario]
    static var scenarios: [Scenario] {
        let url = Bundle.module.url(forResource: "live-events-parity", withExtension: "json", subdirectory: "Fixtures")!
        return try! Wire.decoder().decode(Self.self, from: Data(contentsOf: url)).cases
    }
}
private func liveChannel(_ title: String, overview: String = "", id: String = "channel") -> MediaItem {
    var channel = MediaItem(id: id, name: "Fixture Network", type: "TvChannel")
    channel.currentProgram = LiveProgram(name: title, startDate: "2026-10-12T17:00:00Z", endDate: "2026-10-12T19:00:00Z", isLive: true)
    channel.currentProgram?.overview = overview
    return channel
}
private func fixture(sport: LiveSport = .soccer, league: String = "soccer/eng.1", start: String = "2026-10-12T17:00:00Z",
                     image: String? = "/live-tv-logos/art/game-123.jpg") -> LiveArtworkManifest.Fixture {
    .init(sport: sport, league: league, start: start,
        home: .init(id: "home", name: "Beta Team", aliases: ["beta team", "beta"]),
        away: .init(id: "away", name: "Alpha Team", aliases: ["alpha team", "alpha"]),
        image: image, logos: ["/live-tv-logos/art/alpha-123.png", "/live-tv-logos/art/beta-123.png"])
}

@Suite("Native Home live events") struct LiveEventsTests {
    @Test func featuredFinaleRanksFirstAndExpires() throws {
        var finale = liveChannel("Live: Dancing with the Stars: Finale", id: "finale")
        finale.currentProgram?.genres = ["Featured live event"]
        let nba = liveChannel("Live: NBA Basketball", id: "nba")
        let selected = LiveEvent.select([nba, finale], at: liveNow)
        #expect(selected.first?.id == "finale")
        #expect(selected.first?.sport == .event)
        let end = try #require(selected.first?.end)
        #expect(LiveEvent.select([finale], at: end).isEmpty)
        finale.currentProgram?.isRepeat = true
        #expect(LiveEvent.select([finale], at: liveNow).isEmpty)
    }
    @Test(arguments: ParityFile.scenarios) func matchesCurrentWebRules(_ scenario: ParityFile.Scenario) {
        let actual = LiveEvent.select(scenario.channels, at: liveNow).map {
            ParityFile.Scenario.Expected(id: $0.id, title: $0.title, sport: $0.sport, competition: $0.competition)
        }
        #expect(actual == scenario.expected, "Web/native parity: \(scenario.name)")
    }
    @Test func plainServerProgramImagesDecodeAndPrecedeFallbacks() throws {
        let channel = try Wire.decoder().decode(MediaItem.self, from: Data(#"{"Id":"channel","Name":"Fixture Sports","Type":"TvChannel","ImageTags":{"Primary":"channel-logo"},"CurrentProgram":{"Id":"program-one","Name":"Live: EFL Championship","StartDate":"2026-10-12T17:00:00Z","EndDate":"2026-10-12T19:00:00Z","IsLive":true,"ImageTags":{"Thumb":"thumb-v1","Primary":"poster-v1"},"BackdropImageTags":["backdrop-v1"]}}"#.utf8))
        let event = try #require(LiveTVSnapshot(channels: [channel], fetchedAt: liveNow).events(at: liveNow).first)
        #expect(event.sport == .soccer)
        #expect(event.artwork == nil)
        #expect(event.artworkSources == [
            .program(.init(itemID: "program-one", kind: "Thumb", tag: "thumb-v1")),
            .program(.init(itemID: "program-one", kind: "Backdrop", tag: "backdrop-v1")),
            .program(.init(itemID: "program-one", kind: "Primary", tag: "poster-v1"))])
    }
    @Test func inheritedChannelLogosAndMissingProgramIdentityStayFallbacks() throws {
        var channel = liveChannel("Live: NFL Football")
        channel.imageTags = ["Primary": "channel-logo"]
        channel.currentProgram?.imageTags = ["Primary": "channel-logo", "Thumb": " "]
        channel.currentProgram?.id = "program-one"
        #expect(try #require(LiveEvent.select([channel], at: liveNow).first).artworkSources.isEmpty)
        channel.currentProgram?.imageTags = ["Primary": "real-image"]
        for id in [nil, "", channel.id] as [String?] {
            channel.currentProgram?.id = id
            #expect(try #require(LiveEvent.select([channel], at: liveNow).first).artworkSources.isEmpty)
        }
    }
    @Test func programThenPhotoThenCrestsAndProgrammeChangesInvalidateIdentity() throws {
        var channel = liveChannel("Live: NFL Football")
        channel.currentProgram?.id = "program-one"
        channel.currentProgram?.imageTags = ["Primary": "first-tag"]
        var event = try #require(LiveEvent.select([channel], at: liveNow).first)
        event.artwork = .init(image: "/live-tv-logos/art/event.jpg", logos: ["/live-tv-logos/art/a.png", "/live-tv-logos/art/b.png"], teams: ["Alpha", "Beta"], sport: .football)
        #expect(event.artworkSources == [.program(.init(itemID: "program-one", kind: "Primary", tag: "first-tag")),
            .catalogue("/live-tv-logos/art/event.jpg"),
            .crests(["/live-tv-logos/art/a.png", "/live-tv-logos/art/b.png"])])
        channel.currentProgram?.imageTags = ["Primary": "second-tag"]
        let changed = try #require(LiveEvent.select([channel], at: liveNow).first)
        #expect(changed.artworkSources == [.program(.init(itemID: "program-one", kind: "Primary", tag: "second-tag"))])
    }
    @Test func championshipPhotosMatchBothNamedAndLeagueLabelledGuide() throws {
        let f = fixture(league: "soccer/eng.2")
        let manifest = LiveArtworkManifest(version: 2, events: [f])
        for title in ["Live: Alpha Team vs Beta Team", "Live: English League Championship — Alpha Team vs Beta Team"] {
            let channel = liveChannel(title, overview: "Alpha Team hosts Beta Team.")
            let event = try #require(LiveTVSnapshot(channels: [channel], fetchedAt: liveNow).events(at: liveNow, artwork: manifest).first)
            #expect(event.sport == .soccer)
            #expect(event.artwork?.image == "/live-tv-logos/art/game-123.jpg")
        }
        for title in ["Live: Premier League Soccer — Alpha Team vs Beta Team", "Live: Women's EFL Championship — Alpha Team vs Beta Team"] {
            let event = try #require(LiveEvent.select([liveChannel(title, overview: "Alpha Team hosts Beta Team.")], at: liveNow).first)
            #expect(manifest.artwork(for: event) == nil)
        }
    }
    @Test func expiredOrStaleGuideIsHiddenAndProgressIsBounded() throws {
        let channel = liveChannel("Live: NFL Football")
        let snapshot = LiveTVSnapshot(channels: [channel], fetchedAt: liveNow)
        let event = try #require(snapshot.events(at: liveNow).first)
        #expect(event.progress(at: liveNow) == 0.5)
        #expect(event.progress(at: liveNow.addingTimeInterval(-7200)) == 0)
        #expect(event.progress(at: liveNow.addingTimeInterval(7200)) == 1)
        #expect(snapshot.events(at: liveNow.addingTimeInterval(119)).count == 1)
        #expect(snapshot.events(at: liveNow.addingTimeInterval(120)).isEmpty)
        #expect(snapshot.events(at: liveNow.addingTimeInterval(-1)).isEmpty)
        #expect(!event.isCurrent(at: event.end))
        #expect(LiveEvent.select([channel], at: event.end).isEmpty)
    }
    @Test func emptyAndDuplicateChannelIDsAreNotShown() {
        let channel = liveChannel("Live: NFL Football")
        #expect(LiveEvent.select([channel, channel], at: liveNow).count == 1)
        #expect(LiveEvent.select([liveChannel("Live: NFL Football", id: "")], at: liveNow).isEmpty)
    }
    @Test func verifiedDatedArtworkAndCrestsRespectTeamOrder() throws {
        let event = try #require(LiveEvent.select([liveChannel("Live: Premier League Soccer — Beta Team vs Alpha Team", overview: "Alpha Team visits Beta Team.")], at: liveNow).first)
        let manifest = LiveArtworkManifest(version: 2, events: [fixture()])
        let art = try #require(manifest.artwork(for: event))
        #expect(art.image == "/live-tv-logos/art/game-123.jpg")
        #expect(art.teams == ["Beta Team", "Alpha Team"])
        #expect(art.logos == ["/live-tv-logos/art/beta-123.png", "/live-tv-logos/art/alpha-123.png"])
    }
    @Test func unsupportedAndAmbiguousFixturesCannotBorrowArtwork() throws {
        for title in ["Live: Women's Premier League Soccer", "Live: NCAA Soccer", "Live: Youth Soccer"] {
            let event = try #require(LiveEvent.select([liveChannel(title + " — Alpha Team vs Beta Team", overview: "Alpha Team hosts Beta Team.")], at: liveNow).first)
            #expect(LiveArtworkManifest(version: 2, events: [fixture()]).artwork(for: event) == nil)
        }
        let event = try #require(LiveEvent.select([liveChannel("Live: Alpha Team vs Beta Team")], at: liveNow).first)
        #expect(LiveArtworkManifest(version: 2, events: [fixture(), fixture(sport: .basketball, league: "basketball/nba")]).artwork(for: event) == nil)
        #expect(LiveArtworkManifest(version: 2, events: [fixture(start: "2026-10-13T17:00:00Z")]).artwork(for: event) == nil)
        #expect(LiveArtworkManifest(version: 1, events: [fixture()]).artwork(for: event) == nil)
    }
    @Test func bothTeamsMustComeFromProgramEvidenceNeverChannelBranding() throws {
        let title = "Live: Premier League Soccer"
        var channel = liveChannel(title); channel.name = "Alpha Team vs Beta Team Sports"
        let unverified = try #require(LiveEvent.select([channel], at: liveNow).first)
        let manifest = LiveArtworkManifest(version: 2, events: [fixture()])
        #expect(manifest.artwork(for: unverified) == nil)
        channel.currentProgram?.overview = "Alpha Team hosts Beta Team."
        let snapshot = LiveTVSnapshot(channels: [channel], fetchedAt: liveNow)
        let verified = try #require(snapshot.events(at: liveNow, artwork: manifest).first)
        #expect(verified.title == "Alpha Team vs Beta Team")
        #expect(verified.competition == "Premier League Soccer")
    }
    @Test func uniquelyDatedTeamPairCanEstablishSport() throws {
        let snapshot = LiveTVSnapshot(channels: [liveChannel("Live: Alpha Team vs Beta Team")], fetchedAt: liveNow)
        let event = try #require(snapshot.events(at: liveNow, artwork: .init(version: 2, events: [fixture()])).first)
        #expect(event.sport == .soccer)
    }
    @Test(arguments: ["https://evil.example/image.jpg", "//evil.example/image.jpg", "/live-tv-logos/art/../secret.jpg", "/live-tv-logos/art/a.svg", "/live-tv-logos/art/a.jpg?token=x", "/live-tv-logos/art/%2e.jpg", "/live-tv-logos/art/a.jpg\n"])
    func rejectsUnsafeArtwork(_ path: String) throws {
        #expect(!LiveEventArtwork.isSafePath(path))
        let event = try #require(LiveEvent.select([liveChannel("Live: Alpha Team vs Beta Team")], at: liveNow).first)
        let art = LiveArtworkManifest(version: 2, events: [fixture(image: path)]).artwork(for: event)
        #expect(art?.image == nil)
        #expect(art?.logos.count == 2)
    }
}

private actor LiveTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let pages: [(Int, Data)]
    let endless: Bool
    init(_ pages: [(Int, String)], endless: Bool = false) { self.pages = pages.map { ($0.0, Data($0.1.utf8)) }; self.endless = endless }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let result: (Int, Data)
        if endless {
            let page = ItemPage(items: [liveChannel("Live: NFL Football", id: "channel-\(requests.count)")], totalRecordCount: 100_000)
            result = (200, try Wire.encoder().encode(page))
        } else { result = pages[min(requests.count - 1, pages.count - 1)] }
        return (result.1, HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil)!)
    }
}
private func liveClient(_ transport: LiveTransport, viewer: String = "viewer") throws -> JellyfinClient {
    let server = try ServerAddress("https://fixture.example/jellyfin")
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
        session: .init(server: server, viewer: .init(id: viewer, name: "Fixture"), token: "fixture-private-token", deviceID: "fixture"),
        transport: transport, responseCache: .init(server: server, viewerID: viewer, root: nil))
}
@Suite("Live row API and cache") struct LiveEventsClientTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_PUBLIC_MANIFEST"] != nil))
    func currentPublishedManifestDecodesWhenProvided() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ZOROFIN_PUBLIC_MANIFEST"])
        let manifest = try JSONDecoder().decode(LiveArtworkManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(manifest.version == 2)
        #expect(!manifest.events.isEmpty)
        print("Validated published live-artwork schema: \(manifest.events.count) fixtures")
    }
    @Test func viewerScopedPagingAndWarmCache() async throws {
        let transport = LiveTransport([(200, #"{"Items":[{"Id":"one","Name":"One","Type":"TvChannel"}],"TotalRecordCount":2}"#),
                                       (200, #"{"Items":[{"Id":"two","Name":"Two","Type":"TvChannel"}],"TotalRecordCount":2}"#)])
        let client = try liveClient(transport)
        let first = try await client.liveTVSnapshot()
        #expect(first.channels.map(\.id) == ["one", "two"])
        let second = try await client.liveTVSnapshot()
        let cached = await client.cachedLiveTVSnapshot()
        #expect(first.fetchedAt == second.fetchedAt && first.fetchedAt == cached?.fetchedAt)
        let requests = await transport.requests
        #expect(requests.count == 2)
        for request in requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(.init(name: "enableImages", value: "true")))
            #expect(query.contains(.init(name: "imageTypeLimit", value: "1")))
            #expect(query.contains(.init(name: "enableImageTypes", value: "Primary,Thumb,Backdrop")))
        }
        for (index, request) in requests.enumerated() {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.queryItems!
            #expect(request.url?.path == "/jellyfin/LiveTv/Channels")
            #expect(query.contains(.init(name: "userId", value: "viewer")))
            #expect(query.contains(.init(name: "startIndex", value: String(index))))
            #expect(query.contains(.init(name: "limit", value: "200")))
            #expect(query.contains(.init(name: "addCurrentProgram", value: "true")))
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-private-token") == true)
        }
    }
    @Test func repeatedAndUnboundedPagesStop() async throws {
        let repeatTransport = LiveTransport([(200, #"{"Items":[{"Id":"one","Name":"One"}],"TotalRecordCount":1000}"#)])
        _ = try await liveClient(repeatTransport).liveTVSnapshot()
        #expect(await repeatTransport.requests.count == 2)
        let endless = LiveTransport([], endless: true)
        let feed = try await liveClient(endless).liveTVSnapshot()
        #expect(feed.channels.count == 20)
        #expect(await endless.requests.count == 20)
    }
    @Test func authErrorsAreNotCachedAndAccountSwitchCannotReuseFeed() async throws {
        let denied = LiveTransport([(403, "{}")])
        let client = try liveClient(denied)
        await #expect(throws: ClientError.forbidden) { try await client.liveTVSnapshot() }
        #expect(await client.cachedLiveTVSnapshot() == nil)
        let transport = LiveTransport([(200, #"{"Items":[],"TotalRecordCount":0}"#)])
        _ = try await liveClient(transport, viewer: "one").liveTVSnapshot()
        let other = try liveClient(transport, viewer: "two")
        #expect(await other.cachedLiveTVSnapshot() == nil)
        _ = try await other.liveTVSnapshot()
        #expect(await transport.requests.count == 2)
    }
    @Test func optionalArtworkStaysOnTheChosenServerCredentialFreeAndCached() async throws {
        let data = try JSONEncoder().encode(LiveArtworkManifest(version: 2, events: [fixture()]))
        let transport = LiveTransport([(200, String(decoding: data, as: UTF8.self))])
        let client = try liveClient(transport)
        _ = try await client.liveArtworkManifest(); _ = try await client.liveArtworkManifest()
        _ = try await client.liveArtworkImage(path: "/live-tv-logos/art/game.jpg")
        _ = try await client.liveArtworkImage(path: "/live-tv-logos/art/game.jpg")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].timeoutInterval == 4)
        #expect(requests[0].url?.path == "/jellyfin/live-tv-logos/art/events.json")
        #expect(requests[1].url?.path == "/jellyfin/live-tv-logos/art/game.jpg")
        for request in requests {
            #expect(request.url?.host == "fixture.example")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Jellyfin-Token") == nil)
        }
    }
    @Test func standardProgramImageUsesSelectedServerAuthAndTagCache() async throws {
        let transport = LiveTransport([(200, "fixture-image-bytes")])
        let client = try liveClient(transport)
        _ = try await client.image(itemID: "program-one", kind: "Thumb", tag: "version-one", width: 720)
        _ = try await client.image(itemID: "program-one", kind: "Thumb", tag: "version-one", width: 720)
        _ = try await client.image(itemID: "program-one", kind: "Thumb", tag: "version-two", width: 720)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.url?.path == "/jellyfin/Items/program-one/Images/Thumb" && $0.url?.host == "fixture.example" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.contains("fixture-private-token") == true })
        #expect(requests.allSatisfy { !$0.url!.absoluteString.contains("fixture-private-token") })
    }
    @Test func optionalArtworkRequiresBoundSessionAndRejectsExternalPaths() async throws {
        let transport = LiveTransport([])
        let client = try liveClient(transport)
        let anonymous = JellyfinClient(server: client.server, identity: client.identity, transport: transport)
        let misplaced = JellyfinClient(server: try ServerAddress("https://elsewhere.example"), identity: client.identity,
            session: client.session, transport: transport)
        await #expect(throws: ClientError.missingSession) { try await anonymous.liveArtworkManifest() }
        await #expect(throws: ClientError.missingSession) { try await anonymous.liveArtworkImage(path: "/live-tv-logos/art/game.jpg") }
        await #expect(throws: ClientError.unsafeURL) { try await misplaced.liveArtworkManifest() }
        await #expect(throws: ClientError.unsafeURL) { try await misplaced.liveArtworkImage(path: "/live-tv-logos/art/game.jpg") }
        for path in ["https://elsewhere.example/game.jpg", "/live-tv-logos/art/../game.jpg"] {
            await #expect(throws: ClientError.unsafeURL) { try await client.liveArtworkImage(path: path) }
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func guideImagesMustBeWidePictures() {
        #expect(LiveEventArtwork.isWidePicture(width: 1280, height: 720))
        #expect(LiveEventArtwork.isWidePicture(width: 1920, height: 1000))
        #expect(!LiveEventArtwork.isWidePicture(width: 400, height: 560)) // headshot
        #expect(!LiveEventArtwork.isWidePicture(width: 512, height: 512)) // channel logo
        #expect(!LiveEventArtwork.isWidePicture(width: 1200, height: 300)) // wordmark
        #expect(!LiveEventArtwork.isWidePicture(width: 0, height: 0))
    }
}
