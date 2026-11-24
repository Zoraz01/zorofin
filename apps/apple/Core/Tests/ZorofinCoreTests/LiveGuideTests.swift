import Foundation
import Testing
@testable import ZorofinCore

private let guideStart = Date(timeIntervalSince1970: 1_800_000_000)
private func listing(_ name: String, channel: String = "one", start: Double, end: Double) -> LiveProgram {
    var program = LiveProgram(name: name, startDate: guideStart.addingTimeInterval(start).ISO8601Format(), endDate: guideStart.addingTimeInterval(end).ISO8601Format())
    program.channelId = channel; program.id = name; return program
}
private actor GuideTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let pages: [(Int, String)]
    init(_ pages: [(Int, String)]) { self.pages = pages }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count; requests.append(request)
        let page = pages[min(index, pages.count - 1)]
        return (Data(page.1.utf8), HTTPURLResponse(url: request.url!, statusCode: page.0, httpVersion: nil, headerFields: nil)!)
    }
}
private func guideClient(_ transport: GuideTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://guide.example/jellyfin")
    return JellyfinClient(server: server, identity: .init(deviceID: "device", deviceName: "Test"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "device"), transport: transport)
}
private func page(_ items: [LiveProgram], total: Int) throws -> String {
    struct Page: Encodable { let items: [LiveProgram]; let totalRecordCount: Int }
    return String(decoding: try Wire.encoder().encode(Page(items: items, totalRecordCount: total)), as: UTF8.self)
}

