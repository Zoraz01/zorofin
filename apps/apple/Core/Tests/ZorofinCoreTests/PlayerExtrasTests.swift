import Foundation
import Testing
@testable import ZorofinCore

@Suite("Chapters, scrub thumbnails and track memory") struct PlayerExtrasTests {
    @Test func chaptersAreSortedNumberedAndKeepTheirImageIndex() {
        let chapters = PlayerChapter.list(from: ["Chapters": [
            ["StartPositionTicks": 6_000_000_000, "Name": "The heist", "ImageTag": "b"],
            ["StartPositionTicks": 0, "Name": " "]]])
        #expect(chapters.map(\.name) == ["Chapter 1", "The heist"])
        #expect(chapters[1].start == 600 && chapters[1].imageIndex == 0)
        #expect(PlayerChapter.index(in: chapters, at: 599) == 0)
        #expect(PlayerChapter.index(in: chapters, at: 600) == 1)
        #expect(PlayerChapter.list(from: ["Chapters": [["StartPositionTicks": 0, "Name": "Only"]]]).isEmpty)
    }

    @Test func trickplayFindsTheFrameInItsSheet() throws {
        let tile: [String: Any] = ["Width": 320, "Height": 180, "TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 500, "Interval": 10_000]
        let small: [String: Any] = ["Width": 160, "Height": 90, "TileWidth": 10, "TileHeight": 10, "ThumbnailCount": 500, "Interval": 10_000]
        let info = try #require(Trickplay.best(from: ["Trickplay": ["source": ["160": small, "320": tile]]], mediaSourceID: "source"))
        #expect(info.width == 320)
        let frame = info.frame(at: 1234)
        #expect(frame.sheet == 1 && frame.row == 2 && frame.column == 3)
        #expect(info.frame(at: 99_999).sheet == 4)
        let url = try info.sheetURL(server: ServerAddress("https://media.example/jellyfin"), itemID: "item", sheet: 1, mediaSourceID: "source")
        #expect(url.path == "/jellyfin/Videos/item/Trickplay/320/1.jpg")
        #expect(url.query?.lowercased().contains("api_key") == false)
        #expect(Trickplay.best(from: ["Trickplay": [String: Any]()], mediaSourceID: nil) == nil)
    }

    @Test func trackMemoryFollowsLanguageForcedAndOff() throws {
        func stream(_ index: Int, _ type: String, _ language: String, forced: Bool = false) throws -> MediaStream {
            try Wire.decoder().decode(MediaStream.self, from: Data(#"{"Index":\#(index),"Type":"\#(type)","Language":"\#(language)","IsForced":\#(forced)}"#.utf8))
        }
        let streams = [try stream(1, "Audio", "eng"), try stream(2, "Audio", "jpn"),
                       try stream(3, "Subtitle", "eng", forced: true), try stream(4, "Subtitle", "eng")]
        var memory = TrackMemory().choosing(audio: streams[1], subtitle: streams[3])
        #expect(memory.pick(streams) == (2, 4))
        memory = try JSONDecoder().decode(TrackMemory.self, from: JSONEncoder().encode(memory))
        #expect(memory.pick(streams) == (2, 4))
        memory = memory.choosing(off: true)
        #expect(memory.pick(streams) == (2, -1))
        #expect(memory.pick([try stream(7, "Audio", "fra")]) == (nil, -1))
    }

    @Test func timingIsClampedAndLabelled() {
        #expect(TrackMemory.clamp(30) == 10)
        #expect(TrackMemory.clamp(-0.34) == -0.3)
        #expect(TrackMemory.label(0) == "In sync")
        #expect(TrackMemory.label(-0.3) == "−0.3 s")
    }
}
