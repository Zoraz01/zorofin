import Foundation

/// A small browse selection from the viewer's recent movie/show pages. It uses
/// the same cached reads as Home; no external catalogue or invented popularity.
public enum SearchRecommendations {
    public static func select(from items: [MediaItem], limit: Int = 24) -> [MediaItem] {
        var seen: Set<String> = []
        let ranked = items.enumerated().filter { _, item in
            (item.type == "Movie" || item.isSeries) && !item.id.isEmpty &&
            !item.name.isEmpty && seen.insert(item.id).inserted
        }.sorted { first, second in
            let a = first.element, b = second.element
            if (a.userData?.played == true) != (b.userData?.played == true) { return a.userData?.played != true }
            let aArt = a.imageTags?["Primary"]?.isEmpty == false
            let bArt = b.imageTags?["Primary"]?.isEmpty == false
            if aArt != bArt { return aArt }
            let aRating = rating(a), bRating = rating(b)
            if aRating != bRating { return aRating > bRating }
            return first.offset < second.offset
        }.map(\.element)
        let movies = ranked.filter { $0.type == "Movie" }, shows = ranked.filter(\.isSeries)
        var result: [MediaItem] = []
        let cap = min(24, max(0, limit))
        for index in 0..<max(movies.count, shows.count) {
            if index < movies.count && result.count < cap { result.append(movies[index]) }
            if index < shows.count && result.count < cap { result.append(shows[index]) }
            if result.count >= cap { break }
        }
        return result
    }
    private static func rating(_ item: MediaItem) -> Double {
        guard let value = item.communityRating, value.isFinite, (0...10).contains(value) else { return 0 }
        return value
    }
}

extension JellyfinClient {
    public func searchRecommendations() async throws -> [MediaItem] {
        async let movies = items(type: "Movie")
        async let shows = items(type: "Series")
        let pages = try await (movies, shows)
        return SearchRecommendations.select(from: pages.0.items + pages.1.items)
    }
}
