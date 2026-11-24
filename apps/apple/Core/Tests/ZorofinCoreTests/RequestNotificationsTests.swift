import Foundation
import Testing
@testable import ZorofinCore

private actor NotificationTransport: HTTPTransport {
    var sent: [URLRequest] = []
    let pages: [String]
    let details: [Int: String]
    let failure: Int?
    init(pages: [String], details: [Int: String] = [:], failure: Int? = nil) {
        self.pages = pages; self.details = details; self.failure = failure
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let url = request.url!, path = url.path
        var body = "{}", code = 200
        if path.hasSuffix("/arr/requests") {
            let skip = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "skip" }?.value ?? "0"
            let page = (Int(skip) ?? 0) / 50
            body = pages[min(page, pages.count - 1)]
        } else if path.contains("/jellyseerr/") {
            let id = Int(url.lastPathComponent) ?? 0
            body = details[id] ?? "{}"; code = failure ?? 200
        } else if path.contains("/Items/") { body = #"{"Id":"library-id","Name":"Fixture","Type":"Movie"}"# }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private func notificationClient(_ transport: NotificationTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "fixture"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture"), transport: transport)
}
private func activity(_ id: Int, titleID: Int = 10, status: Int = 5, kind: String = "movie") -> String {
    // The current upstream activity proxy omits is4k and can report standard
    // availability even for a 4K request. Detail receipts are authoritative.
    "{\"id\":\(id),\"tmdbId\":\(titleID),\"type\":\"\(kind)\",\"title\":\"Fixture\",\"requestStatus\":\(status),\"mediaStatus\":\"Available\"}"
}
private func page(_ activities: [String], total: Int = 1) -> String {
    "{\"requests\":[\(activities.joined(separator: ","))],\"totalPages\":\(total)}"
}
private func movie(_ receipts: String = #"{"id":1,"status":5,"is4k":false}"#, status: Int = 5, fourK: Int = 1) -> String {
    "{\"id\":10,\"title\":\"Fixture\",\"mediaInfo\":{\"status\":\(status),\"status4k\":\(fourK),\"jellyfinMediaId\":\"library-id\",\"jellyfinMediaId4k\":\"library-4k\",\"requests\":[\(receipts)]}}"
}

@Suite("Request availability notifications") struct RequestNotificationsTests {
    @Test func personalAuthenticatedPaginationDeduplicatesAndSkipsReadDetails() async throws {
        let transport = NotificationTransport(pages: [page([activity(1), activity(2, titleID: 20)], total: 2), page([activity(1), activity(3)], total: 2)],
            details: [10: movie(#"{"id":1,"status":5,"is4k":false},{"id":3,"status":2,"is4k":false}"#)])
        let result = try await notificationClient(transport).requestAvailabilityNotifications(readIDs: [2])
        #expect(result.notices.map(\.id) == [1, 3]); #expect(!result.hasOlder)
        let sent = await transport.sent
        #expect(sent.count == 3)
        for request in sent {
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path.hasPrefix("/base/") == true)
            #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
            #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
            #expect(!request.url!.absoluteString.contains("fixture-token"))
        }
        for (index, request) in sent.prefix(2).enumerated() {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains(.init(name: "userOnly", value: "true")))
            #expect(query.contains(.init(name: "take", value: "50")))
            #expect(query.contains(.init(name: "skip", value: String(index * 50))))
            #expect(query.contains(.init(name: "filter", value: "all")))
        }
    }
    @Test func approvalOrDownloadProgressAloneDoesNotNotify() async throws {
        let transport = NotificationTransport(pages: [page([activity(1, status: 2), activity(2, status: 1), activity(3, status: 3), activity(4, status: 4)])],
            details: [10: movie(#"{"id":1,"status":2,"is4k":false}"#, status: 3)])
        #expect(try await notificationClient(transport).requestAvailabilityNotifications().notices.isEmpty)
        #expect(await transport.sent.count == 2)
    }
    @Test func qualityComesFromMatchingReceiptNotStandardActivityLabel() async throws {
        let receipts = #"{"id":1,"status":5,"is4k":false},{"id":2,"status":2,"is4k":true},{"id":3,"status":5}"#
        let transport = NotificationTransport(pages: [page([activity(1), activity(2), activity(3)])], details: [10: movie(receipts)])
        let notices = try await notificationClient(transport).requestAvailabilityNotifications().notices
        #expect(notices.map(\.id) == [1]); #expect(notices.first?.is4K == false)
        let fourK = NotificationTransport(pages: [page([activity(2)])], details: [10: movie(receipts, status: 1, fourK: 5)])
        let ready = try await notificationClient(fourK).requestAvailabilityNotifications().notices
        #expect(ready.map(\.id) == [2]); #expect(ready.first?.is4K == true)
    }
    @Test func requestedSeasonsMustAllBeAvailableInCorrectQuality() async throws {
        let detail = #"{"id":20,"name":"Show","mediaInfo":{"status":4,"status4k":4,"seasons":[{"seasonNumber":1,"status":5,"status4k":3},{"seasonNumber":2,"status":3,"status4k":5}],"requests":[{"id":1,"status":5,"is4k":false,"seasons":[{"seasonNumber":1}]},{"id":2,"status":2,"is4k":false,"seasons":[{"seasonNumber":1},{"seasonNumber":2}]},{"id":3,"status":2,"is4k":true,"seasons":[{"seasonNumber":1}]},{"id":4,"status":5,"is4k":true,"seasons":[{"seasonNumber":2}]}]}}"#
        let transport = NotificationTransport(pages: [page((1...4).map { activity($0, titleID: 20, kind: "tv") })], details: [20: detail])
        #expect(try await notificationClient(transport).requestAvailabilityNotifications().notices.map(\.id) == [1, 4])
    }
    @Test func removedOrMissingReceiptsNeverInventAnUpdate() async throws {
        for detail in [movie(status: 7), movie(#"{"id":1,"status":3,"is4k":false}"#), movie(#"{"id":9,"status":5,"is4k":false}"#)] {
            let transport = NotificationTransport(pages: [page([activity(1)])], details: [10: detail])
            #expect(try await notificationClient(transport).requestAvailabilityNotifications().notices.isEmpty)
        }
    }
    @Test func boundedHistorySignalsOlderRequests() async throws {
        let transport = NotificationTransport(pages: [page([], total: 3)])
        let result = try await notificationClient(transport).requestAvailabilityNotifications()
        #expect(result.hasOlder); #expect(await transport.sent.count == 2)
    }
    @Test func detailFailureRemainsAnErrorRatherThanAnEmptyInbox() async throws {
        let transport = NotificationTransport(pages: [page([activity(1)])], failure: 403)
        await #expect(throws: ClientError.forbidden) { try await notificationClient(transport).requestAvailabilityNotifications() }
    }
    @Test func malformedPageAndCancellationFailClosed() async throws {
        let malformed = NotificationTransport(pages: [#"{"error":true}"#])
        await #expect(throws: ClientError.invalidResponse) { try await notificationClient(malformed).requestAvailabilityNotifications() }
        let transport = NotificationTransport(pages: [page([])])
        let client = try notificationClient(transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.requestAvailabilityNotifications()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.sent.isEmpty)
    }
    @Test func openUsesFreshMatchingLibraryVersionAndRejectsChangedAvailability() async throws {
        let notice = RequestAvailabilityNotice(id: 2, kind: .movie, titleID: 10, title: "Fixture", is4K: true)
        let ready = NotificationTransport(pages: [page([])], details: [10: movie(#"{"id":2,"status":5,"is4k":true}"#, fourK: 5)])
        _ = try await notificationClient(ready).requestNotificationItem(notice)
        #expect(await ready.sent.last?.url?.path.hasSuffix("/Items/library-4k") == true)
        let pending = NotificationTransport(pages: [page([])], details: [10: movie(#"{"id":2,"status":2,"is4k":true}"#)])
        await #expect(throws: RequestNotificationError.self) { try await notificationClient(pending).requestNotificationItem(notice) }
        #expect(await pending.sent.count == 1)
    }
    @Test func readReceiptsSurviveReopenAndSeparateAccountsServersAndBasePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerAddress("https://media.example/base"), store = RequestNotificationReadStore(root: root)
        _ = try await store.markRead(7, server: server, viewerID: "viewer")
        let reopened = RequestNotificationReadStore(root: root)
        #expect(try await reopened.readIDs(server: server, viewerID: "viewer") == [7])
        #expect(try await reopened.readIDs(server: server, viewerID: "other").isEmpty)
        #expect(try await reopened.readIDs(server: ServerAddress("https://other.example/base"), viewerID: "viewer").isEmpty)
        #expect(try await reopened.readIDs(server: ServerAddress("https://media.example/other"), viewerID: "viewer").isEmpty)
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            #expect(try String(contentsOf: url, encoding: .utf8) == "[7]")
            #expect(!url.lastPathComponent.contains("viewer") && !url.lastPathComponent.contains("media.example"))
        }
    }
    @Test func concurrentReadsKeepEveryAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RequestNotificationReadStore(root: root), server = try ServerAddress("https://media.example")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 1...20 { group.addTask { _ = try await store.markRead(id, server: server, viewerID: "viewer") } }
            try await group.waitForAll()
        }
        #expect(try await store.readIDs(server: server, viewerID: "viewer") == Set(1...20))
    }
    @Test func corruptReadStateIsNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RequestNotificationReadStore(root: root), server = try ServerAddress("https://media.example")
        _ = try await store.markRead(1, server: server, viewerID: "viewer")
        let url = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await store.markRead(2, server: server, viewerID: "viewer") }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }
    @Test func tvDefaultsBackendPersistsAndSeparatesAccounts() async throws {
        let suite = "Zorofin-notification-test-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = RequestNotificationReadStore(defaultsSuiteName: suite), server = try ServerAddress("https://media.example")
        _ = try await store.markRead(3, server: server, viewerID: "viewer")
        let reopened = RequestNotificationReadStore(defaultsSuiteName: suite)
        #expect(try await reopened.readIDs(server: server, viewerID: "viewer") == [3])
        #expect(try await reopened.readIDs(server: server, viewerID: "other").isEmpty)
    }
}
