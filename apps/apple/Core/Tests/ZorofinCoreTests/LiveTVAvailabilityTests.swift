import Foundation
import Testing
@testable import ZorofinCore

private actor CapacityTransport: HTTPTransport {
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
private struct CancelledCapacityTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw CancellationError() }
}
private func capacityClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/jellyfin")
    return .init(server: server, identity: .init(deviceID: "fixture-tv", deviceName: "Apple TV"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture-tv"), transport: transport)
}
private let occupied = #"{"limit":1,"state":"busy","sameChannel":false,"differentChannel":true,"ownStream":false}"#
private let free = #"{"limit":1,"state":"available","sameChannel":false,"differentChannel":false,"ownStream":false}"#

@Suite("Live TV capacity") struct LiveTVAvailabilityTests {
    @Test func freshConflictBlocksBeforeAnyPlaybackMutation() async throws {
        let transport = CapacityTransport([(200, occupied)])
        let client = try capacityClient(transport)
        await #expect(throws: LiveTVCapacityError.self) { try await client.checkLiveTVCapacity(channelID: "game", enabled: true) }
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/jellyfin/support/live-tv/status")
        #expect(requests[0].httpMethod == "GET" && requests[0].httpBody == nil)
        #expect(requests[0].value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "channelId", value: "game")))
        #expect(query.contains(.init(name: "deviceId", value: "fixture-tv")))
    }
    @Test(arguments: [free,
        #"{"limit":1,"state":"busy","sameChannel":true,"differentChannel":false,"ownStream":false}"#,
        #"{"limit":1,"state":"busy","sameChannel":false,"differentChannel":false,"ownStream":true}"#,
        #"{"limit":1,"state":"unknown","sameChannel":false,"differentChannel":false,"ownStream":false}"#])
    func joinsOwnSwitchesAndAvailableCapacityAreAllowed(_ body: String) async throws {
        let client = try capacityClient(CapacityTransport([(200, body)]))
        try await client.checkLiveTVCapacity(channelID: "channel", enabled: true)
    }
    @Test func unadvertisedServersAreNotProbed() async throws {
        let transport = CapacityTransport([])
        try await capacityClient(transport).checkLiveTVCapacity(channelID: "channel", enabled: false)
        #expect(await transport.requests.isEmpty)
    }
    @Test(arguments: [404, 403, 503]) func optionalServiceFailuresRetainNativePlayback(_ code: Int) async throws {
        try await capacityClient(CapacityTransport([(code, "")])).checkLiveTVCapacity(channelID: "channel", enabled: true)
    }
    @Test func busyResultsAreNeverReusedForNextAttempt() async throws {
        let transport = CapacityTransport([(200, occupied), (200, free)])
        let client = try capacityClient(transport)
        await #expect(throws: LiveTVCapacityError.self) { try await client.checkLiveTVCapacity(channelID: "channel", enabled: true) }
        try await client.checkLiveTVCapacity(channelID: "channel", enabled: true)
        #expect(await transport.requests.count == 2)
    }
    @Test func cancellationCannotFallThroughToPlayback() async throws {
        let client = try capacityClient(CancelledCapacityTransport())
        await #expect(throws: CancellationError.self) { try await client.checkLiveTVCapacity(channelID: "channel", enabled: true) }
    }
    @Test(arguments: ["{}", #"{"limit":0,"state":"busy","sameChannel":false,"differentChannel":true,"ownStream":false}"#,
        #"{"limit":1,"state":"busy","sameChannel":true,"differentChannel":true,"ownStream":false}"#,
        #"{"limit":1,"state":"available","sameChannel":false,"differentChannel":true,"ownStream":false}"#])
    func malformedStatusCannotInventAConflict(_ body: String) async throws {
        try await capacityClient(CapacityTransport([(200, body)])).checkLiveTVCapacity(channelID: "channel", enabled: true)
    }
    @Test func featureIsExplicitlyAdvertisedAndVersioned() async throws {
        for (version, enabled, expected) in [(1, true, true), (2, true, false), (1, false, false)] {
            let body = "{\"schemaVersion\":1,\"features\":{\"liveTVAvailability\":{\"version\":\(version),\"enabled\":\(enabled)}}}"
            let client = try capacityClient(CapacityTransport([(200, body)]))
            #expect(try await client.discoverFeatures().features.liveTVAvailability == expected)
        }
    }
}
