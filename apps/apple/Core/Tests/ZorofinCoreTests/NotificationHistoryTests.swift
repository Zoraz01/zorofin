import Foundation
import Testing
@testable import ZorofinCore

@Suite("Notification inbox history") struct NotificationHistoryTests {
    private func notice(_ id: Int) -> RequestAvailabilityNotice {
        .init(id: id, kind: .movie, titleID: id * 10, title: "Fixture \(id)")
    }
    @Test func firstSuccessfulSnapshotIsHiddenAndLaterAvailabilityIsNew() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerAddress("https://media.example/base"), store = NotificationHistoryStore(root: root)
        #expect(try await store.load(server: server, viewerID: "viewer").requestsInitialized == false)
        let first = try await store.receiveRequests([notice(1)], legacyReadIDs: [7], server: server, viewerID: "viewer")
        #expect(first.requestsInitialized && first.readRequestIDs == [1, 7])
        // A pending request is absent from the first available snapshot and becomes new later.
        let next = try await store.receiveRequests([notice(2)], server: server, viewerID: "viewer")
        #expect(next.requests.map(\.id) == [2, 1])
        #expect(!next.readRequestIDs.contains(2))
        _ = try await store.seeRequest(2, server: server, viewerID: "viewer")
        let reopened = try await NotificationHistoryStore(root: root).load(server: server, viewerID: "viewer")
        #expect(reopened.readRequestIDs == [1, 2, 7])
        #expect(reopened.requests.count == 2)
    }
    @Test func emptySuccessfulBaselineStillAllowsFutureUpdates() async throws {
        let suite = "Zorofin-history-test-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = NotificationHistoryStore(defaultsSuiteName: suite), server = try ServerAddress("https://media.example")
        _ = try await store.receiveRequests([], server: server, viewerID: "viewer")
        let state = try await store.receiveRequests([notice(1)], server: server, viewerID: "viewer")
        #expect(state.readRequestIDs.isEmpty)
        let reopened = try await NotificationHistoryStore(defaultsSuiteName: suite).load(server: server, viewerID: "viewer")
        #expect(reopened.requests.map(\.id) == [1])
        #expect(reopened.requestsInitialized)
    }
    @Test func viewingSupportDoesNotInitializeRequestsAndNewReplyOnSameTicketIsNew() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationHistoryStore(root: root), server = try ServerAddress("https://media.example")
        let first = SupportReply(id: "Tfixture1", status: "answered", issueType: "Playback", message: "First", updatedAt: "same")
        let later = SupportReply(id: first.id, status: first.status, issueType: first.issueType, message: "Later", updatedAt: first.updatedAt)
        _ = try await store.seeReply(first, server: server, viewerID: "viewer")
        let state = try await store.load(server: server, viewerID: "viewer")
        #expect(!state.requestsInitialized)
        #expect(state.hiddenReplies == [first])
        #expect(state.seenReplyKeys.contains(first.notificationKey))
        #expect(!state.seenReplyKeys.contains(later.notificationKey))
        let same = try await store.seeReply(first, server: server, viewerID: "viewer")
        #expect(same.hiddenReplies.count == 1)
    }
    @Test func historySeparatesAccountsServersAndBasePaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationHistoryStore(root: root), server = try ServerAddress("https://media.example/base")
        _ = try await store.receiveRequests([notice(1)], server: server, viewerID: "viewer")
        for (url, user) in [(server, "other"), (try ServerAddress("https://other.example/base"), "viewer"),
                            (try ServerAddress("https://media.example/other"), "viewer")] {
            let state = try await store.load(server: url, viewerID: user)
            #expect(!state.requestsInitialized && state.requests.isEmpty)
        }
        let path = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(!path.lastPathComponent.contains("viewer") && !path.lastPathComponent.contains("media.example"))
    }
    @Test func concurrentFetchAndViewingCannotResurrectReadItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationHistoryStore(root: root), server = try ServerAddress("https://media.example")
        _ = try await store.receiveRequests([], server: server, viewerID: "viewer")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 1...20 {
                group.addTask { _ = try await store.seeRequest(id, server: server, viewerID: "viewer") }
                let item = notice(id)
                group.addTask { _ = try await store.receiveRequests([item], server: server, viewerID: "viewer") }
            }
            try await group.waitForAll()
        }
        let state = try await store.load(server: server, viewerID: "viewer")
        #expect(state.readRequestIDs == Set(1...20))
        #expect(Set(state.requests.map(\.id)) == Set(1...20))
    }
    @Test func historyIsBoundedButOldReadsRemainAndUnsafeArtworkIsNotSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationHistoryStore(root: root), server = try ServerAddress("https://media.example")
        _ = try await store.receiveRequests((1...100).map(notice), server: server, viewerID: "viewer")
        let unsafe = RequestAvailabilityNotice(id: 101, kind: .movie, titleID: 1010, title: "Fixture", posterURL: "https://private.example/image?ApiKey=fixture")
        let state = try await store.receiveRequests([unsafe], server: server, viewerID: "viewer")
        #expect(state.requests.count == 100 && state.requests.first?.posterURL == nil)
        #expect(state.readRequestIDs == Set(1...100))
    }
    @Test func corruptHistoryIsNotOverwrittenOrTreatedAsNewInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationHistoryStore(root: root), server = try ServerAddress("https://media.example")
        _ = try await store.receiveRequests([notice(1)], server: server, viewerID: "viewer")
        let url = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await store.receiveRequests([notice(2)], server: server, viewerID: "viewer") }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }
}
