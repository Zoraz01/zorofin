import Foundation

public enum RequestDiscoverySection: String, CaseIterable, Identifiable, Sendable {
    case recommended, trending, movies, tv, upcoming
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recommended: "Recommended to request"
        case .trending: "Trending now"
        case .movies: "Popular movies"
        case .tv: "Popular TV shows"
        case .upcoming: "Coming soon"
        }
    }
}

public struct RequestDiscoveryRow: Identifiable, Sendable {
    public let section: RequestDiscoverySection
    public var titles: [RequestTitle]
    public var failed: Bool
    public var id: String { section.id }
    public init(section: RequestDiscoverySection, titles: [RequestTitle], failed: Bool = false) {
        self.section = section; self.titles = titles; self.failed = failed
    }
}

private struct RequestRecommendationFeed: Decodable {
    let state: String
    let items: [Recommendation]?
    struct Recommendation: Decodable {
        let tmdbId: Int
        let title: String
        let year: JSONValue?
        let posterUrl: String?
        let overview: String?
        var requestTitle: RequestTitle? {
            guard tmdbId > 0, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let poster = RequestArtwork.url(absolute: posterUrl) else { return nil }
            let release: String?
            switch year {
            case .int(let value): release = (1800...3000).contains(value) ? String(value) : nil
            case .string(let value): release = value.count == 4 && Int(value).map { (1800...3000).contains($0) } == true ? value : nil
            default: release = nil
            }
            return RequestTitle(id: tmdbId, mediaType: "movie", title: title, overview: overview,
                                posterPath: "/" + poster.lastPathComponent, releaseDate: release)
        }
    }
}

public extension JellyfinClient {
    /// Optional same-server feed, authenticated as this viewer. No feed means no
    /// personalized row: never relabel popular titles as personal recommendations.
    func requestRecommendations() async throws -> [RequestTitle] {
        let data = try await requestData(["support", "recommendations"], extensionToken: true, expectedStatus: 200)
        let feed = try JSONDecoder().decode(RequestRecommendationFeed.self, from: data)
        guard feed.state == "ready" else { return [] }
        return Self.uniqueRequestTitles((feed.items ?? []).compactMap(\.requestTitle), limit: 20)
    }

    /// Independent rows fail independently; at most five small reads, no writes,
    /// and cancellation propagates when the account or search changes.
    func requestDiscovery(includeRecommendations: Bool,
                          onRow: @MainActor @Sendable (RequestDiscoveryRow) -> Void = { _ in }) async throws -> [RequestDiscoveryRow] {
        let sections = RequestDiscoverySection.allCases.filter { includeRecommendations || $0 != .recommended }
        return try await withThrowingTaskGroup(of: RequestDiscoveryRow.self) { group in
            for section in sections {
                group.addTask {
                    do {
                        let titles: [RequestTitle]
                        if section == .recommended { titles = try await self.requestRecommendations() }
                        else { titles = try await self.requestTitles(category: section.rawValue).results }
                        try Task.checkCancellation()
                        return .init(section: section, titles: Self.uniqueRequestTitles(titles, limit: 20))
                    } catch is CancellationError { throw CancellationError() }
                    catch ClientError.unavailable(404) where section == .recommended {
                        return .init(section: section, titles: [])
                    } catch {
                        try Task.checkCancellation()
                        return .init(section: section, titles: [], failed: true)
                    }
                }
            }
            var rows: [RequestDiscoveryRow] = []
            for try await row in group {
                try Task.checkCancellation()
                rows.append(row)
                await onRow(row)
            }
            return sections.compactMap { section in rows.first { $0.section == section } }
        }
    }

    private static func uniqueRequestTitles(_ titles: [RequestTitle], limit: Int) -> [RequestTitle] {
        var seen = Set<String>()
        return Array(titles.filter { $0.id > 0 && $0.kind != nil && seen.insert($0.identity).inserted }.prefix(limit))
    }
}
