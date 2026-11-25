import Foundation
import Testing
@testable import ZorofinCore

@Suite("Who's watching backdrop") struct ProfileSpotlightTests {
    private func episode(_ id: String, backdrop: String? = nil, still: String? = nil) -> MediaItem {
        var item = MediaItem(id: id, name: "The Long Dark", type: "Episode",
            userData: .init(playbackPositionTicks: 300))
        item.seriesName = "Northbound"; item.parentIndexNumber = 2; item.indexNumber = 4
        item.runTimeTicks = 1_000
        if let backdrop { item.parentBackdropItemId = "show"; item.parentBackdropImageTags = [backdrop] }
        if let still { item.imageTags = ["Primary": still] }
        return item
    }

    @Test func showBackdropLeadsAndStillIsTheThumbnail() throws {
        let spot = try #require(ProfileSpotlight.pick(from: [episode("e1", backdrop: "b", still: "s")]))
        #expect(spot.title == "Northbound")
        #expect(spot.detail == "S2 E4 · The Long Dark")
        #expect(spot.backdrop == .init(itemID: "show", kind: "Backdrop", tag: "b"))
        #expect(spot.thumbnail == .init(itemID: "e1", kind: "Primary", tag: "s"))
        #expect(spot.progress == 0.3)
    }

    @Test func firstItemWithArtWinsOverEarlierItemWithout() throws {
        let spot = try #require(ProfileSpotlight.pick(from: [episode("bare"), episode("art", backdrop: "b")]))
        #expect(spot.itemID == "art")
    }

    @Test func noArtStillNamesTheTitleAndEmptyFeedIsNil() throws {
        #expect(ProfileSpotlight.pick(from: []) == nil)
        let spot = try #require(ProfileSpotlight.pick(from: [episode("bare")]))
        #expect(spot.backdrop == nil && spot.title == "Northbound")
    }

    @Test func storeRoundTripsPrunesAndRemoves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProfileSpotlightStore(directory: dir)
        let kept = UUID(), dropped = UUID()
        let spot = try #require(ProfileSpotlight.pick(from: [episode("e", backdrop: "b")]))
        store.save(spot, for: kept); store.save(spot, for: dropped)
        store.saveImage(Data([1, 2, 3]), for: kept); store.saveImage(Data([4]), for: dropped)
        #expect(store.loadImage(kept, tag: "show-Backdrop-b") == Data([1, 2, 3]))
        #expect(store.loadImage(kept, tag: "stale") == nil)
        #expect(store.load(kept) == spot)
        store.prune(keeping: [kept])
        #expect(store.load(dropped) == nil && store.load(kept) == spot)
        #expect(store.loadImage(dropped, tag: "show-Backdrop-b") == nil)
        store.save(nil, for: kept)
        #expect(store.load(kept) == nil)
    }

    @Test func sceneAvatarIsStableAndCaseInsensitive() {
        let id = "8C5A3F2E9B6D4E1FA0B2C3D4E5F60718"
        #expect(SceneAvatar.name(for: id) == SceneAvatar.name(for: id.lowercased()))
        // Matches the Flutter/LG/Roku implementations (sum of bytes mod 7).
        #expect(SceneAvatar.name(for: "a") == SceneAvatar.names[97 % 7])
    }
}
