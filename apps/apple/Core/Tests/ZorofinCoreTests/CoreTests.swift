import Foundation
import Testing
@testable import ZorofinCore

private let server = try! ServerAddress("https://media.example/jellyfin")
private let identity = ClientIdentity(deviceID: "fixture-device", deviceName: "Test Device")
private let viewer = Viewer(id: "00000000000000000000000000000001", name: "Fixture Viewer")

private actor StubTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, Data)]
    let delay: Duration
    init(_ responses: [(Int, String)], delay: Duration = .zero) {
        self.responses = responses.map { ($0.0, Data($0.1.utf8)) }; self.delay = delay
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        let response = responses.isEmpty ? (204, Data()) : responses.removeFirst()
        return (response.1, HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!)
    }
}

private func client(_ transport: any HTTPTransport) -> JellyfinClient {
    JellyfinClient(server: server, identity: identity,
        session: Session(server: server, viewer: viewer, token: "fixture-token", deviceID: identity.deviceID), transport: transport)
}

@Suite("Server trust boundary") struct AddressTests {
    @Test func preservesBasePathAndEncodesQuery() throws {
        let url = try server.endpoint(["Items"], query: [.init(name: "searchTerm", value: "A&B / C")])
        #expect(url.path == "/jellyfin/Items")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.first?.value == "A&B / C")
    }
    @Test(arguments: ["media.example", "ftp://media.example", "https://user:pass@media.example",
        "https://media.example?ApiKey=secret", "https://media.example#token", "https://media.example/a/../b",
        "https://media.example/a/%2e%2e/b", "https://media.example:99999"])
    func rejectsInvalidInput(_ input: String) {
        #expect(throws: (any Error).self) { try ServerAddress(input) }
    }
    @Test func localHTTPRequiresChoice() throws {
        #expect(throws: ClientError.insecureServer) { try ServerAddress("http://192.168.2.3:8096") }
        #expect(throws: ClientError.insecureServer) { try ServerAddress("http://media.example", allowsLocalHTTP: true) }
        #expect(throws: ClientError.insecureServer) { try ServerAddress("http://a.10.1.2.3", allowsLocalHTTP: true) }
        #expect(try ServerAddress("http://192.168.2.3:8096", allowsLocalHTTP: true).url.scheme == "http")
        #expect(try ServerAddress("http://server.local:8096", allowsLocalHTTP: true).url.scheme == "http")
    }
    @Test(arguments: ["https://evil.example/jellyfin/video.m3u8", "//evil.example/video.m3u8",
        "http://media.example/jellyfin/video.m3u8", "https://media.example:444/jellyfin/video.m3u8",
        "/other/video.m3u8", "/jellyfin-other/video.m3u8", "/jellyfin/%2e%2e/private",
        "/jellyfin/%252e%252e/private", "https://user@media.example/jellyfin/video.m3u8"])
    func rejectsForeignMedia(_ reference: String) {
        #expect(throws: ClientError.unsafeURL) { try server.mediaURL(reference, token: "secret") }
    }
    @Test func replacesLegacyCredentials() throws {
        let url = try server.mediaURL("/jellyfin/video.m3u8?api_key=old&ApiKey=old2&token=old3&quality=8", token: "new+token")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: true)!.queryItems!
        #expect(query.filter { $0.name == "ApiKey" }.map(\.value) == ["new+token"])
        #expect(query.count == 2)
        #expect(query.first?.name == "quality")
    }
    @Test func pathsCannotInjectSegments() throws {
        #expect(throws: ClientError.unsafeURL) { try server.endpoint(["Items", "../Users"]) }
        #expect(throws: ClientError.unsafeURL) { try server.endpoint(["Items", ".."]) }
        #expect(try server.endpoint(["Zorofin", "Web", "ui", "looks.json"]).path.hasSuffix("/Zorofin/Web/ui/looks.json"))
    }
}

