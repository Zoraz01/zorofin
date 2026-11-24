import Foundation
import Testing
@testable import ZorofinCore

private let guideNow = ISO8601DateFormatter().date(from: "2026-10-17T18:00:00Z")!
private func program(_ name: String, channel: String? = "channel", start: String = "2026-10-17T17:00:00Z", end: String = "2026-10-17T19:00:00Z") -> LiveProgram {
    var value = LiveProgram(name: name, startDate: start, endDate: end)
    value.channelId = channel
    return value
}
private actor PlayerLiveTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let responses: [(Int, String)]
    let delay: Duration
    init(_ responses: [(Int, String)], delay: Duration = .zero) { self.responses = responses; self.delay = delay }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        let value = index < responses.count ? responses[index] : (204, "")
        return (Data(value.1.utf8), HTTPURLResponse(url: request.url!, statusCode: value.0, httpVersion: nil, headerFields: nil)!)
    }
}
private func playerLiveClient(_ transport: PlayerLiveTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://fixture.example/jellyfin")
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Fixture"), token: "fixture-token", deviceID: "fixture"), transport: transport)
}

@Suite("Live player guide") struct LivePlayerGuideTests {
    @Test func currentAndNextAreOrderedAndChannelScoped() {
        let guide = LivePlayerGuide(channelID: "channel", programs: [
            program("Next", start: "2026-10-17T19:00:00Z", end: "2026-10-17T20:00:00Z"),
            program("Other channel", channel: "other"), program("Unknown channel", channel: nil), program("Now"),
            program("Broken", end: "bad"), program("Reversed", start: "2026-10-17T20:00:00Z")], fetchedAt: guideNow)
        #expect(guide.programs.map(\.name) == ["Now", "Next"])
        #expect(guide.current(at: guideNow)?.name == "Now")
        #expect(guide.next(at: guideNow)?.name == "Next")
        #expect(guide.current(at: guideNow.addingTimeInterval(119)) != nil)
        #expect(guide.current(at: guideNow.addingTimeInterval(120)) == nil)
        #expect(guide.next(at: guideNow.addingTimeInterval(120)) == nil)
        #expect(guide.current(at: guideNow.addingTimeInterval(-1)) == nil)
    }
    @Test func programBoundaryAndMissingGuideNeverInventAnEvent() {
        let next = program("Next", start: "2026-10-17T18:00:00Z", end: "2026-10-17T19:00:00Z")
        let ending = program("Ending", end: "2026-10-17T18:00:00Z")
        let guide = LivePlayerGuide(channelID: "channel", programs: [ending, next], fetchedAt: guideNow)
        #expect(!ending.isAiring(at: guideNow) && next.isAiring(at: guideNow))
        #expect(guide.current(at: guideNow)?.name == "Next" && guide.next(at: guideNow) == nil)
        let empty = LivePlayerGuide(channelID: "channel", programs: [], fetchedAt: guideNow)
        #expect(empty.current(at: guideNow) == nil && empty.next(at: guideNow) == nil)
    }
    @Test func guideReadUsesViewerAndBasePathWithoutOpeningOrWritingPlayback() async throws {
        let transport = PlayerLiveTransport([(200, #"{"Items":[{"Name":"Now","ChannelId":"channel","StartDate":"2026-10-17T17:00:00Z","EndDate":"2026-10-17T19:00:00Z"}]}"#)])
        let guide = try await playerLiveClient(transport).livePlayerGuide(channelID: "channel", at: guideNow)
        #expect(guide.current(at: guideNow)?.name == "Now")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.url?.path == "/jellyfin/LiveTv/Programs")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: true)!.queryItems!
        for item in [URLQueryItem(name: "userId", value: "viewer"), .init(name: "channelIds", value: "channel"),
                     .init(name: "limit", value: "8"), .init(name: "sortBy", value: "StartDate"),
                     .init(name: "enableImages", value: "false"), .init(name: "minEndDate", value: guideNow.ISO8601Format()),
                     .init(name: "maxStartDate", value: guideNow.addingTimeInterval(43200).ISO8601Format())] { #expect(query.contains(item)) }
    }
    @Test func missingOrMismatchedSessionCannotReadGuide() async throws {
        let transport = PlayerLiveTransport([]), client = try playerLiveClient(transport)
        let other = JellyfinClient(server: try ServerAddress("https://other.example"), identity: client.identity, session: client.session, transport: transport)
        await #expect(throws: ClientError.missingSession) { try await other.livePlayerGuide(channelID: "channel") }
        let anonymous = JellyfinClient(server: client.server, identity: client.identity, transport: transport)
        await #expect(throws: ClientError.missingSession) { try await anonymous.livePlayerGuide(channelID: "channel") }
        await #expect(throws: ClientError.invalidResponse) { try await client.livePlayerGuide(channelID: "") }
        #expect(await transport.requests.isEmpty)
    }
    @Test func refusedOrOversizedGuideDoesNotBecomeSuccessfulEmptyData() async throws {
        let denied = PlayerLiveTransport([(403, "{}")])
        await #expect(throws: (any Error).self) { try await playerLiveClient(denied).livePlayerGuide(channelID: "channel") }
        let body = "{\"Items\":[" + Array(repeating: "{\"Name\":\"Too many\"}", count: 9).joined(separator: ",") + "]}"
        let oversized = PlayerLiveTransport([(200, body)])
        await #expect(throws: ClientError.invalidResponse) { try await playerLiveClient(oversized).livePlayerGuide(channelID: "channel") }
        #expect(await denied.requests.count == 1)
        #expect(await oversized.requests.count == 1)
    }
}

@Suite("Live player window") struct LivePlayerWindowTests {
    @Test func recommendedOffsetDefinesSafeLiveEdgeAndSeekLimit() {
        let timeline = PlayerTimeline(localPosition: 988, duration: nil, isLive: true,
            seekable: [.init(start: 600, end: 1000)!], liveEdgeOffset: 12)
        #expect(timeline.isAtLiveEdge && timeline.behindLive == 0 && timeline.liveEdgeTarget == 988)
        #expect(timeline.canTimeShiftLive && timeline.remaining == nil)
        #expect(timeline.seek(to: 1000, allowRestart: true) == .local(seconds: 988))
        let behind = PlayerTimeline(localPosition: 900, duration: nil, isLive: true,
            seekable: [.init(start: 600, end: 1000)!], liveEdgeOffset: 12)
        #expect(!behind.isAtLiveEdge && behind.behindLive == 88)
    }
    @Test func shortDiscontinuousAndMissingBuffersDoNotPretendToOfferRewind() {
        let absent = PlayerTimeline(localPosition: 100, duration: 3600, isLive: true)
        #expect(!absent.canTimeShiftLive && absent.liveEdgeTarget == nil && absent.behindLive == nil && absent.bounds == nil)
        let fragmented = PlayerTimeline(localPosition: 199, duration: nil, isLive: true,
            seekable: [.init(start: 0, end: 10)!, .init(start: 190, end: 200)!])
        #expect(!fragmented.canTimeShiftLive)
        let tiny = PlayerTimeline(localPosition: 199, duration: nil, isLive: true,
            seekable: [.init(start: 198, end: 200)!], liveEdgeOffset: 12)
        #expect(tiny.liveEdgeTarget == 199 && tiny.isAtLiveEdge)
        let invalid = PlayerTimeline(localPosition: 100, duration: nil, isLive: true,
            seekable: [.init(start: 0, end: 200)!], liveEdgeOffset: .nan)
        #expect(invalid.liveEdgeTarget == 198)
    }
    @Test func expiredPausedPositionClampsToCurrentWindowAndNeverRestartsAtVODTime() {
        let moved = PlayerTimeline(localPosition: 100, duration: nil, isLive: true,
            seekable: [.init(start: 160, end: 200)!, .init(start: 240, end: 300)!])
        #expect(moved.canTimeShiftLive && !moved.isAtLiveEdge)
        #expect(moved.seek(to: 100, allowRestart: true) == .local(seconds: 160))
        #expect(moved.seek(to: 230, allowRestart: true) == .local(seconds: 240))
        #expect(moved.seek(to: 10000, allowRestart: true) == .local(seconds: 298))
    }
    @Test func channelPanelKeepsIntentButCannotResumeAfterInterruption() {
        var interaction = PlayerInteraction()
        interaction.update(phase: .playing, now: 0); interaction.open(.channels)
        interaction.update(phase: .playing, now: 2); interaction.tick(now: 60)
        #expect(interaction.controlsVisible && interaction.panelResumeIntent)
        interaction.interrupt(now: 61)
        let resumes = interaction.closePanel(now: 62)
        #expect(!resumes)
    }
}

@Suite("Live stream release gate") struct LivePlayerReleaseTests {
    private func reporter(_ transport: PlayerLiveTransport, owned: Bool = true) throws -> PlaybackReporter {
        let info = try Wire.decoder().decode(PlaybackInfo.self, from: Data((owned
            ? #"{"PlaySessionId":"fixture-play-session","MediaSources":[{"Id":"source","SupportsDirectPlay":true,"RequiresClosing":true,"LiveStreamId":"our-stream"}]}"#
            : #"{"PlaySessionId":"fixture-play-session","MediaSources":[{"Id":"source","SupportsDirectPlay":true}]}"#).utf8))
        return try PlaybackReporter(client: playerLiveClient(transport), plan: PlaybackPlan.make(info: info, itemID: "channel", client: playerLiveClient(transport), options: .init()))
    }
    @Test func failedCleanupIsObservableAndExplicitRetryOnlyClosesOwnedStream() async throws {
        let transport = PlayerLiveTransport([(204, ""), (204, ""), (503, "{}"), (204, "")], delay: .milliseconds(10))
        let reporter = try reporter(transport)
        await reporter.start(positionTicks: 0, canSeek: false)
        await reporter.stop(positionTicks: 90)
        #expect(await reporter.liveStreamCloseFailed)
        #expect(await reporter.failureCount == 1)
        async let first = reporter.retryLiveCleanup()
        async let second = reporter.retryLiveCleanup()
        let (a, b) = await (first, second)
        #expect(a && b)
        await reporter.stop(positionTicks: 100)
        #expect(await !reporter.liveStreamCloseFailed)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/jellyfin/Sessions/Playing", "/jellyfin/Sessions/Playing/Stopped", "/jellyfin/LiveStreams/Close", "/jellyfin/LiveStreams/Close"])
        #expect(requests.suffix(2).allSatisfy { $0.url?.query == "liveStreamId=our-stream" })
    }
    @Test func cleanupFailureKeepsReplacementGateClosedUntilExplicitSuccessfulRetry() async throws {
        let transport = PlayerLiveTransport([(503, "{}"), (503, "{}"), (204, "")])
        let reporter = try reporter(transport)
        await reporter.stop(positionTicks: 0)
        #expect(await !reporter.retryLiveCleanup())
        #expect(await reporter.liveStreamCloseFailed)
        #expect(await reporter.retryLiveCleanup())
        #expect(await transport.requests.count == 3)
    }
    @Test func activeOwnershipCannotAuthorizeReplacementBeforeStop() async throws {
        let transport = PlayerLiveTransport([]), reporter = try reporter(transport)
        #expect(await !reporter.retryLiveCleanup())
        #expect(await transport.requests.isEmpty)
    }
    @Test func directLivePlaybackReusesTheOpenedStreamID() throws {
        let transport = PlayerLiveTransport([]), client = try playerLiveClient(transport)
        let info = try Wire.decoder().decode(PlaybackInfo.self, from: Data(#"{"PlaySessionId":"session","MediaSources":[{"Id":"source","SupportsDirectPlay":true,"RequiresOpening":true,"RequiresClosing":true,"LiveStreamId":"our-stream"}]}"#.utf8))
        let plan = try PlaybackPlan.make(info: info, itemID: "channel", client: client, options: .init())
        let query = URLComponents(url: plan.url, resolvingAgainstBaseURL: true)!.queryItems!
        #expect(query.contains(.init(name: "LiveStreamId", value: "our-stream")))
        #expect(plan.liveStreamID == "our-stream" && plan.requiresClosing && plan.method == "DirectPlay")
    }
    @Test func unownedSourceNeverSendsClose() async throws {
        let transport = PlayerLiveTransport([]), reporter = try reporter(transport, owned: false)
        await reporter.stop(positionTicks: 0)
        #expect(await reporter.retryLiveCleanup())
        #expect(await transport.requests.isEmpty)
    }
}
