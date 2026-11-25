import Foundation
import Testing
@testable import ZorofinCore

private let sessionID = "0123456789abcdef0123456789abcdef"

private func sessionJSON(version: Int = 3, status: String = "lobby", round: Int = 0, seat: String = "aaaa1111",
                         display: Bool = false, matches: [[String: Any]] = []) -> [String: Any] {
    ["schemaVersion": 1, "id": sessionID, "code": "ABCDEF", "kind": "movie", "status": status, "round": round,
     "version": version, "filters": [:], "host": true, "seat": seat, "display": display,
     "members": [["seat": "aaaa1111", "name": "Zoe Park", "display": false, "host": true, "you": true, "swiped": 4, "total": 20, "done": false],
                 ["seat": "bbbb2222", "name": "Living room", "display": true, "host": false, "you": true, "swiped": 0, "total": 0, "done": false],
                 ["seat": "cccc3333", "name": "Sam", "display": false, "host": false, "you": false, "swiped": 20, "total": 20, "done": true]],
     "voters": 2, "poolSize": 20, "matches": matches, "almost": []]
}

nonisolated(unsafe) private let dune: [String: Any] = ["itemId": "f00dfeedf00dfeedf00dfeedf00dfeed", "type": "Movie", "title": "Dune", "year": 2021,
                                   "runtimeMinutes": 155, "officialRating": "PG-13", "communityRating": 7.9, "genres": ["Sci-Fi"],
                                   "imageTag": "tag1", "likes": 2, "of": 2]

private actor PickTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, Any)] = []
    init(_ replies: [(Int, Any)]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = replies.isEmpty ? (500, ["error": "none"] as Any) : replies.removeFirst()
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func bodyData(_ index: Int) -> Data { requests[index].httpBody ?? Data() }
}

private func parse(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func pickClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    return .init(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"),
                 session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture"),
                 transport: transport)
}

@Suite("Pick Together contract") struct PickTogetherTests {
    @Test func decodesSessionView() throws {
        let view = try #require(PickTogetherSession(json: sessionJSON(matches: [dune])))
        #expect(view.code == "ABCDEF" && view.kind == .movie && view.status == .lobby && view.seat == "aaaa1111")
        #expect(view.voterMembers.map(\.name) == ["Zoe Park", "Sam"] && view.members[0].initials == "ZP")
        #expect(view.matches.first?.tally == "2 of 2" && view.matches.first?.metadata == "2021 · PG-13 · 2h 35m")
        #expect(view.you?.name == "Zoe Park")
        #expect(view.canStart(asDisplay: true) && view.canStart(asDisplay: false))
        var one = view; one.voters = 1
        #expect(!one.canStart(asDisplay: true) && !one.canStart(asDisplay: false))
    }

    @Test func rejectsOtherSchemasAndBadIDs() {
        var json = sessionJSON(); json["schemaVersion"] = 2
        #expect(PickTogetherSession(json: json) == nil)
        json = sessionJSON(); json["id"] = "../Users"
        #expect(PickTogetherSession(json: json) == nil)
        json = sessionJSON(); json["kind"] = "episode"
        #expect(PickTogetherSession(json: json) == nil)
    }

    @Test func codesAndLinks() throws {
        #expect(PickTogetherCode.normalize(" abc def ") == "ABCDEF")
        #expect(PickTogetherCode.normalize("abc-de") == nil)
        #expect(PickTogetherCode.normalize("ABCDE0") == nil) // 0 is not in the alphabet
        #expect(PickTogetherCode.spaced("ABCDEF") == "ABC DEF")
        let server = try ServerAddress("https://media.example/base")
        let link = try #require(PickTogetherLink.joinURL(server: server, code: "abcdef"))
        #expect(link.absoluteString == "https://media.example/base/web/#/home?zorofin=catchup&pick=ABCDEF")
        #expect(PickTogetherLink.code(from: link.absoluteString, server: server) == "ABCDEF")
        #expect(PickTogetherLink.code(from: "https://evil.example/base/web/#/home?zorofin=catchup&pick=ABCDEF", server: server) == nil)
        #expect(PickTogetherLink.code(from: "https://media.example/other/web/#/home?zorofin=catchup&pick=ABCDEF", server: server) == nil)
        #expect(PickTogetherLink.code(from: "hjk mnp", server: server) == "HJKMNP")
    }

    @Test func createJoinAndSeatCarry() async throws {
        let transport = PickTransport([(200, sessionJSON(display: true)), (200, sessionJSON(seat: "cccc3333"))])
        let client = try pickClient(transport)
        let created = try await client.createPickTogether(kind: .series, display: true)
        #expect(created.display)
        _ = try await client.joinPickTogether(code: "abc def")
        let requests = await transport.requests
        #expect(requests[0].url?.path == "/base/Zorofin/Companion/pickTogether/sessions" && requests[0].httpMethod == "POST")
        let first = parse(await transport.bodyData(0)), second = parse(await transport.bodyData(1))
        #expect(first["kind"] as? String == "series" && first["display"] as? Bool == true)
        #expect(requests[1].url?.path == "/base/Zorofin/Companion/pickTogether/join")
        #expect(second["code"] as? String == "ABCDEF")
        #expect(requests[0].value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token")
    }