@Suite("Live TV guide") struct LiveGuideTests {
    @Test func timelineClipsBoundariesFillsGapsAndRemovesOverlap() {
        let channel = MediaItem(id: "one", name: "Channel", type: "TvChannel")
        let a = listing("A", start: -900, end: 1800)
        let row = LiveGuideRow(channel: channel, programs: [
            listing("C", start: 5400, end: 9000), a, a,
            listing("Overlap", start: 900, end: 2400), listing("Other", channel: "other", start: 0, end: 7200),
            listing("Ends at start", start: -100, end: 0), listing("Starts at end", start: 7200, end: 8000),
            listing("Invalid", start: 500, end: 100)], window: .init(start: guideStart))
        #expect(row.slots.map { $0.program?.name } == ["A", "Overlap", nil, "C"])
        #expect(row.slots.map(\.duration) == [1800, 600, 3000, 1800])
        #expect(row.slots.first?.start == guideStart)
        #expect(row.slots.last?.end == guideStart.addingTimeInterval(7200))
        #expect(Set(row.slots.map(\.id)).count == row.slots.count)
        for pair in zip(row.slots, row.slots.dropFirst()) { #expect(pair.0.end == pair.1.start) }
    }
    @Test func noGuideIsAnExplicitGapNotAnInventedCurrentProgram() {
        var channel = MediaItem(id: "one", name: "Channel", type: "TvChannel")
        channel.currentProgram = listing("Stale current", start: -7200, end: 0)
        let row = LiveGuideRow(channel: channel, programs: [], window: .init(start: guideStart))
        #expect(row.slots.count == 1 && row.slots[0].program == nil && row.slots[0].duration == 7200)
    }
    @Test func filtersUseChannelIdentityNumbersAndViewerFavorites() {
        var one = MediaItem(id: "one", name: "Cinéma", type: "TvChannel", userData: .init(isFavorite: true)); one.channelNumber = "12.1"
        let two = MediaItem(id: "two", name: "News", type: "TvChannel")
        #expect(LiveGuideRow.matching([one, two, one], query: " cinema ", favorites: false).map(\.id) == ["one"])
        #expect(LiveGuideRow.matching([one, two], query: "12.1", favorites: false).map(\.id) == ["one"])
        #expect(LiveGuideRow.matching([one, two], query: "", favorites: true).map(\.id) == ["one"])
        #expect(LiveGuideRow.matching([one, two], query: "News", favorites: true).isEmpty)
    }
    @Test func windowsUseElapsedBroadcastTimeAcrossMidnightAndDST() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        for iso in ["2026-11-01T05:45:00Z", "2026-11-01T06:45:00Z", "2026-03-08T07:15:00Z", "2026-11-04T04:59:00Z"] {
            let date = try #require(ISO8601DateFormatter().date(from: iso))
            let window = LiveGuideWindow.current(at: date, calendar: calendar)
            #expect(window.contains(date) && !window.contains(window.end))
            #expect(calendar.component(.minute, from: window.start) % 30 == 0)
            #expect(window.end.timeIntervalSince(window.start) == 7200)
            #expect(window.shifted(1).start == window.end && window.shifted(1).shifted(-1) == window)
            #expect(window.fraction(window.start.addingTimeInterval(-60)) == 0 && window.fraction(window.end.addingTimeInterval(60)) == 1)
        }
    }
    @Test func guidePaginatesAndKeepsOnlyRequestedChannelWindowWithoutPlayback() async throws {
        let first = listing("Now", start: -900, end: 1800), next = listing("Next", start: 1800, end: 7200)
        let transport = GuideTransport([(200, try page([first], total: 3)), (200, try page([next, listing("Other", channel: "other", start: 0, end: 7200)], total: 3))])
        let values = try await guideClient(transport).guidePrograms(channelIDs: ["one", "one"], window: .init(start: guideStart))
        #expect(values.map(\.name) == ["Now", "Next"])
        let requests = await transport.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.url!.path == "/jellyfin/LiveTv/Programs" })
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        for item in [URLQueryItem(name: "userId", value: "viewer"), .init(name: "channelIds", value: "one"), .init(name: "startIndex", value: "1"),
                     .init(name: "minEndDate", value: guideStart.ISO8601Format()), .init(name: "maxStartDate", value: guideStart.addingTimeInterval(7200).ISO8601Format())] { #expect(query.contains(item)) }
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
    }
    @Test func refusedMalformedRepeatedAndOversizedResultsAreErrorsNotEmptySchedules() async throws {
        for response in [(403, "{}"), (200, "{}"), (200, try page(Array(repeating: listing("A", start: 0, end: 100), count: 201), total: 201))] {
            let transport = GuideTransport([response])
            await #expect(throws: (any Error).self) { try await guideClient(transport).guidePrograms(channelIDs: ["one"], window: .init(start: guideStart)) }
        }
        let repeated = GuideTransport([(200, try page([listing("A", start: 0, end: 100)], total: 4))])
        await #expect(throws: ClientError.invalidResponse) { try await guideClient(repeated).guidePrograms(channelIDs: ["one"], window: .init(start: guideStart)) }
        #expect(await repeated.requests.count == 2)
    }
    @Test func missingSessionAndInvalidChannelBatchCannotReachServer() async throws {
        let transport = GuideTransport([(200, "{}")]), client = try guideClient(transport)
        let anonymous = JellyfinClient(server: client.server, identity: client.identity, transport: transport)
        let mismatch = JellyfinClient(server: try ServerAddress("https://other.example"), identity: client.identity, session: client.session, transport: transport)
        for invalid in [anonymous, mismatch] {
            await #expect(throws: ClientError.missingSession) { try await invalid.guidePrograms(channelIDs: ["one"], window: .init(start: guideStart)) }
            await #expect(throws: ClientError.missingSession) { try await invalid.guideChannels() }
        }
        for ids in [[], [""], ["one,two"], (0..<41).map(String.init)] {
            await #expect(throws: ClientError.invalidResponse) { try await client.guidePrograms(channelIDs: ids, window: .init(start: guideStart)) }
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func channelIndexRequestsViewerFavoritesWithoutOpeningTuner() async throws {
        let transport = GuideTransport([(200, #"{"Items":[{"Id":"one","Name":"News","Type":"TvChannel","ChannelNumber":"1","UserData":{"IsFavorite":true}}],"TotalRecordCount":1}"#)])
        let response = try await guideClient(transport).guideChannels(start: 200)
        #expect(response.items.first?.userData?.isFavorite == true)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "GET" && request.url!.path == "/jellyfin/LiveTv/Channels")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "startIndex", value: "200")))
        #expect(query.contains(.init(name: "userId", value: "viewer")))
        #expect(query.contains(.init(name: "enableUserData", value: "true")))
    }
}
