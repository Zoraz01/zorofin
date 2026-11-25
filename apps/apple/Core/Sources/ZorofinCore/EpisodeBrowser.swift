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
    public private(set) var targetingCancelled = false
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
    @ObservationIgnored private var target: MediaItem?

    public init(library: any EpisodeLibrary) { self.library = library }
    public var selectedSeason: MediaItem? { seasons.first { $0.id == selectedSeasonID } }
    public func cancel() { revision = UUID(); loadingSeasons = false; loadingEpisodes = false }

    public func cancelTargeting() { targetingCancelled = true }

    public func load(_ item: MediaItem, preferredEpisode: MediaItem? = nil, force: Bool = false) async {
        let preferredTarget = item.isEpisode ? item : preferredEpisode.flatMap { episode in
            episode.isEpisode && episode.seriesId == item.episodeSeriesID &&
                (item.type != "Season" || episode.seasonId == item.id) ? episode : nil
        }
        if !force, initialized, context?.id == item.id, context?.seasonId == item.seasonId,
           context?.parentIndexNumber == item.parentIndexNumber, context?.episodeSeriesID == item.episodeSeriesID,
           preferredTarget == nil || target?.id == preferredTarget?.id {
            await resumeSelectedSeason()
            return
        }
        let sameContext = context?.id == item.id && context?.episodeSeriesID == item.episodeSeriesID
        let rememberedSeason = sameContext && targetingCancelled ? selectedSeasonID : nil
        cancel()
        let request = revision
        if !sameContext { targetingCancelled = false }
        target = preferredTarget
        context = item; initialized = false; seasons = []; episodes = []; selectedSeasonID = ""
        currentEpisodeID = preferredTarget?.id
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
            var preferred = rememberedSeason ?? (item.type == "Season" ? item.id : target?.seasonId ?? item.seasonId)
            var preferredNumber = target?.parentIndexNumber ?? item.parentIndexNumber
            if item.isSeries, target == nil, let recent = try? await library.recentlyPlayedEpisode(seriesID: seriesID) {
                target = recent; currentEpisodeID = recent.id
                if rememberedSeason == nil { preferred = recent.seasonId; preferredNumber = recent.parentIndexNumber }
            }
            guard valid(request) else { return }
            let chosen = seasons.first { $0.id == preferred } ??
                ((item.isEpisode || item.isSeries) ? seasons.first { $0.indexNumber == preferredNumber && preferredNumber != nil } : nil) ??
                seasons.first { ($0.indexNumber ?? 0) > 0 } ?? seasons.first
            loadingSeasons = false; initialized = true
            if let chosen {
                await selectSeason(chosen.id)
                // Empty regular seasons cannot strand a series with no history.
                if item.isSeries, target == nil {
                    for next in seasons.drop(while: { $0.id != chosen.id }).dropFirst() {
                        guard !Task.isCancelled, !targetingCancelled, context?.id == item.id,
                              episodes.isEmpty, error == nil else { break }
                        await selectSeason(next.id)
                    }
                    if !targetingCancelled, context?.id == item.id, episodes.isEmpty, error == nil {
                        await selectSeason(chosen.id)
                    }
                }
            }
        } catch {
            guard valid(request) else { return }
            loadingSeasons = false; self.error = "Seasons couldn’t load. Try again."
        }
    }

    /// Explicit navigation back to playback/recent history, independent of the browsing season.
    public func returnToCurrentEpisode() async {
        guard let target,
              let season = seasons.first(where: { $0.id == target.seasonId }) ??
                seasons.first(where: { $0.indexNumber == target.parentIndexNumber && target.parentIndexNumber != nil }) else { return }
        targetingCancelled = false
        await selectSeason(season.id)
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
        if let target,
           target.seasonId == selectedSeasonID || (target.seasonId == nil && target.parentIndexNumber == selectedSeason?.indexNumber) {
            var pages = 0
            while valid(request), !targetingCancelled, !loadingEpisodes, hasMore, error == nil,
                  !episodes.contains(where: { $0.id == target.id }), pages < 100 {
                pages += 1; await loadMore()
            }
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
