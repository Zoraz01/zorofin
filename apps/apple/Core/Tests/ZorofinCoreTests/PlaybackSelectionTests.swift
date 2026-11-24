import Foundation
import Testing
@testable import ZorofinCore

private actor SelectionTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, String)]
    init(_ replies: [(Int, String)] = []) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = replies.isEmpty ? (500, "") : replies.removeFirst()
        return (Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!)
    }
}

private func selectionClient(_ transport: SelectionTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture", deviceID: "fixture"), transport: transport)
}

@Suite("Playback item selection") struct PlaybackSelectionTests {
    @Test func seriesHeroResolvesEpisodeBeforePlaybackNegotiation() async throws {
        let transport = SelectionTransport([
            (200, #"{"Items":[{"Id":"episode","Name":"Episode","Type":"Episode","SeriesId":"series","UserData":{"PlaybackPositionTicks":900000000}}]}"#),
            (200, #"{"MediaSources":[{"Id":"source"}]}"#),
            (200, #"{"PlaySessionId":"play","MediaSources":[{"Id":"source","SupportsDirectPlay":true}]}"#)
        ])
        let client = try selectionClient(transport)
        let selected = try await client.playbackSelection(for: .init(id: "series", name: "Show", type: "Series"),
            options: .init(startTicks: 123, bitrate: 8_000_000, audioIndex: 7, subtitleIndex: 8))
        #expect(selected.item.id == "episode")
        #expect(selected.options.startTicks == 900000000 && selected.options.bitrate == 8_000_000)
        #expect(selected.options.audioIndex == nil && selected.options.subtitleIndex == -2)
        _ = try await client.playbackInfo(for: selected.item, options: selected.options)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/base/Shows/NextUp", "/base/Items/episode/PlaybackInfo", "/base/Items/episode/PlaybackInfo"])
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "seriesId", value: "series")))
        #expect(query.contains(.init(name: "userId", value: "viewer")))
        #expect(query.contains(.init(name: "enableResumable", value: "true")))
    }

    @Test(arguments: ["Movie", "Episode", "TvChannel"])
    func playableItemsKeepExplicitOptionsWithoutExtraDiscovery(_ type: String) async throws {
        let transport = SelectionTransport()
        let selected = try await selectionClient(transport).playbackSelection(for: .init(id: "item", name: "Item", type: type),
            options: .init(startTicks: 450000000, bitrate: 4_000_000, audioIndex: 2, subtitleIndex: -1))
        #expect(selected.item.id == "item" && selected.options.startTicks == 450000000)
        #expect(selected.options.audioIndex == 2 && selected.options.subtitleIndex == -1)
        #expect(await transport.requests.isEmpty)
    }

    @Test func fallbackSkipsEmptySeasonsAndPrefersRegularSeasonsToSpecials() async throws {
        let transport = SelectionTransport([
            (200, #"{"Items":[]}"#),
            (200, #"{"Items":[{"Id":"specials","Name":"Specials","Type":"Season","IndexNumber":0},{"Id":"two","Name":"Season 2","Type":"Season","IndexNumber":2},{"Id":"one","Name":"Season 1","Type":"Season","IndexNumber":1}]}"#),
            (200, #"{"Items":[]}"#),
            (200, #"{"Items":[{"Id":"episode","Name":"Episode","Type":"Episode","SeriesId":"series","SeasonId":"two"}]}"#)
        ])
        let selected = try await selectionClient(transport).playbackSelection(for: .init(id: "series", name: "Show", type: "Series"), options: .init())
        #expect(selected.item.id == "episode")
        let requests = await transport.requests
        let seasons = requests.filter { $0.url?.path.hasSuffix("/Episodes") == true }.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "seasonId" }!.value
        }
        #expect(seasons == ["one", "two"])
    }

    @Test func selectedSeasonDoesNotPlayAnotherSeason() async throws {
        let transport = SelectionTransport([(200, #"{"Items":[{"Id":"episode","Name":"Episode","Type":"Episode","SeriesId":"series","SeasonId":"season"}]}"#)])
        var season = MediaItem(id: "season", name: "Season", type: "Season"); season.seriesId = "series"
        let selected = try await selectionClient(transport).playbackSelection(for: season, options: .init())
        #expect(selected.item.id == "episode")
        #expect(await transport.requests.count == 1)
    }

    @Test func emptyShowHasAnActionableErrorAndNeverNegotiatesTheSeries() async throws {
        let transport = SelectionTransport([(200, #"{"Items":[]}"#), (200, #"{"Items":[]}"#)])
        await #expect(throws: PlaybackSelectionError.noEpisodes) {
            try await selectionClient(transport).playbackSelection(for: .init(id: "series", name: "Show", type: "Series"), options: .init())
        }
        #expect(await transport.requests.allSatisfy { $0.url?.path.hasSuffix("/PlaybackInfo") == false })
    }

    @Test(arguments: [#"{"Items":[{"Id":"other","Name":"Other","Type":"Episode","SeriesId":"different"}]}"#,
                      #"{"Items":[{"Id":"series","Name":"Show","Type":"Series"}]}"#])
    func mismatchedAndContainerResultsAreRejected(_ body: String) async throws {
        let transport = SelectionTransport([(200, body)])
        await #expect(throws: ClientError.invalidResponse) {
            try await selectionClient(transport).playbackSelection(for: .init(id: "series", name: "Show", type: "Series"), options: .init())
        }
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: ["Series", "Season", "BoxSet", "Folder"])
    func playbackBoundaryRejectsContainersWithoutAnHTTP400(_ type: String) async throws {
        let transport = SelectionTransport()
        await #expect(throws: PlaybackSelectionError.unsupportedItem) {
            try await selectionClient(transport).playbackInfo(for: .init(id: "container", name: "Container", type: type), options: .init())
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func permissionFailureDoesNotFallBackToADifferentEpisode() async throws {
        let transport = SelectionTransport([(403, "")])
        await #expect(throws: ClientError.forbidden) {
            try await selectionClient(transport).playbackSelection(for: .init(id: "series", name: "Show", type: "Series"), options: .init())
        }
        #expect(await transport.requests.count == 1)
    }
}
