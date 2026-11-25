import Foundation
import Testing
@testable import ZorofinCore

private func season(_ number: Int) -> MediaItem {
    var item = MediaItem(id: "season-\(number)", name: "Season \(number)", type: "Season")
    item.seriesId = "show"; item.indexNumber = number; return item
}
private func episode(_ number: Int, season: Int = 1) -> MediaItem {
    var item = MediaItem(id: "s\(season)e\(number)", name: "Episode \(number)", type: "Episode")
    item.seriesId = "show"; item.seasonId = "season-\(season)"; item.parentIndexNumber = season; item.indexNumber = number; return item
}
private actor EpisodeFixture: EpisodeLibrary {
    let seasonItems: [MediaItem]
    let pages: [String: ItemPage]
    let recent: MediaItem?
    var requests: [String] = []
    var failNext = false
    var delayedSeason: String?
    var pending: CheckedContinuation<ItemPage, Never>?
    var started: CheckedContinuation<Void, Never>?
    init(seasons: [MediaItem] = [season(0),season(1),season(2)], pages: [String: ItemPage] = [:], recent: MediaItem? = nil) {
        seasonItems = seasons; self.pages = pages; self.recent = recent
    }
    func seasons(seriesID: String) async throws -> ItemPage { ItemPage(items: seasonItems) }
    func recentlyPlayedEpisode(seriesID: String) async throws -> MediaItem? { recent }
    func episodes(seriesID: String, seasonID: String, start: Int) async throws -> ItemPage {
        requests.append("\(seriesID)/\(seasonID)/\(start)")
        if failNext { failNext = false; throw ClientError.network }
        if delayedSeason == seasonID {
            return await withCheckedContinuation { continuation in
                pending = continuation; started?.resume(); started = nil
            }
        }
        return pages["\(seasonID)/\(start)"] ?? ItemPage(items: [], totalRecordCount: 0)
    }
    func failOnce() { failNext = true }
    func delay(_ season: String) { delayedSeason = season }
    func waitForDelay() async { if pending == nil { await withCheckedContinuation { started = $0 } } }
    func release(_ page: ItemPage) { delayedSeason = nil; pending?.resume(returning: page); pending = nil }
}