@Suite("Jellyfin wire contract") struct ClientTests {
    @Test func serverDiscoveryDoesNotSendAnExistingAccountsToken() async throws {
        let transport = StubTransport([(200, "{\"Id\":\"server-id\",\"ServerName\":\"Fixture server\",\"Version\":\"10.11.11\"}")])
        let result = try await client(transport).systemInfo()
        #expect(result.serverName == "Fixture server")
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.path == "/jellyfin/System/Info/Public")
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].httpBody == nil)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
    }
    @Test(arguments: ["{}", "{\"Id\":\"\"}", "{\"Id\":\"  \"}"])
    func unrelatedJSONDoesNotCountAsAConnectedServer(_ body: String) async {
        let transport = StubTransport([(200, body)])
        await #expect(throws: ClientError.invalidResponse) { try await client(transport).systemInfo() }
    }

    @Test func credentialsCannotFollowAClientToAnotherServer() async throws {
        let transport = StubTransport([])
        let other = try ServerAddress("https://other.example")
        let misplaced = JellyfinClient(server: other, identity: identity, session: client(transport).session, transport: transport)
        await #expect(throws: ClientError.unsafeURL) { try await misplaced.currentViewer() }
        #expect(await transport.requests.isEmpty)
    }
    @Test func loginUsesModernHeaderAndBody() async throws {
        let transport = StubTransport([(200, "{\"AccessToken\":\"new\",\"User\":{\"Id\":\"u\",\"Name\":\"Viewer\"}}")])
        let unauthenticated = JellyfinClient(server: server, identity: identity, transport: transport)
        let result = try await unauthenticated.login(username: "viewer", password: "fixture-password")
        #expect(result.viewer.name == "Viewer")
        let request = await transport.requests[0]
        #expect(request.url?.path == "/jellyfin/Users/AuthenticateByName")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("MediaBrowser Client=") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        #expect(body == ["Username": "viewer", "Pw": "fixture-password"])
        #expect(request.url?.query == nil)
    }
    @Test func resumeUsesVersionedSupportedRoute() async throws {
        let transport = StubTransport([(200, "{\"Items\":[],\"TotalRecordCount\":0}")])
        _ = try await client(transport).resume()
        let request = await transport.requests[0]
        #expect(request.url?.path == "/jellyfin/UserItems/Resume")
        #expect(request.url?.query?.contains("limit=20") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
        #expect(request.url?.absoluteString.contains("fixture-token") == false)
    }
    @Test func decodingRetainsImageDictionaryKeysAndOptionalFields() throws {
        let data = Data("{\"Id\":\"movie\",\"Name\":\"North\",\"ImageTags\":{\"Primary\":\"tag\"},\"UserData\":{\"PlaybackPositionTicks\":120000000}}".utf8)
        let item = try Wire.decoder().decode(MediaItem.self, from: data)
        #expect(item.imageTags?["Primary"] == "tag")
        #expect(item.resumeTicks == 120_000_000)
        #expect(item.overview == nil)
    }
    @Test func sessionExpiryIsActionableAndRedacted() async throws {
        let transport = StubTransport([(401, "secret server diagnostic")])
        await #expect(throws: ClientError.unauthorized) { try await client(transport).currentViewer() }
        #expect(ClientError.unauthorized.localizedDescription.contains("secret") == false)
    }
    @Test func headerValuesCannotInjectHeaders() {
        let value = ClientIdentity(deviceID: "id\r\nX-Injected: yes", deviceName: "TV\"\\").authorization(token: "t\r\n")
        #expect(!value.contains("\r") && !value.contains("\n") && !value.contains("\\"))
    }
    @Test func quickConnectUsesSecretAndNoSessionToken() async throws {
        let transport = StubTransport([(200, "{\"Authenticated\":false,\"Secret\":\"temporary\",\"Code\":\"123456\"}")])
        let result = try await client(transport).quickConnectState(secret: "temporary")
        #expect(result.code == "123456")
        let request = await transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=") == false)
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?.queryItems?.first?.value == "temporary")
    }
}