    @Test func pollUnchangedDeckAndSwipe() async throws {
        let deck: [String: Any] = ["schemaVersion": 1, "status": "swiping", "round": 1, "version": 5,
                                   "cards": [dune.merging(["reason": "You requested this", "seen": "partway"]) { $1 }]]
        let transport = PickTransport([(200, ["unchanged": true, "version": 3]), (200, deck),
                                       (200, ["version": 6, "match": dune]), (200, ["version": 7, "match": NSNull()])])
        let client = try pickClient(transport)
        #expect(try await client.pickTogetherState(sessionID, seat: "aaaa1111", since: 3) == nil)
        let cards = try await client.pickTogetherDeck(sessionID, seat: "aaaa1111")
        #expect(cards.cards.first?.reason == "You requested this" && cards.cards.first?.seen == "partway")
        let liked = try await client.pickTogetherSwipe(sessionID, seat: "aaaa1111", itemID: dune["itemId"] as! String, choice: .like)
        #expect(liked.match?.title == "Dune" && liked.version == 6)
        let skipped = try await client.pickTogetherSwipe(sessionID, seat: "aaaa1111", itemID: dune["itemId"] as! String, choice: .skip)
        #expect(skipped.match == nil)
        let requests = await transport.requests
        let poll = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
        #expect(poll.queryItems?.contains(.init(name: "since", value: "3")) == true)
        #expect(poll.queryItems?.contains(.init(name: "seat", value: "aaaa1111")) == true)
        #expect(requests[1].url?.path.hasSuffix("/sessions/\(sessionID)/deck") == true)
        let swipe = parse(await transport.bodyData(2))
        #expect(swipe["seat"] as? String == "aaaa1111" && swipe["choice"] as? String == "like")
        // Session swipes never touch the solo Catch Up taste route.
        #expect(!requests.contains { $0.url?.path.contains("recommendations") == true })
    }

    @Test func removeUsesCallerSeatInQueryAndTargetInBody() async throws {
        let transport = PickTransport([(200, sessionJSON())])
        let client = try pickClient(transport)
        _ = try await client.pickTogetherRemove(sessionID, seat: "aaaa1111", target: "cccc3333")
        let request = await transport.requests[0]
        #expect(request.url?.query == "seat=aaaa1111" && request.url?.path.hasSuffix("/remove") == true)
        let target = parse(await transport.bodyData(0))
        #expect(target["seat"] as? String == "cccc3333")
    }

    @Test func errorsAreTyped() async throws {
        let transport = PickTransport([(404, ["error": "code_not_found"]), (409, ["error": "too_many_seats"]),
                                       (403, ["error": "host_only"]), (503, ["error": "busy"]), (404, ["error": "not_found"])])
        let client = try pickClient(transport)
        await #expect(throws: PickTogetherError.codeNotFound) { try await client.joinPickTogether(code: "ABCDEF") }
        await #expect(throws: PickTogetherError.tooManySeats) { try await client.joinPickTogether(code: "ABCDEF") }
        await #expect(throws: PickTogetherError.hostOnly) { try await client.pickTogetherHost(sessionID, seat: nil, action: .start) }
        await #expect(throws: PickTogetherError.busy) { try await client.createPickTogether(kind: .movie, display: false) }
        await #expect(throws: PickTogetherError.gone) { try await client.pickTogetherState(sessionID, seat: nil, since: nil) }
        #expect(PickTogetherError.gone.endsSession && !PickTogetherError.busy.endsSession)
        await #expect(throws: PickTogetherError.invalidCode) { try await client.joinPickTogether(code: "AB") }
    }

    @Test func trackerOrdersVersionsDecksAndMatches() throws {
        var tracker = PickTogetherTracker()
        let lobby = try #require(PickTogetherSession(json: sessionJSON(version: 3)))
        let tookLobby = tracker.apply(lobby)
        #expect(tookLobby && !tracker.needsDeck)
        let swiping = try #require(PickTogetherSession(json: sessionJSON(version: 5, status: "swiping", round: 1)))
        let tookSwiping = tracker.apply(swiping)
        #expect(tookSwiping && tracker.needsDeck)
        let tookStale = tracker.apply(lobby)
        #expect(!tookStale) // stale reply
        tracker.deckFetched(.init(status: .swiping, round: 1, version: 5, cards: []))
        #expect(!tracker.needsDeck)
        let card = try #require(PickTogetherCard(json: dune))
        let firstMoment = tracker.newMatch(card), repeatMoment = tracker.newMatch(card)
        #expect(firstMoment == card && repeatMoment == nil)
        let next = try #require(PickTogetherSession(json: sessionJSON(version: 9, status: "swiping", round: 2, matches: [dune])))
        tracker.apply(next)
        #expect(tracker.needsDeck)
        tracker.absorbMatches()
        let replay = tracker.newMatch(card)
        #expect(replay == nil)
        // A display never fetches a deck.
        var display = PickTogetherTracker()
        display.apply(try #require(PickTogetherSession(json: sessionJSON(version: 2, status: "swiping", round: 1, seat: "bbbb2222", display: true))))
        #expect(!display.needsDeck)
    }

    @Test func capabilityGate() async throws {
        struct Manifest: HTTPTransport {
            let enabled: Bool
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let body = #"{"schemaVersion":1,"features":{"pickTogether":{"version":1,"enabled":\#(enabled)}}}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        #expect(try await pickClient(Manifest(enabled: true)).discoverFeatures().features.pickTogether)
        #expect(try await !pickClient(Manifest(enabled: false)).discoverFeatures().features.pickTogether)
    }
}