@Suite("Native seasons and episode navigation") @MainActor struct EpisodeBrowserTests {
    @Test func episodeOpensItsOwnSeasonAndSortsSpecials() async {
        let library = EpisodeFixture(seasons: [season(2),season(0),season(1)], pages: ["season-2/0":.init(items:[episode(3,season:2)],totalRecordCount:1)])
        let state = EpisodeBrowserState(library: library)
        await state.load(episode(3,season:2))
        #expect(state.seasons.map(\.indexNumber) == [0,1,2])
        #expect(state.selectedSeasonID == "season-2" && state.currentEpisodeID == "s2e3")
        #expect(state.episodes.map(\.id) == ["s2e3"])
        #expect(state.seasons.first?.seasonTitle == "Specials")
    }
    @Test func seasonPageAndMissingSeasonIDResolveCorrectly() async {
        let library = EpisodeFixture()
        let state = EpisodeBrowserState(library: library)
        await state.load(season(2))
        #expect(state.selectedSeasonID == "season-2")
        var item = episode(2,season:0); item.seasonId = nil
        await state.load(item)
        #expect(state.selectedSeasonID == "season-0")
        #expect(item.episodeNumberLabel == "Special 2")
    }
    @Test func resolvedEpisodeMetadataCorrectsAnInitiallyUnknownSeason() async {
        let state = EpisodeBrowserState(library:EpisodeFixture())
        var incomplete = episode(4,season:2)
        incomplete.seasonId = nil; incomplete.parentIndexNumber = nil
        await state.load(incomplete)
        #expect(state.selectedSeasonID == "season-1")
        await state.load(episode(4,season:2))
        #expect(state.selectedSeasonID == "season-2" && state.currentEpisodeID == "s2e4")
    }
    @Test func seriesUsesRecentSeasonAndOtherwiseFirstRegularSeason() async {
        let item = MediaItem(id:"show",name:"Show",type:"Series")
        let recent = EpisodeBrowserState(library:EpisodeFixture(recent:episode(4,season:2)))
        await recent.load(item)
        #expect(recent.selectedSeasonID == "season-2")
        let first = EpisodeBrowserState(library:EpisodeFixture())
        await first.load(item)
        #expect(first.selectedSeasonID == "season-1")
        let specialsOnly = EpisodeBrowserState(library:EpisodeFixture(seasons:[season(0)]))
        await specialsOnly.load(item)
        #expect(specialsOnly.selectedSeasonID == "season-0")
    }
    @Test func seriesFindsRecentSeasonWhenItsIDIsMissingOrStale() async {
        let show = MediaItem(id: "show", name: "Show", type: "Series")
        for number in [0, 2] {
            var recent = episode(4, season: number); recent.seasonId = nil
            let state = EpisodeBrowserState(library: EpisodeFixture(recent: recent))
            await state.load(show)
            #expect(state.selectedSeasonID == "season-\(number)")
        }
        var recent = episode(4, season: 2); recent.seasonId = "old-season-id"
        let state = EpisodeBrowserState(library: EpisodeFixture(recent: recent))
        await state.load(show)
        #expect(state.selectedSeasonID == "season-2")
    }
    @Test func choosingLoadedSeasonDoesNotDiscardItsCachedEpisodes() async {
        let library = EpisodeFixture(pages: ["season-1/0": .init(items: [episode(1)], totalRecordCount: 1)])
        let state = EpisodeBrowserState(library: library)
        await state.load(MediaItem(id: "show", name: "Show", type: "Series"))
        await state.selectSeason("season-1")
        #expect(state.episodes.map(\.id) == ["s1e1"])
        #expect(await library.requests == ["show/season-1/0"])
    }
    @Test func findsCurrentEpisodeBeyondTheFirstPage() async {
        let library = EpisodeFixture(pages:["season-1/0":.init(items:(1...30).map { episode($0) },totalRecordCount:35),
                                           "season-1/30":.init(items:(31...35).map { episode($0) },totalRecordCount:35)])
        let state = EpisodeBrowserState(library:library)
        await state.load(episode(34))
        #expect(state.episodes.count == 35 && !state.hasMore)
        #expect(await library.requests == ["show/season-1/0","show/season-1/30"])
    }
    @Test func seriesTargetsResolvedNextEpisodeInALaterSeasonAndPage() async {
        let next = episode(35, season: 2)
        let library = EpisodeFixture(pages: [
            "season-2/0": .init(items: (1...30).map { episode($0, season: 2) }, totalRecordCount: 35),
            "season-2/30": .init(items: (31...35).map { episode($0, season: 2) }, totalRecordCount: 35)],
            recent: episode(9))
        let state = EpisodeBrowserState(library: library)
        await state.load(MediaItem(id: "show", name: "Show", type: "Series"), preferredEpisode: next)
        #expect(state.selectedSeasonID == "season-2" && state.currentEpisodeID == next.id)
        #expect(state.episodes.count == 35)
        #expect(await library.requests == ["show/season-2/0", "show/season-2/30"])
    }
    @Test func seriesWithoutHistorySkipsEmptySeasons() async {
        let state = EpisodeBrowserState(library: EpisodeFixture(pages: [
            "season-2/0": .init(items: [episode(1, season: 2)], totalRecordCount: 1)]))
        await state.load(MediaItem(id: "show", name: "Show", type: "Series"))
        #expect(state.selectedSeasonID == "season-2" && state.episodes.count == 1)
    }
    @Test func interactionStopsLateAutomaticTargetPaging() async {
        let library = EpisodeFixture()
        await library.delay("season-2")
        let state = EpisodeBrowserState(library: library)
        let loading = Task { await state.load(episode(35, season: 2)) }
        await library.waitForDelay(); state.cancelTargeting()
        await library.release(.init(items: (1...30).map { episode($0, season: 2) }, totalRecordCount: 35))
        await loading.value
        #expect(state.targetingCancelled && state.episodes.count == 30 && state.hasMore)
        #expect(await library.requests == ["show/season-2/0"])
    }
    @Test func pagingDeduplicatesWithoutRepeatingTheOffset() async {
        let library = EpisodeFixture(pages:["season-1/0":.init(items:(1...30).map { episode($0) },totalRecordCount:32),
                                           "season-1/30":.init(items:[episode(30),episode(31)],totalRecordCount:32)])
        let state = EpisodeBrowserState(library:library)
        await state.load(MediaItem(id:"show",name:"Show",type:"Series"))
        #expect(state.hasMore)
        await state.loadMore()
        #expect(state.episodes.count == 31 && !state.hasMore)
        await state.loadMore()
        #expect(await library.requests.count == 2)
    }
    @Test func lateSeasonReplyCannotReplaceNewSelection() async {
        let library = EpisodeFixture(pages:["season-1/0":.init(items:[episode(1)],totalRecordCount:1)])
        let state = EpisodeBrowserState(library:library)
        await state.load(MediaItem(id:"show",name:"Show",type:"Series"))
        await library.delay("season-2")
        let old = Task { await state.selectSeason("season-2") }
        await library.waitForDelay()
        await state.selectSeason("season-1")
        await library.release(.init(items:[episode(1,season:2)],totalRecordCount:1))
        await old.value
        #expect(state.selectedSeasonID == "season-1" && state.episodes.first?.id == "s1e1")
        #expect(!state.loadingEpisodes && state.error == nil)
    }
    @Test func cancelledBrowserRejectsLateResponse() async {
        let library = EpisodeFixture()
        let state = EpisodeBrowserState(library:library)
        await state.load(MediaItem(id:"show",name:"Show",type:"Series"))
        await library.delay("season-2")
        let old = Task { await state.selectSeason("season-2") }
        await library.waitForDelay(); state.cancel()
        await library.release(.init(items:[episode(1,season:2)],totalRecordCount:1))
        await old.value
        #expect(state.episodes.isEmpty && !state.loadingEpisodes)
    }
    @Test func returningAfterCancellationResumesTheChosenSeason() async throws {
        // Keep the initial season populated so automatic empty-season skipping
        // cannot preload the season whose request this test intends to delay.
        let library = EpisodeFixture(pages:[
            "season-1/0":.init(items:[episode(1)],totalRecordCount:1),
            "season-2/0":.init(items:[episode(1,season:2)],totalRecordCount:1)])
        let state = EpisodeBrowserState(library:library)
        let show = MediaItem(id:"show",name:"Show",type:"Series")
        await state.load(show)
        try #require(state.selectedSeasonID == "season-1")
        #expect(await library.requests == ["show/season-1/0"])
        await library.delay("season-2")
        let old = Task { await state.selectSeason("season-2") }
        await library.waitForDelay(); state.cancel()
        await library.release(.init(items:[episode(1,season:2)],totalRecordCount:1))
        await old.value
        await state.load(show)
        #expect(state.selectedSeasonID == "season-2" && state.episodes.first?.id == "s2e1")
        #expect(!state.loadingEpisodes && state.error == nil)
        #expect(await library.requests == ["show/season-1/0", "show/season-2/0", "show/season-2/0"])
    }
    @Test func failedPageCanRetryWithoutDroppingTheSeason() async {
        let library = EpisodeFixture(pages:["season-1/0":.init(items:[episode(1)],totalRecordCount:1)])
        await library.failOnce()
        let state = EpisodeBrowserState(library:library)
        await state.load(MediaItem(id:"show",name:"Show",type:"Series"))
        #expect(state.error != nil && state.selectedSeasonID == "season-1")
        await state.loadMore()
        #expect(state.error == nil && state.episodes.count == 1)
    }
    @Test func wrongSeasonResponseFailsClosedAndMoviesNeverFetch() async {
        let library = EpisodeFixture(pages:["season-1/0":.init(items:[episode(1,season:2)],totalRecordCount:1)])
        let state = EpisodeBrowserState(library:library)
        await state.load(MediaItem(id:"film",name:"Movie"))
        #expect(await library.requests.isEmpty)
        await state.load(MediaItem(id:"show",name:"Show",type:"Series"))
        #expect(state.episodes.isEmpty && state.error != nil)
    }
    @Test func watchedAndResumeProgressAreBounded() {
        var item = episode(1); item.runTimeTicks = 100; item.userData = .init(playbackPositionTicks:50)
        #expect(item.watchProgress == 0.5)
        item.userData?.playedPercentage = 500
        #expect(item.watchProgress == 1)
        item.userData?.playedPercentage = -10
        #expect(item.watchProgress == 0)
        item.userData?.played = true
        #expect(item.watchProgress == 1)
    }
}

