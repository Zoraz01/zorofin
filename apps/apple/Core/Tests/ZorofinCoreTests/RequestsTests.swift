import Foundation
import Testing
@testable import ZorofinCore

private actor RequestsTransport: HTTPTransport {
    var sent: [URLRequest] = []
    let postStatus: Int
    let postBody: String
    let movie: String
    let quota: String
    let connected: Bool
    init(postStatus: Int = 201, postBody: String = #"{"id":71,"status":1}"#,
         movie: String = #"{"id":10,"title":"Fixture"}"#,
         quota: String = #"{"movie":{"restricted":false},"tv":{"restricted":false}}"#,
         connected: Bool = true) {
        self.postStatus = postStatus; self.postBody = postBody; self.movie = movie; self.quota = quota; self.connected = connected
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let path = request.url!.path
        var body = "{}", status = 200
        if request.httpMethod == "POST" {
            if postStatus == -1 { throw ClientError.network }
            if postStatus == -2 { throw CancellationError() }
            status = postStatus; body = postBody
        } else if path.hasSuffix("user-status") { body = connected ? #"{"active":true,"userFound":true}"# : #"{"active":true,"userFound":false,"reason":"blocked"}"# }
        else if path.hasSuffix("quota") { body = quota }
        else if path.hasSuffix("public-config") { body = #"{"JellyseerrEnable4KRequests":true,"JellyseerrEnable4KTvRequests":true}"# }
        else if path.hasSuffix("partial-requests") { body = #"{"partialRequestsEnabled":true,"enableSpecialEpisodes":false}"# }
        else if path.contains("/movie/") || path.contains("/tv/") { body = movie }
        else if path.hasSuffix("search") || path.contains("/discover/") { body = #"{"results":[{"id":10,"mediaType":"movie","title":"Fixture"}],"totalPages":2}"# }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    var posts: [URLRequest] { sent.filter { $0.httpMethod == "POST" } }
}

private struct RequestsFixture {
    let root: URL
    let client: JellyfinClient
    let journal: RequestJournal
    let service: RequestSubmissionService
    init(_ transport: RequestsTransport) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let server = try ServerAddress("https://media.example/base")
        client = JellyfinClient(server: server, identity: .init(deviceID: "test", deviceName: "test"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "test"), transport: transport)
        journal = RequestJournal(server: server, viewerID: "viewer", root: root)
        service = RequestSubmissionService(client: client, journal: journal)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let movieIntent = RequestIntent(kind: .movie, id: 10, is4K: false)
private let showJSON = #"{"id":20,"name":"Fixture show","mediaType":"tv","seasons":[{"seasonNumber":0,"episodeCount":1},{"seasonNumber":1,"episodeCount":8},{"seasonNumber":2,"episodeCount":6},{"seasonNumber":3,"episodeCount":4},{"seasonNumber":4,"episodeCount":0}],"mediaInfo":{"status":4,"status4k":1,"seasons":[{"seasonNumber":1,"status":5,"status4k":1}],"requests":[{"id":12,"status":1,"is4k":false,"seasons":[{"seasonNumber":3}]}]}}"#

@Suite("Native Requests") struct RequestsTests {
    @Test func signedInProxyAndCamelCasePayload() async throws {
        let transport = RequestsTransport(), f = try RequestsFixture(transport); defer { f.cleanup() }
        let receipt = try await f.service.submit(movieIntent)
        #expect(receipt.id == 71)
        let posts = await transport.posts
        #expect(posts.count == 1)
        let post = try #require(posts.first)
        #expect(post.url?.path == "/base/JellyfinEnhanced/jellyseerr/request")
        #expect(post.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
        #expect(post.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        let body = try #require(JSONSerialization.jsonObject(with: post.httpBody!) as? [String: Any])
        #expect(Set(body.keys) == ["mediaType", "mediaId", "is4k"])
        #expect(body["mediaId"] as? Int == 10)
        #expect(try await f.journal.entries().first?.receiptID == 71)
        await #expect(throws: RequestFailure.alreadyRequested) { try await f.service.submit(movieIntent) }
        #expect(await transport.posts.count == 1)
    }
    @Test(arguments: [-1, -2, 409, 500, 502, 503])
    func ambiguousDeliverySurvivesRelaunch(status: Int) async throws {
        let transport = RequestsTransport(postStatus: status), f = try RequestsFixture(transport); defer { f.cleanup() }
        await #expect(throws: RequestFailure.unconfirmed) { try await f.service.submit(movieIntent) }
        let reopened = RequestJournal(server: f.client.server, viewerID: "viewer", root: f.root)
        await #expect(throws: RequestFailure.unconfirmed) { try await reopened.begin(movieIntent) }
        #expect(try await reopened.entries().count == 1)
        #expect(await transport.posts.count == 1)
    }
    @Test(arguments: [400, 401, 403, 404, 422, 429])
    func explicitRejectionDoesNotInventReceipt(status: Int) async throws {
        let transport = RequestsTransport(postStatus: status), f = try RequestsFixture(transport); defer { f.cleanup() }
        await #expect(throws: RequestFailure.rejected) { try await f.service.submit(movieIntent) }
        #expect(try await f.journal.entries().isEmpty)
    }
    @Test(arguments: ["{}", #"{"error":true}"#, #"{"id":0}"#, "<html>Sign in</html>"])
    func malformedSuccessIsUnconfirmed(body: String) async throws {
        let f = try RequestsFixture(RequestsTransport(postBody: body)); defer { f.cleanup() }
        await #expect(throws: RequestFailure.unconfirmed) { try await f.service.submit(movieIntent) }
        #expect(try await f.journal.entries().first?.receiptID == nil)
    }
    @Test func duplicateAndRestrictedPreflightsNeverPost() async throws {
        let transports = [RequestsTransport(movie: #"{"id":10,"title":"Fixture","mediaInfo":{"status":5}}"#),
            RequestsTransport(quota: #"{"movie":{"limit":2,"used":2,"restricted":true}}"#), RequestsTransport(connected: false)]
        for transport in transports {
            let f = try RequestsFixture(transport); defer { f.cleanup() }
            do { _ = try await f.service.submit(movieIntent); Issue.record("Invalid request was accepted") } catch { }
            #expect(await transport.posts.isEmpty)
            #expect(try await f.journal.entries().isEmpty)
        }
    }
    @Test func qualityAndSeasonStateRemainIndependent() throws {
        let title = try JSONDecoder().decode(RequestTitle.self, from: Data(showJSON.utf8))
        #expect(title.eligibleSeasons(is4K: false).map(\.seasonNumber) == [2])
        #expect(title.eligibleSeasons(is4K: true).map(\.seasonNumber) == [1, 2, 3])
        #expect(title.eligibleSeasons(is4K: true, specials: true).map(\.seasonNumber) == [0, 1, 2, 3])
        let settings = try JSONDecoder().decode(RequestSeasonSettings.self, from: Data(#"{"partialRequestsEnabled":true}"#.utf8))
        #expect(throws: RequestFailure.invalidSelection) { try RequestIntent(kind: .tv, id: 20, is4K: false, seasons: [1, 2]).validate(title: title, settings: settings, quota: nil) }
        try RequestIntent(kind: .tv, id: 20, is4K: true, seasons: [1, 2]).validate(title: title, settings: settings, quota: nil)
        #expect(throws: RequestFailure.invalidSelection) { try RequestIntent(kind: .tv, id: 20, is4K: true, seasons: [99]).validate(title: title, settings: settings, quota: nil) }
        #expect(throws: RequestFailure.invalidSelection) { try RequestIntent(kind: .tv, id: 20, is4K: true, seasons: [0]).validate(title: title, settings: settings, quota: nil) }
    }
    @Test func tvQuotaCountsSeasonsAndWholeShowPolicyIsRespected() throws {
        let title = try JSONDecoder().decode(RequestTitle.self, from: Data(showJSON.utf8))
        let settings = try JSONDecoder().decode(RequestSeasonSettings.self, from: Data(#"{"partialRequestsEnabled":false}"#.utf8))
        #expect(throws: RequestFailure.invalidSelection) { try RequestIntent(kind: .tv, id: 20, is4K: true, seasons: [2]).validate(title: title, settings: settings, quota: nil) }
        let quota = try JSONDecoder().decode(RequestQuota.self, from: Data(#"{"tv":{"limit":3,"used":1,"restricted":false}}"#.utf8))
        #expect(throws: RequestFailure.quota) { try RequestIntent(kind: .tv, id: 20, is4K: true, seasons: [1, 2, 3]).validate(title: title, settings: settings, quota: quota) }
    }
    @Test func journalSeparatesAccountsServersQualityAndOverlappingSeasons() async throws {
        let f = try RequestsFixture(RequestsTransport()); defer { f.cleanup() }
        let first = RequestIntent(kind: .tv, id: 20, is4K: false, seasons: [1, 2])
        _ = try await f.journal.begin(first)
        let reopened = RequestJournal(server: f.client.server, viewerID: "viewer", root: f.root)
        await #expect(throws: RequestFailure.unconfirmed) { try await reopened.begin(.init(kind: .tv, id: 20, is4K: false, seasons: [2, 3])) }
        _ = try await reopened.begin(.init(kind: .tv, id: 20, is4K: false, seasons: [3]))
        _ = try await reopened.begin(.init(kind: .tv, id: 20, is4K: true, seasons: [1]))
        _ = try await RequestJournal(server: f.client.server, viewerID: "other", root: f.root).begin(first)
        _ = try await RequestJournal(server: ServerAddress("https://other.example"), viewerID: "viewer", root: f.root).begin(first)
        #expect(try await f.journal.entries().count == 3)
        for url in try FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil) {
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(!content.contains("fixture-token") && !content.contains("media.example") && !content.contains("viewer"))
        }
    }
    @Test func onlyMatchingReceiptsReconcileUncertainTV() async throws {
        let f = try RequestsFixture(RequestsTransport()); defer { f.cleanup() }
        _ = try await f.journal.begin(.init(kind: .tv, id: 20, is4K: false, seasons: [3]))
        _ = try await f.journal.begin(.init(kind: .tv, id: 20, is4K: true, seasons: [3]))
        let title = try JSONDecoder().decode(RequestTitle.self, from: Data(showJSON.utf8))
        try await f.journal.reconcile(title)
        let entries = try await f.journal.entries()
        #expect(entries[0].receiptID == 12)
        #expect(entries[1].receiptID == nil)
    }
    @Test func corruptJournalFailsClosed() async throws {
        let f = try RequestsFixture(RequestsTransport()); defer { f.cleanup() }
        _ = try await f.journal.begin(movieIntent)
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)
        await #expect(throws: RequestFailure.storage) { try await f.journal.begin(.init(kind: .movie, id: 11, is4K: false)) }
    }
    @Test func concurrentJournalInstancesPermitOnlyOneAttempt() async throws {
        let f = try RequestsFixture(RequestsTransport()); defer { f.cleanup() }
        let other = RequestJournal(server: f.client.server, viewerID: "viewer", root: f.root)
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for journal in [f.journal, other] { group.addTask { (try? await journal.begin(movieIntent)) != nil } }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        #expect(count == 1)
        await #expect(throws: RequestFailure.inProgress) { try await f.service.allowAnotherAttempt(kind: .movie, id: 10, is4K: false) }
    }
    @Test func manualRecoveryRequiresFreshChecksAndNeverPosts() async throws {
        let transport = RequestsTransport(postStatus: -1), f = try RequestsFixture(transport); defer { f.cleanup() }
        await #expect(throws: RequestFailure.unconfirmed) { try await f.service.submit(movieIntent) }
        let file = try #require(FileManager.default.contentsOfDirectory(at: f.root, includingPropertiesForKeys: nil).first)
        var entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        entries[0]["created"] = Date().addingTimeInterval(-120).timeIntervalSinceReferenceDate
        try JSONSerialization.data(withJSONObject: entries).write(to: file)
        try await f.service.allowAnotherAttempt(kind: .movie, id: 10, is4K: false)
        #expect(try await f.journal.entries().isEmpty)
        #expect(await transport.posts.count == 1)
    }
    @Test func searchEncodesInputAndKeepsBasePath() async throws {
        let transport = RequestsTransport(), f = try RequestsFixture(transport); defer { f.cleanup() }
        _ = try await f.client.requestTitles(query: "Dune & Arrival", page: 2)
        let request = try #require(await transport.sent.first)
        #expect(request.url?.path == "/base/JellyfinEnhanced/jellyseerr/search")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value == "Dune & Arrival")
    }
    @Test func artworkCannotExfiltrateCredentialsOrUseAnArbitraryHost() {
        #expect(RequestArtwork.url(path: "/poster.jpg")?.host == "image.tmdb.org")
        for value in ["https://evil.example/x.jpg", "/../x.jpg", "/x.jpg?ApiKey=secret", "//evil.example/x.jpg"] { #expect(RequestArtwork.url(path: value) == nil) }
        for value in ["https://image.tmdb.org.evil.example/t/p/w300/x.jpg", "http://image.tmdb.org/t/p/w300/x.jpg", "https://user:secret@image.tmdb.org/t/p/w300/x.jpg"] { #expect(RequestArtwork.url(absolute: value) == nil) }
    }
    @Test func downloadCompletionDoesNotClaimAvailability() throws {
        let queue = try JSONDecoder().decode(RequestQueue.self, from: Data(#"{"items":[{"tmdbId":10,"source":"Radarr","progress":100,"status":"completed"}]}"#.utf8))
        let item = try JSONDecoder().decode(RequestActivityItem.self, from: Data(#"{"id":1,"type":"movie","tmdbId":10,"requestStatus":2,"mediaStatus":"Processing"}"#.utf8))
        #expect(item.statusLabel == "Requested")
        #expect(queue.label(for: item) == "Adding to library")
    }
}
