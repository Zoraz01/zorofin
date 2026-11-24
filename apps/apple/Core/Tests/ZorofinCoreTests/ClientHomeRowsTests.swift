import Foundation
import Testing
@testable import ZorofinCore

private let rowsNow = ISO8601DateFormatter().date(from: "2026-10-27T18:00:00Z")!
private let eastern = TimeZone(identifier: "America/New_York")!

private func entry(_ id: String, type: String = "Movie", minutes: Int64? = nil, played: Bool = false, created: String? = nil,
                   width: Int? = nil, range: String? = nil, videoRange: String? = nil, series: String? = nil,
                   genres: [String]? = nil, tags: [String]? = nil, overview: String? = nil, virtual: Bool = false) -> ClientHomeRows.Entry {
    var item = MediaItem(id: id, name: id, type: type, overview: overview, userData: .init(played: played))
    item.runTimeTicks = minutes.map { $0 * 600_000_000 }
    item.seriesId = series
    item.genres = genres
    if width != nil || range != nil || videoRange != nil {
        var stream = try! Wire.decoder().decode(MediaStream.self, from: Data(#"{"Index":0,"Type":"Video"}"#.utf8))
        stream.width = width; stream.videoRangeType = range; stream.videoRange = videoRange
        item.mediaStreams = [stream]
    }
    return .init(item: item, facts: .init(id: id, dateCreated: created, tags: tags, locationType: virtual ? "Virtual" : "FileSystem"))
}
private func day(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T16:00:00Z")! }

@Suite("Client-side Home rows") struct ClientHomeRowsTests {
    @Test func jellyfinSevenDigitFractionsParse() {
        #expect(ClientHomeRows.date("2026-10-20T12:34:56.1234567Z") == ISO8601DateFormatter().date(from: "2026-10-20T12:34:56Z"))
        #expect(ClientHomeRows.date("2026-10-20T12:34:56") == ISO8601DateFormatter().date(from: "2026-10-20T12:34:56Z"))
        #expect(ClientHomeRows.date("2026-10-20T12:34:56.5+02:00") != nil)
        #expect(ClientHomeRows.date("") == nil && ClientHomeRows.date(nil) == nil)
    }
    @Test func ninetyMinuteRowSkipsPlayedVirtualAndLongFilms() {
        let cards = ClientHomeRows.shortMovies([
            entry("short", minutes: 85), entry("exact", minutes: 90), entry("long", minutes: 91),
            entry("seen", minutes: 80, played: true), entry("missing", minutes: 80, virtual: true), entry("unknown")])
        #expect(cards.map(\.id) == ["short", "exact"])
        #expect(cards.first?.subtitle == "85 min")
    }
    @Test func showcaseUsesVideoMetadataOnly() {
        let cards = ClientHomeRows.showcase([
            entry("uhd", width: 3840), entry("dv", width: 3840, range: "DOVIWithHDR10"), entry("hdr", videoRange: "HDR"),
            entry("plus", range: "HDR10Plus"), entry("invalid", range: "DOVIInvalid"), entry("hd", width: 1920, range: "SDR")])
        #expect(cards.map(\.id) == ["uhd", "dv", "hdr", "plus"])
        #expect(cards[1].badges == ["4K", "Dolby Vision"])
        #expect(cards[1].qualityBadges == ["4K", "Dolby Vision"])
        #expect(cards[3].badges == ["HDR10+"])
    }
    @Test func newEpisodesFollowFavoritesWithinFourteenDays() {
        let cards = ClientHomeRows.newEpisodes([
            entry("old", type: "Episode", created: "2026-10-01T00:00:00Z", series: "fav"),
            entry("new", type: "Episode", created: "2026-10-25T00:00:00.0000000Z", series: "fav"),
            entry("newer", type: "Episode", created: "2026-10-26T00:00:00Z", series: "fav"),
            entry("other", type: "Episode", created: "2026-10-26T00:00:00Z", series: "other"),
            entry("watched", type: "Episode", played: true, created: "2026-10-26T00:00:00Z", series: "fav"),
            entry("future", type: "Episode", created: "2026-11-26T00:00:00Z", series: "fav")], favorites: ["fav"], at: rowsNow)
        #expect(cards.map(\.id) == ["newer", "new"])
        #expect(cards.first?.badges == ["New episode"])
    }
    @Test func sportsMatchFullTeamNamesAndSkipStudioShows() {
        let channel = MediaItem(id: "ch", name: "Sports One", type: "TvChannel")
        func program(_ id: String, _ name: String, start: String, end: String, sports: Bool = true, channel: String = "ch") -> ClientHomeRows.GuideProgram {
            .init(id: id, channelId: channel, name: name, overview: nil, startDate: start, endDate: end, isSports: sports, genres: nil)
        }
        let programs = [
            program("later", "Boston Celtics at New York Knicks", start: "2026-10-27T18:45:00Z", end: "2026-10-27T21:00:00Z"),
            program("tonight", "New York Knicks at Miami Heat", start: "2026-10-27T23:00:00Z", end: "2026-10-28T01:00:00Z"),
            program("generic", "TNT Sports 1", start: "2026-10-27T17:00:00Z", end: "2026-10-27T19:00:00Z"),
            program("now", "NBA: Knicks vs. Heat", start: "2026-10-27T17:00:00Z", end: "2026-10-27T19:00:00Z"),
            program("studio", "NBA Studio Live", start: "2026-10-27T17:00:00Z", end: "2026-10-27T19:00:00Z"),
            program("ended", "New York Knicks Classic", start: "2026-10-27T10:00:00Z", end: "2026-10-27T12:00:00Z"),
            program("far", "New York Knicks at Boston Celtics", start: "2026-10-28T09:00:00Z", end: "2026-10-28T11:00:00Z"),
            program("orphan", "New York Knicks", start: "2026-10-27T17:00:00Z", end: "2026-10-27T19:00:00Z", channel: "gone"),
            program("drama", "New York Knicks", start: "2026-10-27T17:00:00Z", end: "2026-10-27T19:00:00Z", sports: false)]
        // No teams, no row: generic sports channels never fill it.
        #expect(ClientHomeRows.sports(programs, channels: [channel], teams: [], at: rowsNow).isEmpty)
        let mine = ClientHomeRows.sports(programs, channels: [channel], teams: ["New York Knicks", "Miami Heat"], at: rowsNow)
        #expect(mine.map(\.id) == ["later"], "on now or within the hour only")
        #expect(mine.map(\.badges) == [["Starting soon"]])
        let heat = ClientHomeRows.sports(programs, channels: [channel], teams: ["Heat"], at: rowsNow)
        #expect(heat.map(\.id) == ["now"] && heat[0].badges == ["On now"])
        #expect(heat[0].item.id == "ch" && heat[0].subtitle == "NBA: Knicks vs. Heat")
        #expect(!ClientHomeRows.teamMatches("Sunnyvale FC", teams: ["Sunny"]))
        #expect(ClientHomeRows.teamMatches("Real Madrid vs. Barça", teams: ["barça"]))
    }
    @Test func seasonalPlanFollowsTheLocalCalendar() {
        #expect(SeasonalThemes.plan(at: rowsNow, timeZone: eastern).first == "halloween")
        #expect(SeasonalThemes.plan(at: day("2026-07-01"), timeZone: eastern).first == "fourth-july")
        #expect(SeasonalThemes.plan(at: day("2026-02-12"), timeZone: eastern).prefix(2) == ["valentines", "black-history"])
        #expect(SeasonalThemes.plan(at: day("2026-02-28"), timeZone: eastern).contains("black-history"))
        #expect(SeasonalThemes.plan(at: day("2026-03-01"), timeZone: eastern).contains("black-history") == false)
        #expect(SeasonalThemes.plan(at: day("2026-05-25"), timeZone: eastern).first == "memorial-day")
        #expect(SeasonalThemes.plan(at: day("2026-11-26"), timeZone: eastern).first == "thanksgiving")
        #expect(SeasonalThemes.plan(at: day("2026-12-24"), timeZone: eastern).first == "christmas")
        // Late evening on Dec 31 in New York is already Jan 1 in UTC.
        let newYearsEve = ISO8601DateFormatter().date(from: "2027-01-01T03:00:00Z")!
        #expect(SeasonalThemes.plan(at: newYearsEve, timeZone: eastern).first == "new-year")
        let april = SeasonalThemes.plan(at: day("2026-04-28"), timeZone: eastern)
        #expect(april.first == "spring" && Set(april.suffix(4)) == ["comfort", "movie-night", "rainy-day", "weekend-adventures"])
        #expect(Set(april).count == april.count)
    }
    @Test func metadataNeverInfersHolidaysFromGenreAlone() {
        let war = entry("war", genres: ["Action", "War"])
        #expect(!SeasonalThemes.metadataMatches(war.item, tags: [], theme: "fourth-july"))
        let parade = entry("parade", genres: ["Comedy"], overview: "A Fourth of July parade goes wrong.")
        #expect(SeasonalThemes.metadataMatches(parade.item, tags: [], theme: "fourth-july"))
        #expect(!SeasonalThemes.metadataMatches(entry("pride").item, tags: [], theme: "pride"))
        #expect(SeasonalThemes.metadataMatches(entry("pride").item, tags: ["Pride"], theme: "pride"))
        let campus = entry("campus", genres: ["Horror"], overview: "A college campus")
        #expect(!SeasonalThemes.metadataMatches(campus.item, tags: [], theme: "back-to-school"))
        #expect(SeasonalThemes.metadataMatches(entry("mystery", genres: ["Mystery"]).item, tags: [], theme: "rainy-day"))
    }
    @Test func seasonalRankIsStableUnwatchedFirstAndDeduplicated() {
        let items = (0..<30).map { entry("m\($0)", played: $0 % 3 == 0).item }
        let first = SeasonalThemes.rank(items + items, theme: "halloween", viewerID: "v", at: rowsNow, timeZone: eastern)
        let again = SeasonalThemes.rank(items.reversed(), theme: "halloween", viewerID: "v", at: rowsNow, timeZone: eastern)
        #expect(first.map(\.id) == again.map(\.id))
        #expect(first.count == 20 && Set(first.map(\.id)).count == 20)
        #expect(first.allSatisfy { $0.userData?.played != true })
    }
    @Test func mergeKeepsServerOnlyRowsAndFallsBackOnFailure() {
        let card = HomeRowCard(id: "x", item: MediaItem(id: "x", name: "X"), subtitle: "")
        let server = HomeFeed(generatedAt: "2026-10-27T18:00:00Z", preferences: .init(), rows: [
            HomeRow(id: "requests-ready", title: "Your requests are ready", description: "", cards: [card]),
            HomeRow(id: "popular", title: "Popular", description: "", cards: [card]),
            HomeRow(id: "showcase", title: "Server showcase", description: "", cards: [card]),
            HomeRow(id: "short-movies", title: "Server short", description: "", cards: [card])])
        let client = [
            HomeRow(id: "short-movies", title: "Watch in 90 minutes", description: "", state: "empty", cards: []),
            HomeRow(id: "showcase", title: "4K / HDR showcase", description: "", state: "unavailable", cards: [])]
        let feed = ClientHomeRows.feed(client: client, server: server, teams: ["Boston Celtics"], at: rowsNow)
        #expect(feed.rows.map(\.id) == ["requests-ready", "short-movies", "showcase", "popular"])
        #expect(feed.rows[1].title == "Watch in 90 minutes")
        #expect(feed.rows[2].title == "Server showcase")
        #expect(feed.preferences.teams == ["Boston Celtics"])
        let plain = ClientHomeRows.feed(client: client, server: nil, teams: [], at: rowsNow)
        #expect(plain.rows.map(\.id) == ["short-movies", "showcase"])
    }
}

// MARK: Network contract

private actor RoutedTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let routes: @Sendable (URLRequest) -> (Int, String)
    init(_ routes: @escaping @Sendable (URLRequest) -> (Int, String)) { self.routes = routes }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = routes(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private func routedClient(_ transport: RoutedTransport) throws -> JellyfinClient {
    let address = try ServerAddress("https://media.example/jellyfin")
    return JellyfinClient(server: address, identity: .init(deviceID: "fixture", deviceName: "Test"),
        session: .init(server: address, viewer: .init(id: "viewer", name: "Viewer"), token: "viewer-token", deviceID: "fixture"),
        transport: transport)
}
private func query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@Suite("Client-side Home rows network") struct ClientHomeRowsNetworkTests {
    @Test func buildsRowsFromPlainJellyfinReadsOnly() async throws {
        let transport = RoutedTransport { request in
            let path = request.url!.path
            if path.hasSuffix("/LiveTv/Channels") { return (200, #"{"Items":[{"Id":"ch","Name":"Sports","Type":"TvChannel"}],"TotalRecordCount":1}"#) }
            if path.hasSuffix("/LiveTv/Programs") {
                return (200, #"{"Items":[{"Id":"p1","ChannelId":"ch","Name":"Live: Boston Bruins at Washington Capitals","IsSports":true,"StartDate":"2026-10-27T17:30:00.0000000Z","EndDate":"2026-10-27T20:00:00.0000000Z"}]}"#)
            }
            switch query(request, "includeItemTypes") {
            case "Movie" where query(request, "parentId") == nil:
                return (200, #"{"Items":[{"Id":"m1","Name":"Night of Fright","Type":"Movie","RunTimeTicks":51000000000,"Genres":["Horror"],"DateCreated":"2026-10-20T00:00:00.0000000Z","LocationType":"FileSystem","MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"VideoRangeType":"HDR10"}],"UserData":{"Played":false}}],"TotalRecordCount":1}"#)
            case "Series": return (200, #"{"Items":[{"Id":"s1","Name":"Show","Type":"Series"}],"TotalRecordCount":1}"#)
            case "Episode": return (200, #"{"Items":[{"Id":"e1","Name":"Pilot","Type":"Episode","SeriesId":"s1","DateCreated":"2026-10-26T00:00:00Z","UserData":{"Played":false}}],"TotalRecordCount":1}"#)
            case "BoxSet": return (200, #"{"Items":[],"TotalRecordCount":0}"#)
            default: return (404, "{}")
            }
        }
        let rows = try await routedClient(transport).clientHomeRows(teams: ["Washington Capitals"], at: rowsNow, timeZone: eastern)
        #expect(rows.map(\.id) == ["new-episodes", "short-movies", "showcase", "curated", "sports"])
        #expect(rows.allSatisfy { $0.state == "ready" })
        #expect(rows[0].cards.map(\.id) == ["e1"])
        #expect(rows[1].cards.first?.subtitle == "85 min")
        #expect(rows[2].cards.first?.badges == ["4K", "HDR10"])
        #expect(rows[3].title == "Spooky season" && rows[3].cards.map(\.id) == ["m1"])
        #expect(rows[4].cards.first?.id == "p1")
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.allSatisfy { !$0.url!.path.contains("/support/") })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Jellyfin-Token") == nil })
        #expect(requests.allSatisfy { query($0, "userId") == "viewer" })
    }
    @Test func oneFailingSourceLeavesTheOtherRows() async throws {
        let transport = RoutedTransport { request in
            if request.url!.path.contains("/LiveTv/") { return (500, "{}") }
            if query(request, "includeItemTypes") == "Series" { return (200, #"{"Items":[],"TotalRecordCount":0}"#) }
            return (200, #"{"Items":[],"TotalRecordCount":0}"#)
        }
        let rows = try await routedClient(transport).clientHomeRows(teams: ["Boston Celtics"], at: rowsNow, timeZone: eastern)
        #expect(rows.first { $0.id == "sports" }?.state == "unavailable")
        #expect(rows.filter { $0.id != "sports" }.allSatisfy { $0.state == "empty" })
        // No favorites means no episode scan at all.
        #expect(await transport.requests.allSatisfy { query($0, "includeItemTypes") != "Episode" })
    }
    @Test func signedOutSessionsSurfaceInsteadOfEmptyRows() async throws {
        let transport = RoutedTransport { _ in (401, "{}") }
        await #expect(throws: ClientError.unauthorized) {
            _ = try await routedClient(transport).clientHomeRows(teams: [], at: rowsNow, timeZone: eastern)
        }
    }
    @Test func teamsRoundTripThroughJellyfinDisplayPreferences() async throws {
        let transport = RoutedTransport { request in
            if request.httpMethod == "POST" { return (204, "") }
            return (200, #"{"Id":"zorofin-home","Client":"zorofin","SortBy":"SortName","CustomPrefs":{"other":"keep"}}"#)
        }
        let client = try routedClient(transport)
        #expect(try await client.savedHomeTeams() == nil)
        try await client.saveHomeTeams(["Boston Celtics", "New York Knicks"])
        let post = try #require(await transport.requests.last)
        #expect(post.httpMethod == "POST")
        #expect(post.url?.path == "/jellyfin/DisplayPreferences/zorofin-home")
        #expect(query(post, "client") == "zorofin" && query(post, "userId") == "viewer")
        let httpBody = try #require(post.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        let custom = try #require(body["CustomPrefs"] as? [String: String])
        #expect(custom["other"] == "keep")
        let saved = try #require(custom["zorofinTeams"])
        #expect(try JSONDecoder().decode([String].self, from: Data(saved.utf8)) == ["Boston Celtics", "New York Knicks"])
        #expect(body["SortBy"] as? String == "SortName")
        await #expect(throws: ClientError.invalidResponse) { try await client.saveHomeTeams(["NY"]) }
    }
    @Test func legacyServerTeamsAreAdoptedOnce() async throws {
        let transport = RoutedTransport { request in
            if request.url!.path.hasSuffix("/support/home/preferences") {
                return (200, #"{"hiddenRows":[],"teams":["Boston Celtics"],"minutes":90,"theme":"automatic"}"#)
            }
            if request.httpMethod == "POST" { return (204, "") }
            return (200, #"{"Id":"zorofin-home","CustomPrefs":{}}"#)
        }
        let client = try routedClient(transport)
        #expect(try await client.homeTeams(serverFallback: true) == ["Boston Celtics"])
        #expect(await transport.requests.contains { $0.httpMethod == "POST" })
        let plain = RoutedTransport { _ in (200, #"{"Id":"zorofin-home","CustomPrefs":{"zorofinTeams":"[\"Chicago Bulls\"]"}}"#) }
        #expect(try await routedClient(plain).homeTeams(serverFallback: true) == ["Chicago Bulls"])
        #expect(await plain.requests.count == 1)
    }
}

@Suite("Seasonal calendar parity") struct SeasonalParityTests {
    struct Fixture: Decodable { struct Case: Decodable { let at: String; let plan: [String] }; let timeZone: String; let cases: [Case] }
    @Test func matchesTheServerCalendarForTwoYears() throws {
        let url = try #require(Bundle.module.url(forResource: "seasonal-plan-parity", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let zone = try #require(TimeZone(identifier: fixture.timeZone))
        #expect(fixture.cases.count > 700)
        for item in fixture.cases {
            let date = try #require(ISO8601DateFormatter.fractional.date(from: item.at))
            #expect(SeasonalThemes.plan(at: date, timeZone: zone) == item.plan, "Server/native parity on \(item.at)")
        }
    }
}
private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }
}