@Suite("Playback negotiation and lifecycle") struct PlaybackTests {
    private func info(_ source: String) throws -> PlaybackInfo {
        try Wire.decoder().decode(PlaybackInfo.self, from: Data("{\"PlaySessionId\":\"play-session\",\"MediaSources\":[\(source)]}".utf8))
    }
    @Test func directPlayUsesServerStreamRoute() throws {
        let info = try info("{\"Id\":\"source\",\"SupportsDirectPlay\":true}")
        let plan = try PlaybackPlan.make(info: info, itemID: "movie", client: client(StubTransport([])), options: .init())
        #expect(plan.method == "DirectPlay")
        #expect(plan.url.path == "/jellyfin/Videos/movie/stream")
        #expect(plan.url.query?.contains("ApiKey=fixture-token") == true)
    }
    private func hlsPlan(_ query: String, subtitle: Int = -1) throws -> PlaybackPlan {
        let info = try info(#"{"Id":"source","SupportsTranscoding":true,"TranscodingSubProtocol":"hls","TranscodingUrl":"/jellyfin/Videos/movie/master.m3u8?\#(query)"}"#)
        return try PlaybackPlan.make(info: info, itemID: "movie", client: client(StubTransport([])),
                                     options: .init(subtitleIndex: subtitle))
    }
    @Test func remuxIsNotLabelledAsTranscoding() throws {
        #expect(try hlsPlan("TranscodeReasons=ContainerNotSupported").deliveryDescription == "Remux (original video)")
        #expect(try hlsPlan("TranscodeReasons=ContainerNotSupported,AudioCodecNotSupported").copiesVideo)
        // Text subtitles in the manifest still copy the video; burned-in ones do not.
        #expect(try hlsPlan("TranscodeReasons=ContainerNotSupported,SubtitleCodecNotSupported&SubtitleMethod=Hls", subtitle: 3).copiesVideo)
        #expect(try !hlsPlan("TranscodeReasons=ContainerNotSupported,SubtitleCodecNotSupported&SubtitleMethod=Encode", subtitle: 3).copiesVideo)
        #expect(try !hlsPlan("TranscodeReasons=ContainerNotSupported,SubtitleCodecNotSupported", subtitle: 3).copiesVideo)
        #expect(try hlsPlan("TranscodeReasons=VideoCodecNotSupported").deliveryDescription == "Transcoding")
        #expect(try !hlsPlan("TranscodeReasons=ContainerNotSupported,ContainerBitrateExceedsLimit").copiesVideo)
        #expect(try !hlsPlan("PlaySessionId=x").copiesVideo)
    }
    @Test func manifestSubtitleSwitchKeepsThePlaySession() throws {
        let plan = try hlsPlan("TranscodeReasons=ContainerNotSupported&SubtitleMethod=Hls", subtitle: 3)
        let off = plan.selectingSubtitle(-1)
        #expect(off.options.subtitleIndex == -1 && off.sessionID == plan.sessionID && off.url == plan.url)
        #expect(off.report(positionTicks: 1, paused: false, canSeek: true)["SubtitleStreamIndex"] == .int(-1))
    }
    @Test func manifestSubtitleMatchUsesUniqueTextTracks() throws {
        let streams = try Wire.decoder().decode([MediaStream].self, from: Data(#"""
        [{"Index":2,"Type":"Subtitle","Codec":"subrip","DisplayTitle":"English - SUBRIP - External"},
         {"Index":3,"Type":"Subtitle","Codec":"subrip","DisplayTitle":"English - SUBRIP"},
         {"Index":4,"Type":"Subtitle","Codec":"PGSSUB","DisplayTitle":"English - PGSSUB"},
         {"Index":5,"Type":"Subtitle","Codec":"ass","DisplayTitle":"Signs"},
         {"Index":6,"Type":"Subtitle","Codec":"ass","DisplayTitle":"Signs"}]
        """#.utf8))
        let names = ["English - SUBRIP - External", "English - SUBRIP", "Signs", "Signs"]
        #expect(ManifestSubtitleMatch.choice(for: -1, streams: streams, optionNames: names) == .off)
        #expect(ManifestSubtitleMatch.choice(for: 3, streams: streams, optionNames: names) == .option(1))
        #expect(ManifestSubtitleMatch.choice(for: 2, streams: streams, optionNames: names) == .option(0))
        // Image subtitles need a burn-in stream; ambiguous names renegotiate.
        #expect(ManifestSubtitleMatch.choice(for: 4, streams: streams, optionNames: names + ["English - PGSSUB"]) == nil)
        #expect(ManifestSubtitleMatch.choice(for: 5, streams: streams, optionNames: names) == nil)
        #expect(ManifestSubtitleMatch.choice(for: 9, streams: streams, optionNames: names) == nil)
    }
    @Test func remuxNegotiationPreservesSelectedSourceAndHLSDownload() async throws {
        // A remux-enabled, video-transcoding-disabled viewer can receive HLS
        // with SupportsDirectStream=false after successful profile selection.
        let response = #"""
        {"PlaySessionId":"play","MediaSources":[{"Id":"chosen-source","Container":"mkv","SupportsDirectPlay":false,"SupportsDirectStream":false,"SupportsTranscoding":true,"TranscodingSubProtocol":"hls","TranscodingUrl":"/jellyfin/Videos/movie/master.m3u8?api_key=old&TranscodeReasons=ContainerNotSupported"}]}
        """#
        let transport = StubTransport([(200, response)])
        let current = client(transport)
        let options = PlaybackOptions(bitrate: 8_000_000)
        let info = try await current.playbackInfo(itemID: "movie", options: options, sourceID: "chosen-source")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/jellyfin/Items/movie/PlaybackInfo")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
        #expect(request.url?.absoluteString.contains("fixture-token") == false)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["MediaSourceId"] as? String == "chosen-source")
        #expect(body["EnableDirectStream"] as? Bool == true)
        #expect(body["EnableDirectPlay"] as? Bool == true)
        #expect(body["AllowVideoStreamCopy"] as? Bool == true)
        #expect(body["MaxStreamingBitrate"] as? Int == 8_000_000)
        let profile = try #require(body["DeviceProfile"] as? [String: Any])
        let conversions = try #require(profile["TranscodingProfiles"] as? [[String: Any]])
        #expect(!conversions.isEmpty && conversions.allSatisfy { $0["Protocol"] as? String == "hls" })
        #expect(info.mediaSources?.first?.supportsDirectStream == false)
        let plan = try PlaybackPlan.make(info: info, itemID: "movie", client: current, options: options)
        let download = try DownloadPlan.make(info: info, itemID: "movie", client: current, options: options)
        #expect(plan.sourceID == "chosen-source" && plan.method == "Transcode")
        #expect(plan.url.path == "/jellyfin/Videos/movie/master.m3u8")
        #expect(download.method == .stream && download.url == plan.url)
        let query = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(.init(name: "ApiKey", value: "fixture-token")))
        #expect(!query.contains { $0.name == "api_key" })
    }
    @Test func acceptsTheServerHLSPlanForARemuxOnlyViewer() throws {
        let info = try info(#"{"Id":"source","SupportsTranscoding":false,"SupportsDirectStream":true,"TranscodingUrl":"/jellyfin/Videos/movie/master.m3u8?TranscodeReasons=ContainerNotSupported"}"#)
        let plan = try PlaybackPlan.make(info: info, itemID: "movie", client: client(StubTransport([])), options: .init())
        #expect(plan.url.path.hasSuffix("/master.m3u8"))
        #expect(plan.copiesVideo)
    }
    @Test(arguments: [true, false])
    func remuxPermissionDoesNotMakeHTTPConversionPlayableOrDownloadable(_ supportsTranscoding: Bool) throws {
        let info = try info(#"{"Id":"source","SupportsDirectPlay":false,"SupportsDirectStream":true,"SupportsTranscoding":\#(supportsTranscoding),"TranscodingSubProtocol":"http","TranscodingUrl":"/jellyfin/Videos/movie/stream?TranscodeReasons=ContainerNotSupported"}"#)
        let current = client(StubTransport([]))
        #expect(throws: ClientError.unsupportedPlayback) {
            try PlaybackPlan.make(info: info, itemID: "movie", client: current, options: .init())
        }
        #expect(throws: ClientError.unsupportedPlayback) {
            try DownloadPlan.make(info: info, itemID: "movie", client: current, options: .init())
        }
    }
    @Test func discoversSourceBeforeNegotiatingTrackSelection() async throws {
        let transport = StubTransport([
            (200, "{\"PlaySessionId\":\"discovery\",\"MediaSources\":[{\"Id\":\"different-source\"}]}"),
            (200, "{\"PlaySessionId\":\"play\",\"MediaSources\":[{\"Id\":\"different-source\",\"SupportsDirectPlay\":true}]}")])
        _ = try await client(transport).playbackInfo(itemID: "movie", options: .init())
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        #expect(body["MediaSourceId"] as? String == "different-source")
        #expect(body["SubtitleStreamIndex"] as? Int == -1)
        #expect(requests[1].value(forHTTPHeaderField: "X-Emby-Token") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
    }
    @Test func knownSourceKeepsTrackSelectionOnThatVersion() async throws {
        let transport = StubTransport([(200, "{\"PlaySessionId\":\"play\",\"MediaSources\":[{\"Id\":\"chosen-version\"}]}")])
        _ = try await client(transport).playbackInfo(itemID: "movie", options: .init(audioIndex: 2, subtitleIndex: 3), sourceID: "chosen-version")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        #expect(body["MediaSourceId"] as? String == "chosen-version")
        #expect(body["AudioStreamIndex"] as? Int == 2)
        #expect(body["SubtitleStreamIndex"] as? Int == 3)
        #expect(body["EnableDirectStream"] as? Bool == true)
        #expect(body["EnableDirectPlay"] as? Bool == false)
    }
    @Test func liveChannelIgnoresPlaceholderDetailSource() async throws {
        let channel = try Wire.decoder().decode(MediaItem.self, from: Data(#"{"Id":"channel","Name":"Live channel","Type":"TvChannel","MediaSources":[{"Id":"placeholder-file-source","Protocol":"File"}]}"#.utf8))
        let transport = StubTransport([
            (200, #"{"PlaySessionId":"discovery","MediaSources":[{"Id":"current-tuner-source","RequiresOpening":true,"OpenToken":"fixture-open"}]}"#),
            (200, #"{"PlaySessionId":"play","MediaSources":[{"Id":"current-tuner-source","RequiresOpening":true,"OpenToken":"fixture-open"}]}"#)])
        _ = try await client(transport).playbackInfo(for: channel, options: .init(subtitleIndex: -2))
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        #expect(body["MediaSourceId"] as? String == "current-tuner-source")
        #expect(body["AutoOpenLiveStream"] as? Bool == false)
        #expect(body["EnableDirectStream"] as? Bool == true)
    }
    @Test func movieDetailKeepsItsChosenVersion() async throws {
        let movie = try Wire.decoder().decode(MediaItem.self, from: Data(#"{"Id":"movie","Name":"Movie","Type":"Movie","MediaSources":[{"Id":"chosen-version"}]}"#.utf8))
        let transport = StubTransport([(200, #"{"PlaySessionId":"play","MediaSources":[{"Id":"chosen-version"}]}"#)])
        _ = try await client(transport).playbackInfo(for: movie, options: .init(audioIndex: 2))
        let requests = await transport.requests
        #expect(requests.count == 1)
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        #expect(body["MediaSourceId"] as? String == "chosen-version")
        #expect(body["AudioStreamIndex"] as? Int == 2)
    }
    @Test func missingSourceFailsBeforeNegotiation() async throws {
        let transport = StubTransport([(200, "{\"MediaSources\":[]}")])
        await #expect(throws: ClientError.unsupportedPlayback) {
            try await client(transport).playbackInfo(itemID: "movie", options: .init())
        }
        #expect(await transport.requests.count == 1)
    }
    @Test func selectedSubtitleForcesNegotiatedHLS() throws {
        let info = try info("{\"Id\":\"source\",\"SupportsDirectPlay\":true,\"SupportsTranscoding\":true,\"TranscodingUrl\":\"/jellyfin/Videos/movie/master.m3u8\"}")
        let options = PlaybackOptions(subtitleIndex: 3)
        let plan = try PlaybackPlan.make(info: info, itemID: "movie", client: client(StubTransport([])), options: options)
        #expect(plan.method == "Transcode")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PlaybackProfile.request(userID: "u", options: options))) as! [String: Any]
        #expect(body["EnableDirectPlay"] as? Bool == false)
        #expect(body["SubtitleStreamIndex"] as? Int == 3)
        #expect(body["IsPlayback"] == nil)
    }
    @Test func liveSourceMustBeOpenedBeforePlanning() throws {
        let unopened = try info("{\"Id\":\"source\",\"SupportsDirectPlay\":true,\"RequiresOpening\":true}")
        #expect(throws: ClientError.unsupportedPlayback) {
            try PlaybackPlan.make(info: unopened, itemID: "channel", client: client(StubTransport([])), options: .init())
        }
        let opened = try info("{\"Id\":\"source\",\"SupportsTranscoding\":true,\"TranscodingUrl\":\"/jellyfin/Videos/channel/master.m3u8\",\"RequiresOpening\":true,\"RequiresClosing\":true,\"LiveStreamId\":\"owned-stream\"}")
        let plan = try PlaybackPlan.make(info: opened, itemID: "channel", client: client(StubTransport([])), options: .init())
        #expect(plan.liveStreamID == "owned-stream")
        #expect(plan.requiresClosing)
        #expect(plan.method == "Transcode")
    }
    @Test func mediaPlanRejectsCrossServerSession() throws {
        let misplaced = JellyfinClient(server: try ServerAddress("https://other.example"), identity: identity,
            session: client(StubTransport([])).session)
        let info = try info("{\"Id\":\"source\",\"SupportsDirectPlay\":true}")
        #expect(throws: ClientError.unsafeURL) {
            try PlaybackPlan.make(info: info, itemID: "movie", client: misplaced, options: .init())
        }
    }
    @Test func noRawMediaPathFallback() throws {
        let info = try info("{\"Id\":\"source\",\"Path\":\"https://provider.example/secret\"}")
        #expect(throws: ClientError.unsupportedPlayback) {
            try PlaybackPlan.make(info: info, itemID: "movie", client: client(StubTransport([])), options: .init())
        }
    }
    @Test func reportsAreOrderedAndStopIsFinal() async throws {
        let transport = StubTransport([], delay: .milliseconds(10))
        let client = client(transport)
        let info = try info("{\"Id\":\"source\",\"SupportsDirectPlay\":true,\"RequiresClosing\":true,\"LiveStreamId\":\"owned-stream\"}")
        let plan = try PlaybackPlan.make(info: info, itemID: "movie", client: client, options: .init())
        let reporter = PlaybackReporter(client: client, plan: plan)
        await reporter.start(positionTicks: 0, canSeek: true)
        await reporter.start(positionTicks: 0, canSeek: true)
        await reporter.progress(positionTicks: 50, paused: false, canSeek: true)
        await reporter.stop(positionTicks: 60)
        await reporter.progress(positionTicks: 70, paused: true, canSeek: true)
        await reporter.stop(positionTicks: 80)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/jellyfin/Sessions/Playing", "/jellyfin/Sessions/Playing/Progress", "/jellyfin/Sessions/Playing/Stopped", "/jellyfin/LiveStreams/Close"])
        let stop = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: Any]
        #expect(stop["PositionTicks"] as? Int == 60)
        #expect(requests[3].url?.query == "liveStreamId=owned-stream")
    }
    @Test func failedTranscodeStartEndsItsServerEncode() async throws {
        let transport = StubTransport([])
        let client = client(transport)
        let info = try info("{\"Id\":\"source\",\"SupportsTranscoding\":true,\"TranscodingUrl\":\"/jellyfin/Videos/episode/master.m3u8\"}")
        let plan = try PlaybackPlan.make(info: info, itemID: "episode", client: client, options: .init(startTicks: 15_000_000_000, subtitleIndex: 3))
        let reporter = PlaybackReporter(client: client, plan: plan)
        await reporter.stop(positionTicks: 0, failed: true)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/jellyfin/Videos/ActiveEncodings"])
        #expect(requests.first?.httpMethod == "DELETE")
        #expect(requests.first?.url?.query?.contains("playSessionId=play-session") == true)
    }
    @Test func finishedTranscodeReportsStopBeforeEndingItsEncode() async throws {
        let transport = StubTransport([])
        let client = client(transport)
        let info = try info("{\"Id\":\"source\",\"SupportsTranscoding\":true,\"TranscodingUrl\":\"/jellyfin/Videos/episode/master.m3u8\"}")
        let plan = try PlaybackPlan.make(info: info, itemID: "episode", client: client, options: .init(subtitleIndex: 3))
        let reporter = PlaybackReporter(client: client, plan: plan)
        await reporter.start(positionTicks: 0, canSeek: true)
        await reporter.stop(positionTicks: 50)
        await reporter.stop(positionTicks: 60)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/jellyfin/Sessions/Playing", "/jellyfin/Sessions/Playing/Stopped", "/jellyfin/Videos/ActiveEncodings"])
    }
    @Test func directPlayStopDoesNotTouchEncodes() async throws {
        let transport = StubTransport([])
        let client = client(transport)
        let plan = try PlaybackPlan.make(info: info("{\"Id\":\"source\",\"SupportsDirectPlay\":true}"), itemID: "movie", client: client, options: .init())
        await PlaybackReporter(client: client, plan: plan).stop(positionTicks: 0, failed: true)
        #expect(await transport.requests.isEmpty)
    }
    @Test func onlyTranscodedResumesGetTheLongerPreparationWindow() {
        #expect(PlayerPreparation.timeout(method: "Transcode", isLive: false, startSeconds: 1553) == .seconds(75))
        #expect(PlayerPreparation.timeout(method: "Transcode", isLive: false, startSeconds: 0) == .seconds(30))
        #expect(PlayerPreparation.timeout(method: "Transcode", isLive: true, startSeconds: 10) == .seconds(30))
        #expect(PlayerPreparation.timeout(method: "DirectPlay", isLive: false, startSeconds: 1553) == .seconds(30))
        #expect(PlayerPreparation.timeout(method: "Transcode", isLive: false, startSeconds: .nan) == .seconds(30))
    }
    @Test func transientStopRetriesKeepTheFinalPositionAndAccount() async throws {
        let transport = StubTransport([(503, ""), (502, ""), (204, "")])
        try await client(transport).reportPlayback("stop", payload: ["ItemId": .string("episode"), "PositionTicks": .int(3600000000)])
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(Set(requests.compactMap(\.httpBody)).count == 1)
        #expect(requests.allSatisfy { $0.url?.absoluteString == "https://media.example/jellyfin/Sessions/Playing/Stopped" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true })
    }
    @Test func exhaustedStopRetriesRemainAFailure() async {
        let transport = StubTransport([(503, ""), (503, ""), (503, "")])
        await #expect(throws: ClientError.unavailable(503)) {
            try await client(transport).reportPlayback("stop", payload: [:])
        }
        #expect(await transport.requests.count == 3)
    }
    @Test(arguments: [401, 403, 400, 500]) func stopDoesNotRetryPermanentFailures(_ status: Int) async {
        let transport = StubTransport([(status, "")])
        await #expect(throws: (any Error).self) {
            try await client(transport).reportPlayback("stop", payload: [:])
        }
        #expect(await transport.requests.count == 1)
    }
    @Test func progressDoesNotRetryServerFailure() async {
        let transport = StubTransport([(503, "")])
        await #expect(throws: ClientError.unavailable(503)) {
            try await client(transport).reportPlayback("progress", payload: [:])
        }
        #expect(await transport.requests.count == 1)
    }
    @Test func timeConversionRejectsNonFiniteValues() {
        #expect(MediaTime.ticks(seconds: .nan) == 0)
        #expect(MediaTime.ticks(seconds: .infinity) == 0)
        #expect(MediaTime.ticks(seconds: -2) == 0)
        #expect(MediaTime.ticks(seconds: 1.25) == 12_500_000)
        #expect(MediaTime.seconds(ticks: 12_500_000) == 1.25)
    }
    @Test func slowReportsCoalesceProgressWithoutLosingStop() async throws {
        let transport = StubTransport([], delay: .milliseconds(20))
        let client = client(transport)
        let plan = try PlaybackPlan.make(info: info("{\"Id\":\"source\",\"SupportsDirectPlay\":true}"), itemID: "movie", client: client, options: .init())
        let reporter = PlaybackReporter(client: client, plan: plan)
        await reporter.start(positionTicks: 0, canSeek: true)
        for position in 1...100 { await reporter.progress(positionTicks: Int64(position), paused: false, canSeek: true) }
        await reporter.stop(positionTicks: 101)
        let requests = await transport.requests
        #expect(requests.count <= 4)
        #expect(requests.last?.url?.path == "/jellyfin/Sessions/Playing/Stopped")
        let payload = try JSONSerialization.jsonObject(with: requests.last!.httpBody!) as! [String: Any]
        #expect(payload["PositionTicks"] as? Int == 101)
    }
}
