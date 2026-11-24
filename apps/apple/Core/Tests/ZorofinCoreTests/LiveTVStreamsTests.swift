import Foundation
import Testing
@testable import ZorofinCore

private actor StreamsTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw ClientError.network }
        let (code, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}
private func streamsClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/jellyfin")
    return .init(server: server, identity: .init(deviceID: "fixture-tv", deviceName: "Apple TV"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture-tv"), transport: transport)
}

private let espn = String(repeating: "e", count: 32)
private let fox = String(repeating: "f", count: 32)
// The companion's response, including fields the apps ignore.
private let full = """
{"version":1,"state":"full","limit":1,"inUse":1,"free":0,"otherUse":0,"message":"1 of 1 Live TV stream in use: ESPN.",
 "streams":[{"channelId":"\(espn)","channelName":"ESPN","channelNumber":"206","programme":{"title":"SportsCenter","endsAt":"2026-11-07T16:00:00.0000000Z"},
 "startedAt":"2026-11-07T15:00:00.000Z","viewers":2,"paused":false,"yours":false}],
 "request":{"channelId":"\(fox)","playing":false,"canStart":false,"reason":"full","message":""}}
"""

@Suite("Live TV streams") struct LiveTVStreamsTests {
    @Test func namesTheChannelUsingTheOnlyStream() throws {
        let status = try JSONDecoder().decode(LiveTVStreams.self, from: Data(full.utf8))
        #expect(status.summary == "1 of 1 Live TV stream in use. Anyone can join a channel that’s already playing.")
        #expect(status.channelLine(for: fox) == "ESPN is using the only Live TV stream.")
        #expect(status.channelLine(for: espn) == "Already playing for 2 people. Joining doesn’t use another stream.")
        let blocked = try #require(status.blocked(channelID: fox))
        #expect(blocked.text == "ESPN is using the only Live TV stream right now.")
        #expect(blocked.hint == "You can watch ESPN instead, or try again when a stream is free.")
        #expect(blocked.join?.channel.isLive == true)
        #expect(status.blocked(channelID: espn) == nil)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-07T15:42:00Z"))
        #expect(status.streams[0].detail(now: now) == "2 watching · 18 min left")
    }

    @Test func freeStreamsBlockNothing() {
        let status = LiveTVStreams(limit: 2, inUse: 1, free: 1, streams: [.init(channelId: espn, channelName: "ESPN")])
        #expect(status.blocked(channelID: fox) == nil)
        #expect(status.channelLine(for: fox) == nil)
        #expect(status.summary == "1 of 2 Live TV streams in use. 1 stream free for another channel.")
    }

    @Test func conflictThrowsWithTheChannelToWatchInstead() async throws {
        let transport = StreamsTransport([(200, full)])
        let client = try streamsClient(transport)
        await #expect(throws: LiveTVStreamsConflict.self) {
            try await client.checkLiveTVCapacity(channelID: fox, features: .init(liveTvStreams: true))
        }
        let url = try #require(await transport.requests.first?.url?.absoluteString)
        #expect(url.contains("/Zorofin/Companion/liveTvStreams/status"))
        #expect(url.contains("channelId=\(fox)"))
    }

    @Test func missingModuleLeavesPlaybackAlone() async throws {
        let client = try streamsClient(StreamsTransport([(404, "")]))
        try await client.checkLiveTVCapacity(channelID: fox, features: .init(liveTvStreams: true))
    }
}
