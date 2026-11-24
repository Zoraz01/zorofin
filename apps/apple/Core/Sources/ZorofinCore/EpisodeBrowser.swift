import Foundation
import Observation

public protocol EpisodeLibrary: Sendable {
    func seasons(seriesID: String) async throws -> ItemPage
    func episodes(seriesID: String, seasonID: String, start: Int) async throws -> ItemPage
    func recentlyPlayedEpisode(seriesID: String) async throws -> MediaItem?
}

extension JellyfinClient: EpisodeLibrary {
    public func recentlyPlayedEpisode(seriesID: String) async throws -> MediaItem? {
        guard let session else { throw ClientError.missingSession }
        let page = try await request(ItemPage.self, path: ["Items"], query: [
            .init(name: "userId", value: session.viewer.id),
            .init(name: "parentId", value: seriesID), .init(name: "recursive", value: "true"),
            .init(name: "includeItemTypes", value: "Episode"), .init(name: "isMissing", value: "false"),
            .init(name: "enableUserData", value: "true"), .init(name: "sortBy", value: "DatePlayed"),
            .init(name: "sortOrder", value: "Descending"), .init(name: "limit", value: "1")], cachePolicy: .activity)
        return page.items.first { $0.isEpisode && $0.seriesId == seriesID && $0.userData?.lastPlayedDate != nil }
    }
}

public extension MediaItem {
    var episodeSeriesID: String? { isSeries ? id : (isEpisode || type == "Season") ? seriesId : nil }
    var seasonTitle: String { indexNumber == 0 ? "Specials" : name }
    var episodeNumberLabel: String {
        guard isEpisode else { return "" }
        guard let indexNumber else { return "Episode" }
        if parentIndexNumber == 0 { return "Special \(indexNumber)" }
        return "S\(parentIndexNumber ?? 1) E\(indexNumber)"
    }
    var watchProgress: Double {
        if userData?.played == true { return 1 }
        if let percentage = userData?.playedPercentage, percentage.isFinite { return min(1, max(0, percentage / 100)) }
        guard let duration = runTimeTicks, duration > 0 else { return 0 }
        return min(1, Double(resumeTicks) / Double(duration))
    }
}

/// One browser per view/account. Request revisions keep late season pages out of the current selection.
@MainActor @Observable public final class EpisodeBrowserState {
    public private(set) var seasons: [MediaItem] = []
    public private(set) var episodes: [MediaItem] = []
    public private(set) var selectedSeasonID = ""
    public private(set) var currentEpisodeID: String?
    public private(set) var seriesID = ""
    public private(set) var loadingSeasons = false
    public private(set) var loadingEpisodes = false
    public private(set) var error: String?
    public private(set) var hasMore = false
    public private(set) var total: Int?
    @ObservationIgnored private let library: any EpisodeLibrary
    @ObservationIgnored private var context: MediaItem?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var initialized = false

    public init(library: any EpisodeLibrary) { self.library = library }
    public var selectedSeason: MediaItem? { seasons.first { $0.id == selectedSeasonID } }
    public func cancel() { revision = UUID(); loadingSeasons = false; loadingEpisodes = false }

    public func load(_ item: MediaItem, force: Bool = false) async {
        if !force, initialized, context?.id == item.id, context?.seasonId == item.seasonId,
           context?.parentIndexNumber == item.parentIndexNumber, context?.episodeSeriesID == item.episodeSeriesID {
            await resumeSelectedSeason()
            return
        }
        cancel()
        let request = revision
        context = item; initialized = false; seasons = []; episodes = []; selectedSeasonID = ""
        currentEpisodeID = item.isEpisode ? item.id : nil
        hasMore = false; total = nil; error = nil
        guard let seriesID = item.episodeSeriesID else { return }
        self.seriesID = seriesID; loadingSeasons = true
        do {
            let page = try await library.seasons(seriesID: seriesID)
            guard valid(request) else { return }
            guard page.items.allSatisfy({ $0.type == "Season" && ($0.seriesId == nil || $0.seriesId == seriesID) }) else { throw ClientError.invalidResponse }
            var seen = Set<String>()
            seasons = page.items.filter { seen.insert($0.id).inserted }.sorted {
                if $0.indexNumber != $1.indexNumber { return ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            var preferred = item.type == "Season" ? item.id : item.seasonId
            var preferredNumber = item.parentIndexNumber
            if item.isSeries, let recent = try? await library.recentlyPlayedEpisode(seriesID: seriesID) {
                preferred = recent.seasonId; preferredNumber = recent.parentIndexNumber
            }
            guard valid(request) else { return }
            let chosen = seasons.first { $0.id == preferred } ??
                ((item.isEpisode || item.isSeries) ? seasons.first { $0.indexNumber == preferredNumber && preferredNumber != nil } : nil) ??
                seasons.first { ($0.indexNumber ?? 0) > 0 } ?? seasons.first
            loadingSeasons = false; initialized = true
            if let chosen { await selectSeason(chosen.id) }
        } catch {
            guard valid(request) else { return }
            loadingSeasons = false; self.error = "Seasons couldn’t load. Try again."
        }
    }

    public func selectSeason(_ id: String) async {
        guard seasons.contains(where: { $0.id == id }) else { return }
        if id == selectedSeasonID, !loadingEpisodes, error == nil { await resumeSelectedSeason(); return }
        cancel()
        selectedSeasonID = id; episodes = []; offset = 0; total = nil; hasMore = true; error = nil
        await resumeSelectedSeason()
    }

    private func resumeSelectedSeason() async {
        let request = revision
        if episodes.isEmpty && hasMore && error == nil { await loadMore() }
        // Center the episode being viewed, even when it falls beyond the first page.
        // Each page becomes usable immediately; changing season/leaving cancels this search.
        if let context, context.isEpisode,
           context.seasonId == selectedSeasonID || (context.seasonId == nil && context.parentIndexNumber == selectedSeason?.indexNumber) {
            while valid(request), !loadingEpisodes, hasMore, error == nil, !episodes.contains(where: { $0.id == context.id }) { await loadMore() }
        }
    }

    public func loadMore() async {
        guard !loadingEpisodes, hasMore, !selectedSeasonID.isEmpty else { return }
        let request = revision, season = selectedSeasonID, start = offset
        loadingEpisodes = true; error = nil
        do {
            let page = try await library.episodes(seriesID: seriesID, seasonID: season, start: start)
            guard valid(request), season == selectedSeasonID else { return }
            guard page.items.allSatisfy({ $0.isEpisode && ($0.seriesId == nil || $0.seriesId == seriesID) && ($0.seasonId == nil || $0.seasonId == season) }) else { throw ClientError.invalidResponse }
            var seen = Set(episodes.map(\.id))
            let new = page.items.filter { seen.insert($0.id).inserted }.map { item in
                var item = item; item.seriesId = seriesID; item.seasonId = season
                return item
            }
            episodes += new
            offset += page.items.count; total = page.totalRecordCount
            hasMore = !new.isEmpty && (total.map { offset < $0 } ?? (page.items.count >= 30))
            loadingEpisodes = false
        } catch {
            guard valid(request) else { return }
            loadingEpisodes = false; self.error = "Episodes couldn’t load. Try again."
        }
    }
    private func valid(_ request: UUID) -> Bool { request == revision && !Task.isCancelled }
}
