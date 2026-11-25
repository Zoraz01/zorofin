import Foundation
import Testing
@testable import ZorofinCore

private func movie(_ id: String, type: String = "Movie", trailers: Int? = nil) -> MediaItem {
    var item = MediaItem(id: id, name: id, type: type); item.localTrailerCount = trailers; return item
}
private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
private let source = TrailerSource(trailerID: "trailer", url: URL(string: "https://media.example/Videos/trailer/stream.mp4")!)

@Suite("Trailer previews") struct TrailerPreviewTests {
    @Test func dwellLookupThenStartMuted() {
        var preview = PreviewCoordinator()
        #expect(preview.focus(movie("a"), at: t0).isEmpty && preview.phase == .waiting)
        #expect(preview.tick(at: at(0.5)).isEmpty)
        #expect(preview.tick(at: at(0.6)) == [.lookup(itemID: "a")])
        #expect(preview.tick(at: at(0.9)).isEmpty) // one lookup at a time
        #expect(preview.lookedUp("a", source: source, at: at(1.0)).isEmpty)
        #expect(preview.tick(at: at(2.0)) == [.start(source)])
        #expect(!preview.showsVideo)
        preview.firstFrame()
        #expect(preview.showsVideo && preview.muted && preview.hints == .playing)
    }

    @Test func movingOnStopsAtOnceAndNextTitleGetsItsOwnDwell() {
        var preview = PreviewCoordinator()
        _ = preview.focus(movie("a"), at: t0); _ = preview.tick(at: at(0.6))
        _ = preview.lookedUp("a", source: source, at: at(0.7)); _ = preview.tick(at: at(2)); preview.firstFrame()
        #expect(preview.focus(movie("b"), at: at(5)) == [.stop])
        #expect(preview.tick(at: at(6.9)) == [.lookup(itemID: "b")])
        _ = preview.lookedUp("b", source: source, at: at(6.95))
        #expect(preview.tick(at: at(6.99)).isEmpty && preview.tick(at: at(7)) == [.start(source)])
    }

    @Test func skimmingNeverLooksUp() {
        var preview = PreviewCoordinator()
        for (index, id) in ["a", "b", "c", "d", "e", "f"].enumerated() {
            _ = preview.focus(movie(id), at: at(Double(index) * 0.3))
            #expect(preview.tick(at: at(Double(index) * 0.3 + 0.29)).isEmpty)
        }
        #expect(preview.tick(at: at(1.5 + 0.6)) == [.lookup(itemID: "f")])
    }

    @Test func interactionRestartsTheDwell() {
        var preview = PreviewCoordinator()
        _ = preview.focus(movie("a"), at: t0)
        preview.interaction(at: at(0.5))
        #expect(preview.tick(at: at(0.9)).isEmpty && preview.tick(at: at(1.1)) == [.lookup(itemID: "a")])
    }

    @Test func manualPauseSticksForTheVisit() {
        var preview = PreviewCoordinator()
        _ = preview.focus(movie("a"), at: t0); _ = preview.lookedUp("a", source: source, at: t0)
        _ = preview.tick(at: at(2)); preview.firstFrame()
        #expect(preview.playPause(at: at(3)) == [.pause] && preview.hints == .paused)
        #expect(preview.tick(at: at(30)).isEmpty && preview.phase == .paused)
        _ = preview.focus(movie("b"), at: at(31))
        _ = preview.focus(movie("a"), at: at(32))
        #expect(preview.phase == .resting && preview.tick(at: at(40)).isEmpty && preview.hints == .replay)
        #expect(preview.playPause(at: at(41)) == [.stop, .start(source)])
        // Leaving Home clears the hold.
        _ = preview.stopAll(endVisit: true)
        _ = preview.focus(movie("a"), at: at(50))
        #expect(preview.phase == .waiting)
    }

    @Test func capEndsAndDoesNotLoop() {
        var preview = PreviewCoordinator()
        _ = preview.focus(movie("a"), at: t0); _ = preview.lookedUp("a", source: source, at: t0)
        _ = preview.tick(at: at(2)); preview.firstFrame()
        #expect(preview.progress(played: 29.9).isEmpty)
        #expect(preview.progress(played: 30) == [.stop] && preview.phase == .resting)
        #expect(preview.tick(at: at(60)).isEmpty)
    }

