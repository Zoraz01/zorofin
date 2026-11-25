import Foundation

/// The server's Next Up order leads one Home shelf. Matching unfinished episodes
/// retain their resume position at that rank; remaining resume titles follow.
public struct ContinueWatchingFeed: Sendable {
    public let items: [MediaItem]
    public let isPartial: Bool

    public init(resume: [MediaItem], nextUp: [MediaItem], isPartial: Bool = false, limit: Int = 40) {
        self.isPartial = isPartial
        var ids: Set<String> = [], series: Set<String> = []
        var selected: [MediaItem] = []
        let cap = min(40, max(0, limit))
        func showID(_ item: MediaItem) -> String? {
            guard item.isEpisode, let show = item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !show.isEmpty else { return nil }
            return show
        }
        let resumable = resume.filter { !$0.id.isEmpty && !$0.name.isEmpty && ($0.type == "Movie" || $0.isEpisode) }
        var resumeByID: [String: MediaItem] = [:], resumeBySeries: [String: MediaItem] = [:]
        for item in resumable where item.isEpisode {
            if resumeByID[item.id] == nil { resumeByID[item.id] = item }
            if let show = showID(item), resumeBySeries[show] == nil { resumeBySeries[show] = item }
        }
        // Next Up already ranks shows by the server's viewing history, including
        // season transitions. Do not bury those suggestions behind old resumes.
        let upcoming = nextUp.filter { !$0.id.isEmpty && !$0.name.isEmpty && $0.isEpisode && $0.userData?.played != true }
        let candidates = upcoming.map { item in
            resumeByID[item.id] ?? showID(item).flatMap { resumeBySeries[$0] } ?? item
        } + resumable
        for item in candidates {
            guard selected.count < cap else { break }
            guard !item.id.isEmpty, !item.name.isEmpty, !ids.contains(item.id) else { continue }
            let show = showID(item)
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
