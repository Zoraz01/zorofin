import Foundation

public enum PlaybackSelectionError: Error, LocalizedError, Equatable, Sendable {
    case noEpisodes, unsupportedItem
    public var errorDescription: String? {
        switch self {
        case .noEpisodes: "No playable episodes were found. Open the show's details to choose an episode."
        case .unsupportedItem: "This item cannot be played directly. Open its details and choose a movie or episode."
        }
    }
}

public extension MediaItem {
    var isPlayableVideo: Bool { ["Movie", "Episode", "TvChannel", "Video", "MusicVideo", "Trailer"].contains(type ?? "") }
}

public struct PlaybackSelection: Sendable {
    public let item: MediaItem
    public let options: PlaybackOptions
}

public extension JellyfinClient {
    /// Home banners may represent an entire show. Resolve its account-specific
    /// episode before creating a player or sending an item to a SyncPlay group.
    func playbackSelection(for item: MediaItem, options: PlaybackOptions) async throws -> PlaybackSelection {
        try Task.checkCancellation()
        guard let session else { throw ClientError.missingSession }
        guard session.server == server else { throw ClientError.unsafeURL }
        let selected: MediaItem
        if item.isSeries {
            let next = try await nextUp(seriesID: item.id, includeResumable: true).items
            try validateEpisodes(next, seriesID: item.id)
            if let episode = next.first { selected = episode }
            else { selected = try await firstEpisode(seriesID: item.id) }
        } else if item.type == "Season" {
            guard let seriesID = item.seriesId, !seriesID.isEmpty else { throw PlaybackSelectionError.noEpisodes }
            let episodes = try await episodes(seriesID: seriesID, seasonID: item.id).items
            try validateEpisodes(episodes, seriesID: seriesID, seasonID: item.id)
            guard let episode = episodes.first else { throw PlaybackSelectionError.noEpisodes }
            selected = episode
        } else {
            guard item.isPlayableVideo else { throw PlaybackSelectionError.unsupportedItem }
            selected = item
        }
        try Task.checkCancellation()
        var configured = options
        if selected.id != item.id {
            // A show's position/track indices do not belong to the chosen episode.
            configured.startTicks = selected.resumeTicks
            configured.audioIndex = nil
            configured.subtitleIndex = -2
        }
        return PlaybackSelection(item: selected, options: configured)
    }

    private func firstEpisode(seriesID: String) async throws -> MediaItem {
        let seasons = try await seasons(seriesID: seriesID).items
        guard seasons.allSatisfy({ $0.type == "Season" && ($0.seriesId == nil || $0.seriesId == seriesID) }) else {
            throw ClientError.invalidResponse
        }
        // Prefer regular seasons to specials; an empty season must not prevent play.
        let ordered = seasons.sorted {
            let left = $0.indexNumber == 0 ? Int.max : ($0.indexNumber ?? Int.max - 1)
            let right = $1.indexNumber == 0 ? Int.max : ($1.indexNumber ?? Int.max - 1)
            return left == right ? $0.id < $1.id : left < right
        }
        for season in ordered {
            try Task.checkCancellation()
            let episodes = try await episodes(seriesID: seriesID, seasonID: season.id).items
            try validateEpisodes(episodes, seriesID: seriesID, seasonID: season.id)
            if let episode = episodes.first { return episode }
        }
        throw PlaybackSelectionError.noEpisodes
    }

    private func validateEpisodes(_ episodes: [MediaItem], seriesID: String, seasonID: String? = nil) throws {
        guard episodes.allSatisfy({ $0.isEpisode && ($0.seriesId == nil || $0.seriesId == seriesID)
            && (seasonID == nil || $0.seasonId == nil || $0.seasonId == seasonID) }) else { throw ClientError.invalidResponse }
    }
}