    @Test func noTrailerTimeoutAndIneligibleRowsKeepArtwork() {
        var preview = PreviewCoordinator()
        _ = preview.focus(movie("a"), at: t0); _ = preview.tick(at: at(0.6))
        #expect(preview.lookedUp("a", source: nil, at: at(0.7)).isEmpty && preview.phase == .resting)
        #expect(preview.playPause(at: at(3)).isEmpty && preview.hints == .details)
        _ = preview.focus(movie("b"), at: at(4)); _ = preview.lookedUp("b", source: source, at: at(4))
        #expect(preview.tick(at: at(6)) == [.start(source)])
        #expect(preview.tick(at: at(9)) == [.stop] && preview.phase == .resting) // no first frame in 3 s
        #expect(preview.focus(movie("ep", type: "Episode"), at: at(10)).isEmpty && preview.itemID == nil)
        #expect(preview.focus(movie("none", trailers: 0), at: at(11)).isEmpty && preview.itemID == nil)
    }

    @Test func autoplayOffStillPlaysOnPlayPause() {
        var preview = PreviewCoordinator(autoplay: false)
        _ = preview.focus(movie("a"), at: t0)
        #expect(preview.tick(at: at(5)).isEmpty && preview.hints == .playPreview)
        #expect(preview.playPause(at: at(5)) == [.lookup(itemID: "a")])
        #expect(preview.lookedUp("a", source: source, at: at(5.2)) == [.start(source)])
    }

    @Test func soundIsPerPreview() {
        var preview = PreviewCoordinator()
        _ = preview.focus(movie("a"), at: t0); _ = preview.lookedUp("a", source: source, at: t0)
        _ = preview.tick(at: at(2)); preview.firstFrame()
        #expect(preview.toggleSound() == false)
        _ = preview.focus(movie("b"), at: at(3))
        #expect(preview.muted)
    }

    @Test func compatibilityIsDirectPlayOnly() {
        func source(_ container: String, video: String, height: Int, audio: String) -> MediaSource {
            var value = MediaSource(); value.container = container
            var v = MediaStream(index: 0); v.type = "Video"; v.codec = video; v.height = height
            var a = MediaStream(index: 1); a.type = "Audio"; a.codec = audio
            value.mediaStreams = [v, a]; return value
        }
        #expect(TrailerPreview.compatible(source("mov,mp4,m4a", video: "h264", height: 720, audio: "aac")))
        #expect(!TrailerPreview.compatible(source("mkv", video: "h264", height: 720, audio: "aac")))
        #expect(!TrailerPreview.compatible(source("mp4", video: "vp9", height: 720, audio: "aac")))
        #expect(!TrailerPreview.compatible(source("mp4", video: "h264", height: 2160, audio: "aac")))
        #expect(!TrailerPreview.compatible(source("mp4", video: "h264", height: 720, audio: "dts")))
        #expect(!TrailerPreview.compatible(source("mp4", video: "hevc", height: 720, audio: "aac"), allowHEVC: false))
    }

    @Test func lookupUsesLocalTrailersAndNeverPlaybackRoutes() async throws {
        actor Transport: HTTPTransport {
            var paths: [String] = []
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                paths.append(request.url!.path)
                let body = request.url!.path.hasSuffix("LocalTrailers")
                    ? #"[{"Id":"t1","Name":"Trailer","Type":"Trailer"}]"#
                    : #"{"Id":"t1","Name":"Trailer","Type":"Trailer","MediaSources":[{"Id":"src","Container":"mp4","MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Height":720},{"Index":1,"Type":"Audio","Codec":"aac"},{"Index":2,"Type":"Subtitle","Codec":"srt"}]}]}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let transport = Transport()
        let server = try ServerAddress("https://media.example/base")
        let client = JellyfinClient(server: server, identity: .init(deviceID: "d", deviceName: "D"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "V"), token: "tok", deviceID: "d"), transport: transport)
        let found = try #require(try await client.previewTrailer(for: movie("m1")))
        #expect(found.url.path == "/base/Videos/t1/stream.mp4")
        #expect(found.url.query?.contains("static=true") == true && found.url.query?.contains("mediaSourceId=src") == true)
        #expect(found.subtitleURL?.path == "/base/Videos/t1/src/Subtitles/2/0/Stream.vtt")
        #expect(await transport.paths == ["/base/Items/m1/LocalTrailers", "/base/Items/t1"])
        #expect(try await client.previewTrailer(for: movie("ep", type: "Episode")) == nil)
    }
}
