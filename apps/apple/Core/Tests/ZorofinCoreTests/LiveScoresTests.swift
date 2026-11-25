import Foundation
import Testing
@testable import ZorofinCore

// The same cases as the web row (support-agent/tests/live-events.test.js) and the
// TV app (apps/tv/test/live_scores_test.dart), so every client agrees.
private let gameStart = ISO8601DateFormatter().date(from: "2026-11-09T00:30:00Z")!

private func scoreEvent(_ channel: String, matchup: [String]? = nil, at: Date = gameStart,
                        leagueContext: String = "NBA Basketball") -> LiveEvent {
    LiveEvent(channel: MediaItem(id: channel, name: channel, type: "TvChannel"),
              title: matchup?.joined(separator: " vs ") ?? channel, competition: "NBA", sport: .basketball,
              start: at, end: at.addingTimeInterval(3 * 3600), priority: 0, matchup: matchup,
              context: leagueContext, leagueContext: leagueContext, evidence: "")
}

private func side(_ name: String, _ short: String, _ code: String, favorite: Bool = false, color: String = "") -> String {
    #"{"name":"\#(name)","short":"\#(short)","abbreviation":"\#(code)","favorite":\#(favorite),"color":"\#(color)"}"#
}

private func nets(state: String = "in", score: String? = #"{"home":"88","away":"64"}"#, detail: String = "Q3 4:12",
                  channels: String = "[]") -> String {
    #"{"id":"nba:1","state":"\#(state)","start":"2026-11-09T00:30:00.000Z","detail":"\#(detail)","#
        + (score.map { #""score":\#($0),"# } ?? "")
        + #""home":\#(side("Dallas Mavericks", "Mavericks", "DAL")),"away":\#(side("Brooklyn Nets", "Nets", "BKN", color: "#000000")),"channels":\#(channels)}"#
}

private func games(_ json: String...) throws -> [LiveGame] {
    let body = #"{"updatedAt":"2026-11-09T01:00:00Z","games":["# + json.joined(separator: ",") + "]}"
    return try #require(try LiveScoresFeed.decode(Data(body.utf8))).games
}

@Suite("Live now scores") struct LiveScoresTests {
    @Test func aGameBothGuideTeamsNameGetsItsScore() throws {
        let event = scoreEvent("NBA — Nets At Mavericks", matchup: ["Brooklyn Nets", "Dallas Mavericks"])
        let score = try #require(LiveScores.score(for: event, in: try games(nets())))
        #expect(score.away == "BKN" && score.awayScore == "64" && score.home == "DAL" && score.homeScore == "88")
        #expect(score.awayName == "Nets" && score.homeName == "Mavericks")
        #expect(!score.isFinal && score.homeLeads)
        #expect(score.awayColor == 0xd9dedb, "black would vanish")
        #expect(score.homeColor == nil)
        #expect(score.status == "Live · Q3 4:12")
        #expect(score.text == "BKN 64 – 88 DAL · Q3 4:12")
    }

    @Test func scoresNeedTheSameStartedGameAndPlainNumbers() throws {
        let event = scoreEvent("NBA — Nets At Mavericks", matchup: ["Brooklyn Nets", "Dallas Mavericks"])
        #expect(LiveScores.score(for: scoreEvent("Sports", matchup: ["Nets", "Mavericks"]), in: try games(nets())) != nil)
        #expect(LiveScores.score(for: scoreEvent("Test Sports", matchup: ["Brooklyn Nets", "Miami Heat"]), in: try games(nets())) == nil)
        #expect(LiveScores.score(for: scoreEvent("NBA — Nets At Mavericks", matchup: ["Brooklyn Nets", "Dallas Mavericks"],
                                                 at: gameStart.addingTimeInterval(12 * 3600)), in: try games(nets())) == nil)
        #expect(LiveScores.score(for: event, in: try games(nets(score: nil))) == nil)
        #expect(LiveScores.score(for: event, in: try games(nets(state: "pre"))) == nil)
        #expect(LiveScores.score(for: event, in: try games(nets(score: #"{"home":"<b>","away":"1"}"#))) == nil)
        let byChannel = try #require(LiveScores.score(for: scoreEvent("ESPN"), in: try games(nets(channels: #"[{"name":"ESPN"}]"#))))
        #expect(!byChannel.isFinal)
        let done = try #require(LiveScores.score(for: event, in: try games(nets(state: "post", detail: "Final"))))
        #expect(done.isFinal && done.status == "Final")
    }

    @Test func anEventChannelNamedAfterItsGameMatches() throws {
        let feed = try games(nets())
        #expect(LiveScores.score(for: scoreEvent("NBA — Nets At Mavericks"), in: feed)?.home == "DAL")
        #expect(LiveScores.score(for: scoreEvent("NBA — Heat At Kings"), in: feed) == nil)
        #expect(LiveScores.score(for: scoreEvent("NBA 7"), in: feed) == nil)
    }

    @Test func theFeedSetsOrderCapAndFavoriteTeams() throws {
        let kings = #"{"state":"in","start":"2026-11-09T00:30:00Z","home":\#(side("Sacramento Kings", "Kings", "SAC", favorite: true)),"away":\#(side("Miami Heat", "Heat", "MIA"))}"#
        let mavs = #"{"state":"in","start":"2026-11-09T00:30:00Z","home":\#(side("Dallas Mavericks", "Mavericks", "DAL")),"away":\#(side("Brooklyn Nets", "Nets", "BKN"))}"#
        let feed = LiveScoresFeed(games: try games(kings, mavs), leagues: ["basketball/nba"])
        let events = [scoreEvent("NBA — Nets At Mavericks"), scoreEvent("NBA — Celtics At Bucks"),
                      scoreEvent("ESPN", leagueContext: "Boxing"), scoreEvent("NBA — Heat At Kings")]
        let out = LiveScores.arrange(events, feed: feed)
        #expect(out.map(\.channel.name) == ["NBA — Heat At Kings", "NBA — Nets At Mavericks", "ESPN"],
                "feed order first, game cut by the cap dropped, boxing kept")
        #expect(out[0].favoriteTeam && !out[1].favoriteTeam)
        #expect(out[0].score == nil, "spoiler-free feed has no score")
        #expect(LiveScores.arrange(events, feed: LiveScoresFeed(games: feed.games)).count == 4,
                "leagues the server does not follow stay")
        #expect(LiveScores.arrange(events, feed: nil).map(\.id) == events.map(\.id))
    }

    @Test func aFeedWithoutAFirstScheduleReadKeepsTheGuideRow() throws {
        #expect(try LiveScoresFeed.decode(Data(#"{"games":[],"updatedAt":null}"#.utf8)) == nil)
        let body = #"{"updatedAt":"2026-11-09T01:00:00Z","spoilerFree":false,"leagues":["basketball/nba"],"maxGames":20,"order":"league","games":["# + nets() + #",{"home":"bad"}]}"#
        let feed = try #require(try LiveScoresFeed.decode(Data(body.utf8)))
        #expect(feed.games.count == 1 && feed.leagues == ["basketball/nba"])
    }
}