private actor EpisodeHTTPFixture: HTTPTransport {
    var requests: [URLRequest] = []
    let body: Data
    init(_ body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url:request.url!, statusCode:200, httpVersion:nil, headerFields:nil)!)
    }
}
@Suite("Episode browsing request boundaries") struct EpisodeRequestTests {
    @Test func requestsUseSelectedServerViewerSeasonAndPagination() async throws {
        let server = try ServerAddress("https://media.example/base")
        let transport = EpisodeHTTPFixture(try Wire.encoder().encode(ItemPage(items:[])))
        let client = JellyfinClient(server:server,identity:.init(deviceID:"fixture",deviceName:"Fixture"),
            session:.init(server:server,viewer:.init(id:"viewer",name:"Viewer"),token:"fixture",deviceID:"fixture"),transport:transport)
        _ = try await client.episodes(seriesID:"show",seasonID:"season-2",start:30)
        _ = try await client.seasons(seriesID:"show")
        _ = try await client.recentlyPlayedEpisode(seriesID:"show")
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "media.example" })
        let query = URLComponents(url:requests[0].url!,resolvingAgainstBaseURL:false)!.queryItems!
        #expect(query.contains(.init(name:"seasonId",value:"season-2")))
        #expect(query.contains(.init(name:"startIndex",value:"30")))
        #expect(query.contains(.init(name:"userId",value:"viewer")))
        #expect(query.contains(.init(name:"isMissing",value:"false")))
        #expect(requests[0].url?.path == "/base/Shows/show/Episodes")
        let misplaced = JellyfinClient(server:try ServerAddress("https://other.example"),identity:client.identity,session:client.session,transport:transport)
        await #expect(throws:ClientError.unsafeURL) { try await misplaced.recentlyPlayedEpisode(seriesID:"show") }
        #expect(await transport.requests.count == 3)
    }
}

