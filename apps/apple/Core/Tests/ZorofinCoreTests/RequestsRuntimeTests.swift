import Foundation
import Testing
@testable import ZorofinCore

/// Opt-in read-only verification. The caller owns a short-lived session file and
/// must revoke the session and remove the file in a finally block. No POST request
/// endpoint is called by this test; real catalog additions are not test fixtures.
@Suite("Requests against running Jellyfin") struct RequestsRuntimeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_REQUESTS_SESSION_FILE"] != nil))
    func liveReadModelsAndArtwork() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["ZOROFIN_REQUESTS_SESSION_FILE"])
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(session.server.url.host == "127.0.0.1")
        let client = JellyfinClient(server: session.server,
            identity: .init(deviceID: session.deviceID, deviceName: "Native Requests Verification"), session: session)
        let version = try await client.systemInfo().version
        #expect(version == env["ZOROFIN_REQUESTS_EXPECTED_VERSION"])
        try #require(try await client.requestAccess().available)
        let config = try await client.requestConfiguration()
        _ = try await client.requestQuota()
        _ = try await client.requestSeasonSettings()
        var count = 0
        for category in ["trending", "movies", "tv", "upcoming"] {
            let page = try await client.requestTitles(category: category)
            #expect(!page.results.isEmpty)
            count += page.results.count
        }
        let search = try await client.requestTitles(query: "Dune")
        let movie = try #require(search.results.first { $0.kind == .movie })
        let details = try await client.requestTitle(kind: .movie, id: movie.id)
        #expect(details.id == movie.id)
        let shows = try await client.requestTitles(category: "tv")
        let show = try #require(shows.results.first { $0.kind == .tv })
        let seasons = try await client.requestTitle(kind: .tv, id: show.id)
        #expect(seasons.seasons != nil)
        let mine = try await client.requestActivity(mine: true)
        let shared = try await client.requestActivity(mine: false)
        let queue = try await client.requestQueue()
        _ = mine.requests.compactMap { queue.label(for: $0) }
        let artwork = try #require(RequestArtwork.url(path: details.posterPath))
        #expect(try await RequestArtwork.data(url: artwork).count > 0)
        print("Requests runtime verified: Jellyfin \(version ?? "unknown"); catalog items \(count); personal activity \(mine.requests.count); shared activity \(shared.requests.count); 4K movie \(config.allows4K(.movie)); 4K TV \(config.allows4K(.tv)); media POSTs 0")
    }
}
