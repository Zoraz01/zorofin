import Foundation
import Testing
@testable import ZorofinCore

private let server = try! ServerAddress("https://media.example/jellyfin")
private let identity = ClientIdentity(deviceID: "fixture-device", deviceName: "Test Device")
private let viewer = Viewer(id: "00000000000000000000000000000001", name: "Fixture Viewer")

private struct NoTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ClientError.unsupportedPlayback }
}

private let client = JellyfinClient(server: server, identity: identity,
    session: Session(server: server, viewer: viewer, token: "fixture-token", deviceID: identity.deviceID), transport: NoTransport())

@Suite("On-device playback for files AVPlayer can't take") struct OnDevicePlaybackTests {
    private func plan(reasons: String, video: String = "hevc", range: String = "HDR10", audio: String = "truehd",
                      subtitle: (Int, String, Bool)? = nil, bitrate: Int = 30_000_000,
                      options: PlaybackOptions = .init()) throws -> (PlaybackPlan, MediaSource) {
        var streams = [#"{"Index":0,"Type":"Video","Codec":"\#(video)","VideoRangeType":"\#(range)"}"#,
                       #"{"Index":1,"Type":"Audio","Codec":"\#(audio)","Channels":8}"#]
        if let (index, codec, external) = subtitle {
            streams.append(#"{"Index":\#(index),"Type":"Subtitle","Codec":"\#(codec)","Language":"eng","IsExternal":\#(external)}"#)
        }
        let source = #"{"Id":"source","Container":"mkv","Bitrate":\#(bitrate),"SupportsTranscoding":true,"TranscodingSubProtocol":"hls","TranscodingUrl":"/jellyfin/videos/movie/master.m3u8?TranscodeReasons=\#(reasons)","MediaStreams":[\#(streams.joined(separator: ","))]}"#
        let info = try Wire.decoder().decode(PlaybackInfo.self, from: Data(#"{"PlaySessionId":"play","MediaSources":[\#(source)]}"#.utf8))
        let plan = try PlaybackPlan.make(info: info, itemID: "movie", client: client, options: options)
        return (plan, info.mediaSources![0])
    }

    @Test func takesTrueHDAndPGSFilesTheServerWouldConvert() throws {
        var options = PlaybackOptions(); options.subtitleIndex = 2
        let (plan, source) = try plan(reasons: "AudioCodecNotSupported,SubtitleCodecNotSupported",
                                      subtitle: (2, "PGSSUB", false), options: options)
        #expect(OnDevicePlayback.shouldUse(plan: plan, source: source, isLive: false, hardwareHEVC: true, maxBitrate: 120_000_000))
        let request = try OnDevicePlayback.request(plan: plan, source: source, client: client)
        #expect(request.subtitle == .embeddedPGS(2, extractionPath: ["Videos", "movie", "source", "Subtitles", "2", "0", "Stream.pgssub"], language: "eng"))
        #expect(request.url.path == "/jellyfin/Videos/movie/stream")
        #expect(request.url.query?.contains("static=true") == true)
        #expect(request.url.query?.lowercased().contains("api_key") == false)
        #expect(request.headers["Authorization"]?.contains("fixture-token") == true)
        let reported = plan.playedOnDevice(url: request.url)
        #expect(reported.method == "DirectPlay" && reported.sessionID == "play")
        #expect(reported.report(positionTicks: 0, paused: false, canSeek: true)["SubtitleStreamIndex"] == .int(2))
    }

    @Test func textEmbeddedSubtitlesKeepOnlyTheInFileReader() throws {
        let (plan, source) = try plan(reasons: "ContainerNotSupported", subtitle: (3, "ass", false))
        #expect(try OnDevicePlayback.subtitle(3, plan: plan, source: source, server: server) == .embedded(3))
        #expect(try OnDevicePlayback.subtitle(-1, plan: plan, source: source, server: server) == .off)
    }

    @Test func bitmapTransferUsesOriginalStreamAndRejectsInvalidOrTruncatedData() async throws {
        struct Response: HTTPTransport {
            let data: Data
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let url = try #require(request.url)
                #expect(url.path == "/jellyfin/Videos/movie/source/Subtitles/3/0/Stream.pgssub")
                #expect(url.query == nil)
                #expect(request.value(forHTTPHeaderField: "Authorization") == identity.authorization(token: "fixture-token"))
                #expect(request.timeoutInterval == 90)
                return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])))
            }
        }
        let path = ["Videos", "movie", "source", "Subtitles", "3", "0", "Stream.pgssub"]
        let segment = Data([0x50, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0x80, 0, 0])
        let file = try await client.preparePGSFile(path: path, transport: Response(data: segment))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(file.pathExtension == "sup")
        #expect(try Data(contentsOf: file) == segment)
        for bad in [Data("<html>error</html>".utf8), segment.dropLast(), segment.dropLast() + [1]] {
            await #expect(throws: ClientError.invalidResponse) {
                _ = try await client.preparePGSFile(path: path, transport: Response(data: bad))
            }
        }
    }

    @Test func externalSubtitlesComeFromJellyfinsSubtitleRoute() throws {
        var options = PlaybackOptions(); options.subtitleIndex = 3
        let (plan, source) = try plan(reasons: "ContainerNotSupported", subtitle: (3, "ass", true), options: options)
        let request = try OnDevicePlayback.request(plan: plan, source: source, client: client)
        guard case .external(let url, let language) = request.subtitle else { Issue.record("expected sidecar"); return }
        #expect(url.path == "/jellyfin/Videos/movie/source/Subtitles/3/0/Stream.ass")
        #expect(language == "eng")
    }

    @Test(arguments: [
        ("VideoCodecNotSupported", "hevc", "HDR10", true, 30_000_000, false),         // a real video encode
        ("ContainerBitrateExceedsLimit", "hevc", "HDR10", true, 30_000_000, false),   // quality cap
        ("AudioCodecNotSupported", "hevc", "HDR10", false, 30_000_000, false),        // no hardware HEVC
        ("AudioCodecNotSupported", "vc1", "SDR", true, 30_000_000, false),            // video AVPlayer can't decode
        ("AudioCodecNotSupported", "hevc", "DOVIWithEL", true, 30_000_000, false),    // Dolby Vision profile 7
        ("AudioCodecNotSupported", "hevc", "HDR10", true, 200_000_000, false),        // above the viewer's limit
        ("", "hevc", "HDR10", true, 30_000_000, false),                               // no reasons given
        ("AudioCodecNotSupported", "h264", "SDR", false, 30_000_000, true),
    ])
    func keepsTheServerPathForEverythingElse(_ reasons: String, _ video: String, _ range: String,
                                             _ hevc: Bool, _ bitrate: Int, _ expected: Bool) throws {
        let (plan, source) = try plan(reasons: reasons, video: video, range: range, bitrate: bitrate)
        #expect(OnDevicePlayback.shouldUse(plan: plan, source: source, isLive: false, hardwareHEVC: hevc,
                                           maxBitrate: 120_000_000) == expected)
    }

    @Test func neverTakesLiveTV() throws {
        let (plan, source) = try plan(reasons: "AudioCodecNotSupported")
        #expect(!OnDevicePlayback.shouldUse(plan: plan, source: source, isLive: true, hardwareHEVC: true, maxBitrate: 120_000_000))
    }
}
