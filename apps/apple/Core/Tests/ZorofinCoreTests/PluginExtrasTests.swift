import Foundation
import Testing
@testable import ZorofinCore

// The same cases as the TV apps (apps/tv/test/plugin_extras_test.dart).
private actor ExtrasTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw ClientError.network }
        let response = responses.removeFirst()
        return (Data(response.1.utf8), HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil,
                                                       headerFields: ["Content-Type": "application/json"])!)
    }
}

private func extrasClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/jellyfin")
    return JellyfinClient(server: server, identity: .init(deviceID: "test", deviceName: "test"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "test"),
        transport: transport)
}

private var newYork: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private final class Store: @unchecked Sendable {
    var values: [String: [String]] = [:]
}

private func skips(_ store: Store) -> CatchUpSkips {
    CatchUpSkips(server: "https://media.example", viewerID: "viewer",
                 read: { store.values[$0] }, write: { store.values[$0] = $1 })
}

@Suite("Plugin Calendar and Catch Up") struct PluginExtrasTests {
    @Test func theManifestTurnsEachExtraOnByItself() async throws {
        #expect(PluginExtras.decode(Data(#"{"calendar":true,"catchUp":false}"#.utf8)) == .init(calendar: true))
        #expect(PluginExtras.decode(Data("[]".utf8)) == .none)
        let missing = ExtrasTransport([(404, "")])
        #expect(try await extrasClient(missing).pluginExtras() == .none)
        let refused = ExtrasTransport([(403, "")])
        #expect(try await extrasClient(refused).pluginExtras() == .none)
        let on = ExtrasTransport([(200, #"{"calendar":true,"catchUp":true}"#)])
        #expect(try await extrasClient(on).pluginExtras() == .init(calendar: true, catchUp: true))
        let request = try #require(await on.requests.first)
        #expect(request.url?.path == "/jellyfin/Zorofin/Extras")
        #expect(request.value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token")
    }

    @Test func calendarEntriesLandOnTheViewersDay() throws {
        let calendar = newYork
        // 01:30 UTC on the 10th is the evening of the 9th in New York.
        let episode = try #require(CalendarEvent(json: [
            "kind": "episode", "title": "Sample Detective", "subtitle": "S1:E1 · Pilot",
            "at": "2026-11-10T01:30:00Z", "premiere": true, "release": "airing",
            "posterUrl": "http://insecure.example/p.jpg", "itemId": ""
        ], calendar: calendar))
        #expect(episode.day == "2026-11-09")
        #expect(episode.badge == "Series premiere")
        #expect(episode.posterURL == nil && episode.itemID == nil)
        // Movie releases are dates: the 12th everywhere.
        let movie = try #require(CalendarEvent(json: [
            "kind": "movie", "title": "The Long Road Home", "at": "2026-11-12T00:00:00Z", "allDay": true,
            "release": "digital", "posterUrl": "https://image.example/p.jpg", "itemId": "abc"
        ], calendar: calendar))
        #expect(movie.day == "2026-11-12" && movie.badge == "Digital release")
        #expect(movie.posterURL?.host == "image.example" && movie.itemID == "abc")
        #expect(CalendarEvent(json: ["kind": "album", "title": "x", "at": "2026-11-12T00:00:00Z"]) == nil)
        #expect(CalendarEvent(json: ["kind": "movie", "title": "x", "at": "soon"]) == nil)
        let season = CalendarEvent(kind: "episode", title: "Night Market", at: .now, day: "2026-11-12",
                                   subtitle: "S4:E1 · Back Again", premiere: true)
        #expect(season.badge == "Season premiere")
    }

    @Test func theAgendaGroupsFromTodayAndLabelsDays() throws {
        let calendar = newYork
        let now = try #require(CalendarEvent.instant("2026-11-09T15:00:00Z"))
        func event(_ kind: String, _ title: String, _ day: String, hour: Int = 20, allDay: Bool = false) -> CalendarEvent {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            let at = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: allDay ? 0 : hour))!
            return CalendarEvent(kind: kind, title: title, at: at, day: day, allDay: allDay)
        }
        let events = [event("episode", "Yesterday", "2026-11-08"), event("episode", "Late", "2026-11-09", hour: 22),
                      event("movie", "Release", "2026-11-09", allDay: true), event("episode", "Early", "2026-11-09", hour: 21),
                      event("episode", "Thursday", "2026-11-12")]
        let days = CalendarAgenda.group(events, filter: .all, now: now, calendar: calendar)
        #expect(days.map(\.day) == ["2026-11-09", "2026-11-12"])
        #expect(days[0].events.map(\.title) == ["Early", "Late", "Release"])
        #expect(CalendarAgenda.group(events, filter: .movies, now: now, calendar: calendar).map(\.day) == ["2026-11-09"])
        #expect(CalendarAgenda.label("2026-11-09", now: now, calendar: calendar) == "Today · Monday, November 9")
        #expect(CalendarAgenda.label("2026-11-10", now: now, calendar: calendar) == "Tomorrow · Tuesday, November 10")
        #expect(CalendarAgenda.label("2026-11-12", now: now, calendar: calendar) == "Thursday, November 12")
    }

    @Test func calendarAsksForTheViewersFourWeeks() async throws {
        let transport = ExtrasTransport([(200, #"{"items":[{"kind":"movie","title":"A","at":"2026-11-12","allDay":true},{"kind":"x"}]}"#)])
        let start = try #require(CalendarEvent.instant("2026-11-09T15:00:00Z"))
        let events = try await extrasClient(transport).calendar(start: start, calendar: newYork)
        #expect(events.map(\.title) == ["A"])
        let url = try #require(await transport.requests.first?.url)
        #expect(url.path == "/jellyfin/Zorofin/Arr/Calendar")
        #expect(url.query?.contains("start=2026-11-09") == true && url.query?.contains("days=28") == true)
        let broken = ExtrasTransport([(200, "{}")])
        await #expect(throws: ClientError.invalidResponse) { try await extrasClient(broken).calendar(start: start) }
    }

    @Test func catchUpKeepsWatchedAndLikedTitlesButExcludesLocalSkips() throws {
        let store = Store()
        let saved = skips(store)
        var liked = MediaItem(id: "liked", name: "Liked", type: "Movie")
        liked.userData = UserData(); liked.userData?.likes = true
        var played = MediaItem(id: "seen", name: "Seen", type: "Movie"); played.userData = .init(played: true)
        let titles = [MediaItem(id: "a", name: "A", type: "Movie"), liked, played,
                      MediaItem(id: "b", name: "B", type: "Series"), MediaItem(id: "c", name: "C", type: "Movie")]
        saved.add("b")
        var queue = CatchUpQueue(titles, skips: saved)
        #expect(queue.items.map(\.id) == ["a", "liked", "seen", "c"])
        #expect(queue.current?.id == "a" && queue.position == "1 of 4")
        queue.next(); queue.next(); queue.next(); queue.next()
        #expect(queue.done)
        for i in 0..<510 { saved.add("t\(i)") }
        #expect(store.values[saved.key]?.count == 500 && store.values[saved.key]?.last == "t509")
        #expect(saved.key == "zorofin-catchup-skips:https://media.example:viewer")
        saved.clear()
        #expect(!saved.contains("t509"))
    }

    @Test func undoRestoresOnlyTheLastSkipAndQueuePosition() {
        let store = Store(), saved = skips(store)
        var queue = CatchUpQueue([MediaItem(id: "a", name: "A"), MediaItem(id: "b", name: "B")], skips: saved)
        saved.add("other"); saved.add("a"); queue.next()
        saved.remove("a"); queue.restore(0)
        #expect(queue.current?.id == "a" && !saved.contains("a") && saved.contains("other"))
        queue.restore(-1); #expect(queue.current?.id == "a")
    }

    @Test func legacyRatingAndTelemetryRemainCompatible() async throws {
        let transport = ExtrasTransport([(200, ""), (204, ""), (500, "")])
        let client = try extrasClient(transport)
        try await client.likeItem("abc")
        await client.logCatchUp("abc", action: .later)
        await client.logCatchUp("abc", action: .skip) // A failed log never throws.
        let requests = await transport.requests
        #expect(requests[0].httpMethod == "POST" && requests[0].url?.path == "/jellyfin/UserItems/abc/Rating")
        #expect(requests[0].url?.query?.contains("likes=true") == true)
        #expect(requests[1].url?.path == "/jellyfin/Zorofin/Extras/CatchUp/Log")
        let body = try #require(requests[1].httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["itemId": "abc", "action": "later"])
    }

    @Test func likeOnlyWritesRecommendationTasteAndRequiresAcknowledgment() async throws {
        let transport = ExtrasTransport([
            (200, #"{"schemaVersion":1,"likedItemIds":[]}"#),
            (200, #"{"schemaVersion":1,"likedItemIds":["aabb"]}"#)
        ])
        let client = try extrasClient(transport)
        await #expect(throws: ClientError.invalidResponse) { try await client.likeForRecommendations("AA-BB") }
        try await client.likeForRecommendations("AA-BB")
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.path == "/jellyfin/Zorofin/Companion/recommendations/taste" })
        let body = try #require(requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["itemId": "AA-BB", "action": "like"])
    }
    @Test func catchUpIncludesPlayedAndFiltersSharedLikes() async throws {
        let transport = ExtrasTransport([
            (200, #"{"Items":[{"Id":"AA-BB","Name":"Liked","Type":"Movie"},{"Id":"seen","Name":"Seen","Type":"Movie","UserData":{"Played":true}}]}"#),
            (200, #"{"schemaVersion":1,"likedItemIds":["aabb"]}"#)
        ])
        let titles = try await extrasClient(transport).catchUpTitles(.all)
        #expect(titles.map(\.id) == ["seen"])
        let requests = await transport.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.httpMethod == "GET" })
        #expect(requests.first?.url?.query?.contains("IsPlayed") == false)
    }

}
