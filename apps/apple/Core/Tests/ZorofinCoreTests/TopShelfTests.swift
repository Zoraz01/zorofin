import Foundation
import Testing
@testable import ZorofinCore

@Suite("Apple TV Home Screen previews") struct TopShelfTests {
    let id = "0123456789abcdef0123456789abcdef"
    func entry(_ id: String = "0123456789abcdef0123456789abcdef") -> TopShelfEntry {
        TopShelfEntry(item: MediaItem(id: id, name: "A film", overview: "<b>A story</b>"), continuing: false, imageName: UUID().uuidString + ".jpg")
    }
    @Test func actionsRoundTripWithoutCredentialsAndRejectForeignRoutes() throws {
        let account = UUID()
        for action in [TopShelfLink.Action.play, .details] {
            let link = try #require(TopShelfLink(accountID: account, itemID: id, action: action))
            #expect(TopShelfLink(url: link.url) == link)
            #expect(!link.url.absoluteString.contains("token"))
        }
        for raw in ["https://top-shelf/\(account)/\(id)?action=play", "zorofin://host/\(account)/\(id)?action=play",
                    "zorofin://top-shelf/\(account)/../?action=play", "zorofin://user@top-shelf/\(account)/\(id)?action=play",
                    "zorofin://top-shelf/\(account)/\(id)?action=play&ApiKey=secret", "zorofin://top-shelf/\(account)/\(id)?action=play#fragment"] {
            #expect(TopShelfLink(url: try #require(URL(string: raw))) == nil)
        }
        #expect(TopShelfLink(accountID: account, itemID: "../../secret", action: .play) == nil)
    }
    @Test func snapshotExpiryAndAccountAreExplicit() throws {
        let now = Date(), account = UUID(), value = entry()
        let snapshot = TopShelfSnapshot(accountID: account, entries: [value], now: now)
        let data = try JSONEncoder().encode(snapshot)
        let read = try JSONDecoder().decode(TopShelfSnapshot.self, from: data)
        #expect(read.accountID == account)
        #expect(read.isValid(at: now))
        #expect(!read.isValid(at: now.addingTimeInterval(TopShelfSnapshot.lifetime)))
        #expect(!read.isValid(at: now.addingTimeInterval(-61)))
        #expect(!TopShelfSnapshot(accountID: account, entries: [value, value]).isValid())
        #expect(value.summary == "A story")
    }
    @Test func cacheReplacementMissingArtworkAndSignOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TopShelfStore(root: root), first = entry(), second = entry()
        let a = TopShelfSnapshot(accountID: UUID(), entries: [first])
        try store.save(a, images: [first.imageName: Data([0xff,0xd8,0xff])])
        #expect(store.load()?.accountID == a.accountID)
        store.clear()
        #expect(store.load() == nil)
        let b = TopShelfSnapshot(accountID: UUID(), entries: [second])
        try store.save(b, images: [second.imageName: Data([0xff,0xd8,0xff])])
        #expect(store.load()?.accountID == b.accountID)
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(first).path))
        try FileManager.default.removeItem(at: store.imageURL(second))
        #expect(store.load() == nil)
    }
    @Test func unsafeArtworkNamesAndSymlinksAreRejected() throws {
        #expect(!TopShelfEntry.validImageName("../../secret.jpg"))
        #expect(!TopShelfEntry.validImageName("https://media.example/art.jpg"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TopShelfStore(root: root), value = entry()
        let snapshot = TopShelfSnapshot(accountID: UUID(), entries: [value])
        try store.save(snapshot, images: [value.imageName: Data([1])])
        try FileManager.default.removeItem(at: store.imageURL(value))
        try FileManager.default.createSymbolicLink(at: store.imageURL(value), withDestinationURL: root.appendingPathComponent("snapshot.json"))
        #expect(store.load() == nil)
        #expect(throws: ClientError.invalidResponse) { try store.save(snapshot, images: ["../bad": Data([1])]) }
    }
    @Test func resumeLeadsAndDuplicateShowsDoNotTakeOver() {
        var episode = MediaItem(id: id, name: "First", type: "Episode", userData: .init(playbackPositionTicks: 100))
        episode.seriesId = "series"
        var second = episode; second.id = "1123456789abcdef0123456789abcdef"
        let movie = MediaItem(id: "2123456789abcdef0123456789abcdef", name: "New film")
        let selection = TopShelfSelection.candidates(resume: [episode, second], movies: [episode, movie, movie])
        #expect(selection.map(\.item.id) == [episode.id, movie.id])
        #expect(selection.map(\.continuing) == [true, false])
    }
    @Test func unstartedNextEpisodeRemainsInContinueWatchingPreviews() {
        var next = MediaItem(id: id, name: "Next", type: "Episode", userData: .init(played: false))
        next.seriesId = "show"
        var watched = next; watched.id = "1123456789abcdef0123456789abcdef"; watched.userData?.played = true
        let movie = MediaItem(id: "2123456789abcdef0123456789abcdef", name: "New film")
        let selection = TopShelfSelection.candidates(resume: [next, watched, movie], movies: [movie])
        #expect(selection.map(\.item.id) == [next.id, movie.id])
        #expect(selection.map(\.continuing) == [true, false])
        #expect(selection[0].item.resumeTicks == 0)
    }
    @Test func existingPreferencesStillDecodeWithoutResettingQuality() throws {
        var value = NativePreferences(); value.bitrate = 8_000_000; value.showRatings = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        object.removeValue(forKey: "homeScreenPreviews")
        let saved = try JSONDecoder().decode(NativePreferences.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(saved.homeScreenPreviews == nil && saved.bitrate == 8_000_000 && saved.showRatings)
        value.homeScreenPreviews = false
        #expect(try JSONDecoder().decode(NativePreferences.self, from: JSONEncoder().encode(value)).homeScreenPreviews == false)
    }
}
