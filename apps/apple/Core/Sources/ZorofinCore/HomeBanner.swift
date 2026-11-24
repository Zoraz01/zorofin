import Foundation

/// A client-selected Home feature. Candidates come only from viewer-scoped
/// library reads, without a server extension or separate artwork service.
public struct HomeBanner: Sendable {
    public private(set) var item: MediaItem?
    private var random: HomeRandom

    public init(seed: UInt64 = .random(in: .min ... .max)) { random = HomeRandom(seed: seed) }

    public mutating func update(_ candidates: [MediaItem], featured: [MediaItem] = []) {
        let preferred = Self.eligible(featured)
        let available = preferred.isEmpty ? Self.eligible(candidates) : preferred
        let highlyRated = available.filter { ($0.communityRating ?? 0).isFinite && ($0.communityRating ?? 0) >= 7 }
        let pool = highlyRated.isEmpty ? available : highlyRated
        let bestArtwork = pool.map(Self.artworkRank).max() ?? 0
        var seen: Set<String> = []
        let finalists = pool.filter {
            Self.artworkRank($0) == bestArtwork && seen.insert($0.id).inserted
        }
        // One selection per Home/account session, stable across row arrivals/refreshes.
        // New sessions can feature another title instead of always the newest one.
        if let refreshed = finalists.first(where: { $0.id == item?.id }) {
            item = refreshed
        } else {
            item = Array(finalists.prefix(8)).randomElement(using: &random)
        }
    }

    private static func eligible(_ candidates: [MediaItem]) -> [MediaItem] {
        candidates.filter {
            ($0.type == "Movie" || $0.isSeries) &&
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func artworkRank(_ item: MediaItem) -> Int {
        if item.backdropImageTags?.contains(where: { !$0.isEmpty }) == true { return 2 }
        if let tag = item.imageTags?["Primary"], !tag.isEmpty { return 1 }
        return 0
    }
}

extension JellyfinClient {
    /// A small, cached pool across movies and shows; ratings belong to the
    /// selected server. Unrated libraries still return real titles as fallback.
    public func homeBannerItems() async throws -> ItemPage {
        guard let session else { throw ClientError.missingSession }
        return try await request(ItemPage.self, path: ["Items"], query: [
            .init(name: "userId", value: session.viewer.id), .init(name: "recursive", value: "true"),
            .init(name: "includeItemTypes", value: "Movie,Series"), .init(name: "limit", value: "12"),
            .init(name: "sortBy", value: "CommunityRating,SortName"), .init(name: "sortOrder", value: "Descending"),
            .init(name: "fields", value: "Overview,MediaStreams"), .init(name: "enableUserData", value: "true"),
            .init(name: "enableImageTypes", value: "Primary,Backdrop"), .init(name: "imageTypeLimit", value: "1"),
            .init(name: "excludeLocationTypes", value: "Virtual"), .init(name: "isPlaceHolder", value: "false")
        ], cachePolicy: .library)
    }
}
