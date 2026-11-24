import Foundation
import Testing
@testable import ZorofinCore

@Suite("Client-side Home banner") struct HomeBannerTests {
    private func title(_ id: String, type: String = "Movie", backdrop: Bool = false, poster: Bool = true) -> MediaItem {
        var item = MediaItem(id: id, name: "Title " + id, type: type)
        item.imageTags = poster ? ["Primary": "poster-" + id] : nil
        item.backdropImageTags = backdrop ? ["backdrop-" + id] : nil
        return item
    }

    @Test func ordinaryLibraryPrefersWidescreenArtworkWithoutAnExtension() {
        var banner = HomeBanner()
        banner.update([title("poster"), title("backdrop", backdrop: true)])
        #expect(banner.item?.id == "backdrop")
    }

    @Test func showsOnlyAndDiscoveryOnlyLibrariesStillHaveABanner() {
        var banner = HomeBanner()
        banner.update([title("show", type: "Series", backdrop: true)])
        #expect(banner.item?.id == "show")
        banner.update([title("discovery", backdrop: true)])
        #expect(banner.item?.id == "discovery")
    }

    @Test func posterOnlyAndMissingImagesStillUseTheRealLibraryTitle() {
        var banner = HomeBanner()
        banner.update([title("poster")])
        #expect(banner.item?.id == "poster")
        banner.update([title("no-art", poster: false)])
        #expect(banner.item?.id == "no-art")
    }

    @Test func loadingAndReorderingShelvesKeepsTheFeatureAndRefreshesItsMetadata() {
        var banner = HomeBanner()
        let chosen = title("chosen", backdrop: true)
        banner.update([chosen])
        var updated = chosen
        updated.userData = UserData(playbackPositionTicks: 120_000_000)
        banner.update((0..<10).map { title("new-arrival-\($0)", backdrop: true) } + [updated])
        #expect(banner.item?.id == chosen.id)
        #expect(banner.item?.resumeTicks == 120_000_000)
    }

    @Test func betterArtworkReplacesAPlaceholderButAnEqualCandidateDoesNot() {
        var banner = HomeBanner()
        banner.update([title("placeholder", poster: false)])
        banner.update([title("placeholder", poster: false), title("real-art", backdrop: true)])
        #expect(banner.item?.id == "real-art")
        banner.update([title("other", backdrop: true), title("real-art", backdrop: true)])
        #expect(banner.item?.id == "real-art")
    }

    @Test func noEligibleTitlesClearsTheBannerInsteadOfFeaturingAChannelOrEpisode() {
        var banner = HomeBanner()
        banner.update([title("movie", backdrop: true)])
        var blankName = title("blank")
        blankName.name = "  "
        banner.update([title("episode", type: "Episode"), title("channel", type: "TvChannel"),
                       title("season", type: "Season"), title(""), blankName])
        #expect(banner.item == nil)
        banner.update([])
        #expect(banner.item == nil)
    }

    @Test func featuredPoolCanReplaceTheNewestMovieWithAHighlyRatedShow() {
        var banner = HomeBanner(seed: 4)
        let recent = title("newest", backdrop: true)
        banner.update([recent])
        var highlyRated = title("rated-show", type: "Series", backdrop: true)
        highlyRated.communityRating = 8.7
        banner.update([recent], featured: [highlyRated])
        #expect(banner.item?.id == "rated-show")
    }

    @Test func highlyRatedTitlesWinAndDifferentVisitsCanFeatureDifferentTitles() {
        let low = title("unrated", backdrop: true)
        let rated = (0..<4).map { index in
            var item = title("rated-\(index)", backdrop: true)
            item.communityRating = 8.0 + Double(index) / 10
            return item
        }
        let ids = (0..<20).compactMap { seed in
            var banner = HomeBanner(seed: UInt64(seed))
            banner.update([], featured: [low] + rated)
            return banner.item?.id
        }
        #expect(!ids.contains("unrated"))
        #expect(Set(ids).count > 1)
    }

    @Test func emptyOrUnavailableFeaturedPoolUsesOrdinaryLibraryCandidates() {
        var banner = HomeBanner(seed: 1)
        banner.update([title("library", backdrop: true)], featured: [])
        #expect(banner.item?.id == "library")
    }

    @Test func featuredReadUsesOnlyStandardViewerScopedJellyfinAndTheCache() async throws {
        let server = try ServerAddress("https://library.example/jellyfin")
        let transport = BannerTransport()
        let cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let client = JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture"),
            transport: transport, responseCache: cache)
        let page = try await client.homeBannerItems()
        #expect(page.items.first?.id == "rated")
        _ = try await client.homeBannerItems()
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.path == "/jellyfin/Items")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["userId"] == "viewer")
        #expect(query["includeItemTypes"] == "Movie,Series")
        #expect(query["sortBy"] == "CommunityRating,SortName")
        #expect(query["limit"] == "12")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
        #expect(request.url?.query?.contains("fixture-token") == false)
        await cache.close(purge: true)
    }

}


private actor BannerTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(#"{"Items":[{"Id":"rated","Name":"Rated title","Type":"Movie","CommunityRating":8.5,"BackdropImageTags":["art"]}]}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