private actor ScoresTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int, body: String
    init(_ status: Int, _ body: String) { self.status = status; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class TestClock: @unchecked Sendable {
    var now = ISO8601DateFormatter().date(from: "2026-11-09T01:00:00Z")!
}

private func scoresClient(_ transport: any HTTPTransport, token: String = "fixture-token") throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/jellyfin")
    return .init(server: server, identity: .init(deviceID: "fixture-tv", deviceName: "Apple TV"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: token, deviceID: "fixture-tv"),
        transport: transport)
}

@Suite("Live now scores cache") struct LiveScoresCacheTests {
    @Test func readsOnceAMinuteThroughThePluginRoute() async throws {
        let transport = ScoresTransport(200, #"{"updatedAt":"2026-11-09T01:00:00Z","games":["# + nets() + "]}")
        let client = try scoresClient(transport), clock = TestClock()
        let cache = LiveScoresCache(clock: { clock.now })
        #expect(await cache.load(client)?.games.count == 1)
        _ = await cache.load(client)
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/jellyfin/Zorofin/Companion/sportsEvents/live")
        #expect(request.url?.query == "window=today")
        clock.now = clock.now.addingTimeInterval(61)
        _ = await cache.load(client)
        #expect(await transport.requests.count == 2)
    }

    @Test func aMissingModuleBacksOffForTenMinutes() async throws {
        let transport = ScoresTransport(404, #"{"error":"Not found"}"#)
        let client = try scoresClient(transport), clock = TestClock()
        let cache = LiveScoresCache(clock: { clock.now })
        #expect(await cache.load(client) == nil)
        clock.now = clock.now.addingTimeInterval(300)
        #expect(await cache.load(client) == nil)
        #expect(await transport.requests.count == 1)
        clock.now = clock.now.addingTimeInterval(360)
        _ = await cache.load(client)
        #expect(await transport.requests.count == 2)
    }

    @Test func anotherAccountStartsFresh() async throws {
        let transport = ScoresTransport(403, #"{"error":"admin_only"}"#)
        let cache = LiveScoresCache()
        _ = await cache.load(try scoresClient(transport))
        _ = await cache.load(try scoresClient(transport, token: "other"))
        #expect(await transport.requests.count == 2)
    }

    @Test func scoredCardsReadLeagueClockChannelAndADarkTeamTint() {
        var event = scoreEvent("ESPN")
        #expect(event.scoreStatus == nil)
        let live = LiveScore(away: "BKN", awayScore: "79", home: "DAL", homeScore: "88", detail: "Q4 4:12",
                             isFinal: false, awayName: "Nets", homeName: "Mavericks", awayColor: nil, homeColor: 0x0053bc)
        event.score = live
        #expect(event.scoreStatus == "NBA · Q4 4:12")
        #expect(event.channelLine == "ESPN")
        event.favoriteTeam = true
        #expect(event.channelLine == "Your teams · ESPN")
        let done = LiveScore(away: "BKN", awayScore: "79", home: "DAL", homeScore: "88", detail: "",
                             isFinal: true, awayName: "", homeName: "", awayColor: nil, homeColor: nil)
        event.score = done
        #expect(event.scoreStatus == "NBA · Final")
        #expect(live.tint == 0x002555)
        #expect(done.tint == 0x1e3a5f)
    }
}



@Suite("Guide and companion Sports parity") struct SportsParityTests {
    private var now: Date { gameStart.addingTimeInterval(1800) }
    private func channel(_ id: String, name: String? = nil, title: String? = nil) -> MediaItem {
        var channel = MediaItem(id: id, name: name ?? id, type: "TvChannel")
        channel.currentProgram = LiveProgram(name: title ?? "Live: NBA Basketball — Away \(id) vs Home \(id)", startDate: "2026-11-09T00:30:00Z", endDate: "2026-11-09T03:30:00Z", isLive: true)
        // Guide matchups count only with listing evidence (LiveRules.cleanTitle), as real EPG rows carry.
        channel.currentProgram?.overview = "Away \(id) visit Home \(id)."
        return channel
    }
    private func game(_ id: String, favorite: Bool = false) -> LiveGame {
        .init(start: gameStart, state: "in", home: .init(name: "Home " + id, abbreviation: "H", favorite: favorite),
            away: .init(name: "Away " + id, abbreviation: "A"), homeScore: "8", awayScore: "6", channels: [id],
            id: "nba:" + id, league: "nba", sport: "basketball", competition: "NBA Basketball", live: true)
    }
    @Test func feedFiltersCoveredGamesAndKeepsOtherLiveEvents() async {
        let guide = LiveTVSnapshot(channels: [channel("one"), channel("two"), channel("omitted"), channel("boxing", name: "Fight Network", title: "Live: Boxing")], fetchedAt: now)
        let feed = LiveScoresFeed(games: [game("two", favorite: true), game("one")], leagues: ["basketball/nba"], maxGames: 1, spoilerFree: true)
        let events = await LiveScores.events(in: guide, feed: feed, at: now)
        #expect(events.map(\.id) == ["two", "boxing"])
        #expect(events[0].favoriteTeam && events[0].score == nil)
        #expect(await LiveScores.events(in: guide, feed: nil, at: now).count == 4)
        #expect(await LiveScores.events(in: guide, feed: .init(games: [], leagues: ["basketball/nba"]), at: now).map(\.id) == ["boxing"])
    }
    @Test func artworkCannotAddOrSelectGamesAndGuideIsRequired() async {
        let guide = LiveTVSnapshot(channels: [channel("one")], fetchedAt: now)
        let art = LiveArtworkManifest(version: 2, events: [.init(sport: .basketball, league: "basketball/nba", start: "2026-11-09T00:30:00Z", home: .init(id: "home", name: "Home one", aliases: ["home one"]), away: .init(id: "away", name: "Away one", aliases: ["away one"]), image: "/live-tv-logos/art/sample.jpg", logos: [])])
        let feed = LiveScoresFeed(games: [game("one")], leagues: ["basketball/nba"])
        let plain = await LiveScores.events(in: guide, feed: feed, at: now)
        let pictured = await LiveScores.events(in: guide, feed: feed, at: now, artwork: art)
        #expect(plain.map(\.id) == pictured.map(\.id) && plain.map(\.title) == pictured.map(\.title))
        #expect(pictured.first?.artwork != nil)
        #expect(await LiveScores.events(in: .init(channels: [], fetchedAt: now), feed: feed, at: now, artwork: art).isEmpty)
        var placeholder = channel("one"); placeholder.currentProgram?.name = "one"
        #expect(await LiveScores.events(in: .init(channels: [placeholder], fetchedAt: now), feed: feed, at: now).isEmpty)
    }
    @Test func explicitFeedChannelWinsBeforeSimulcastDeduplication() async {
        let guide = LiveTVSnapshot(channels: [channel("a-copy", title: "Live: NBA Basketball — Away one vs Home one"), channel("one")], fetchedAt: now)
        let events = await LiveScores.events(in: guide, feed: .init(games: [game("one")], leagues: ["basketball/nba"]), at: now)
        #expect(events.map(\.id) == ["one"])
    }
    @Test func decodesOperatorSettings() throws {
        let feed = try #require(try LiveScoresFeed.decode(Data(#"{"updatedAt":"2026-11-09T01:00:00Z","games":[],"maxGames":2,"spoilerFree":true,"order":"favorites"}"#.utf8)))
        #expect(feed.maxGames == 2 && feed.spoilerFree && feed.order == "favorites")
    }
}
