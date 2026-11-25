import Foundation
import Testing
@testable import ZorofinCore

private actor ProblemTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status = 204
    func setStatus(_ value: Int) { status = value }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private func problemClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    return .init(server: server, identity: .init(deviceID: "fixture", deviceName: "Living Room", version: "1.5.0"),
                 session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture"), transport: transport)
}
private func problem(_ kind: PlaybackProblem = .stalled, client: JellyfinClient) -> PlaybackProblemReport {
    var episode = MediaItem(id: "e1", name: "Pilot", type: "Episode")
    episode.seriesName = "Big Show"
    return .init(kind: kind, item: episode, platform: "Apple TV", identity: client.identity,
                 method: PlaybackProblemReport.method("Transcode", isLive: false), reason: String(repeating: "x", count: 400),
                 startMs: 12_000, positionSeconds: -4)
}

@Suite("Playback problem reports") struct PlaybackProblemsTests {
    @Test func sendsOneProblemToTheViewersOwnServer() async throws {
        let transport = ProblemTransport(), client = try problemClient(transport)
        await PlaybackProblemLog().send(problem(.startFailed, client: client), client: client)
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://media.example/base/Zorofin/PlaybackReports")
        #expect(request.value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["kind"] as? String == "start_failed")
        #expect(body["itemId"] as? String == "e1")
        #expect(body["title"] as? String == "Big Show: Pilot")
        #expect(body["platform"] as? String == "Apple TV")
        #expect(body["appVersion"] as? String == "1.5.0")
        #expect(body["device"] as? String == "Living Room")
        #expect(body["method"] as? String == "transcode")
        #expect((body["reason"] as? String)?.count == 300)
        #expect(body["startMs"] as? Int == 12_000)
        #expect(body["positionSeconds"] as? Int == 0)
    }
    @Test func optionalNumbersAreLeftOutAndMethodsUseTheShortWords() throws {
        let client = try problemClient(ProblemTransport())
        let report = PlaybackProblemReport(kind: .qualityLowered, item: MediaItem(id: "m", name: "Movie"), platform: "iPhone", identity: client.identity)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(body["kind"] as? String == "quality_lowered" && body["title"] as? String == "Movie")
        #expect(body["startMs"] == nil && body["positionSeconds"] == nil)
        #expect(PlaybackProblemReport.method("DirectPlay", isLive: false) == "direct")
        #expect(PlaybackProblemReport.method("DirectStream", isLive: false) == "remux")
        #expect(PlaybackProblemReport.method("DirectPlay", isLive: false, onDevice: true) == "on-device")
        #expect(PlaybackProblemReport.method("Transcode", isLive: true) == "live")
        #expect(PlaybackProblemReport.milliseconds(.milliseconds(12_345)) == 12_345)
    }
    @Test func goesQuietOnceTheServerStopsCollectingAndNeverThrows() async throws {
        let transport = ProblemTransport(), client = try problemClient(transport), log = PlaybackProblemLog()
        await transport.setStatus(500)
        await log.send(problem(client: client), client: client)
        await transport.setStatus(404)
        await log.send(problem(client: client), client: client)
        await transport.setStatus(204)
        await log.send(problem(client: client), client: client)
        #expect(await transport.requests.count == 2)
    }
    @Test func aFailureLoopCannotFloodTheServer() async throws {
        let transport = ProblemTransport(), client = try problemClient(transport), log = PlaybackProblemLog()
        for _ in 0..<(PlaybackProblemLog.maxPerSession + 10) { await log.send(problem(client: client), client: client) }
        #expect(await transport.requests.count == PlaybackProblemLog.maxPerSession)
    }
    @Test func theServerSwitchIsReadFromTheManifestAndTheViewerSwitchDefaultsOn() throws {
        #expect(ServerFeatures().playbackReports == false)
        #expect(ServerFeatures(playbackReports: true).playbackReports)
        // Older preference files have no value: reporting stays on until the viewer turns it off.
        #expect(NativePreferences().sendPlaybackReports != false)
        var off = NativePreferences(); off.sendPlaybackReports = false
        let decoded = try JSONDecoder().decode(NativePreferences.self, from: JSONEncoder().encode(off))
        #expect(decoded.sendPlaybackReports == false)
    }
}
