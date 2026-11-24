import Foundation

/// Resume positions and the server's next episodes form one Home shelf. A show
/// with an unfinished episode keeps that episode instead of a second series card.
public struct ContinueWatchingFeed: Sendable {
    public let items: [MediaItem]
    public let isPartial: Bool

    public init(resume: [MediaItem], nextUp: [MediaItem], isPartial: Bool = false, limit: Int = 40) {
        self.isPartial = isPartial
        var ids: Set<String> = [], series: Set<String> = []
        var selected: [MediaItem] = []
        let cap = min(40, max(0, limit))
        let candidates = resume.filter { $0.type == "Movie" || $0.isEpisode } +
            nextUp.filter { $0.isEpisode && $0.userData?.played != true }
        for item in candidates {
            guard selected.count < cap else { break }
            guard !item.id.isEmpty, !item.name.isEmpty, !ids.contains(item.id) else { continue }
            let show = item.isEpisode ? item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            if let show, !show.isEmpty, series.contains(show) { continue }
            ids.insert(item.id)
            if let show, !show.isEmpty { series.insert(show) }
            selected.append(item)
        }
        items = selected
    }
}

extension JellyfinClient {
    public func continueWatching() async throws -> ContinueWatchingFeed {
        async let resumed = continueWatchingPage(next: false)
        async let upcoming = continueWatchingPage(next: true)
        let (resume, nextUp) = await (resumed, upcoming)
        try Task.checkCancellation()
        // Authentication/retired-session failures cannot be hidden by a second
        // successful source. Ordinary source outages retain the usable half.
        for result in [resume, nextUp] {
            if case .failure(let error) = result {
                if error is CancellationError { throw error }
                if let clientError = error as? ClientError,
                   [.unauthorized, .forbidden, .missingSession, .unsafeURL].contains(clientError) { throw error }
            }
        }
        switch (resume, nextUp) {
        case (.success(let resumed), .success(let upcoming)):
            return ContinueWatchingFeed(resume: resumed.items, nextUp: upcoming.items)
        case (.success(let resumed), .failure):
            return ContinueWatchingFeed(resume: resumed.items, nextUp: [], isPartial: true)
        case (.failure, .success(let upcoming)):
            return ContinueWatchingFeed(resume: [], nextUp: upcoming.items, isPartial: true)
        case (.failure(let error), .failure): throw error
        }
    }

    private func continueWatchingPage(next: Bool) async -> Result<ItemPage, any Error> {
        do {
            if next { return .success(try await nextUp()) }
            return .success(try await resume())
        }
        catch { return .failure(error) }
    }
}