extension EpisodeBrowserTests {
    @Test func explicitCurrentActionReturnsAcrossSeasonsAndPages() async {
        let library = EpisodeFixture(pages: [
            "season-1/0": .init(items: (1...30).map { episode($0) }, totalRecordCount: 35),
            "season-1/30": .init(items: (31...35).map { episode($0) }, totalRecordCount: 35),
            "season-2/0": .init(items: [episode(1, season: 2)], totalRecordCount: 1)])
        let state = EpisodeBrowserState(library: library)
        await state.load(episode(32))
        state.cancelTargeting()
        await state.selectSeason("season-2")
        #expect(state.selectedSeasonID == "season-2" && state.currentEpisodeID == "s1e32")
        await state.returnToCurrentEpisode()
        #expect(state.selectedSeasonID == "season-1" && !state.targetingCancelled)
        #expect(state.episodes.contains { $0.id == "s1e32" })
    }
    @Test func currentActionWithoutHistoryDoesNotGuessAnEpisode() async {
        let state = EpisodeBrowserState(library: EpisodeFixture())
        await state.load(MediaItem(id: "show", name: "Show", type: "Series"))
        state.cancelTargeting()
        await state.selectSeason("season-2")
        await state.returnToCurrentEpisode()
        #expect(state.currentEpisodeID == nil && state.selectedSeasonID == "season-2")
    }
}
