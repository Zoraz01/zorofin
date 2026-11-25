import Foundation
import Testing
@testable import ZorofinCore

@Suite("Announcement inbox") struct ServerAnnouncementsTests {
    private func message(_ extra: [String: Any] = [:], now: Date = Date()) throws -> SupportReply? {
        var value: [String: Any] = ["enabled": true, "id": "notice-1", "title": "Server update", "message": "Administrator message"]
        value.merge(extra) { _, new in new }
        return try JSONDecoder().decode(ServerAnnouncement.self, from: JSONSerialization.data(withJSONObject: value)).inboxMessage(now: now)
    }
    @Test func stableIdentityAndEditedUnread() throws {
        let parsed = try message()
        let first = try #require(parsed)
        #expect(first.isAnnouncement)
        #expect(first.sourceLabel == "Server announcement")
        #expect(first.notificationKey == (try message())?.notificationKey)
        #expect(first.notificationKey != (try message(["title": "Updated headline"]))?.notificationKey)
        #expect(first.notificationKey != (try message(["message": "Edited message"]))?.notificationKey)
    }
    @Test func inactiveAndInvalidMessages() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-04T00:00:00Z"))
        #expect(try message(["enabled": false], now: now) == nil)
        #expect(try message(["startAt": "2026-11-05T00:00:00Z"], now: now) == nil)
        #expect(try message(["endAt": "2026-11-04T00:00:00Z"], now: now) == nil)
        #expect(throws: ClientError.invalidResponse) { try message(["startAt": "invalid"]) }
        #expect(throws: ClientError.invalidResponse) { try message(["id": "../unsafe"]) }
    }
    @Test func partialRefreshPreservesOnlyFailedSource() throws {
        let parsed = try message()
        let previous = try #require(parsed)
        let reply = SupportReply(id: "Tabcdef", status: "Resolved", issueType: "Playback", message: "Answer", updatedAt: "")
        let partial = ServerInbox(replies: [reply], announcements: nil)
        #expect(partial.partial)
        #expect(partial.keeping([previous]) == [previous, reply])
        #expect(ServerInbox(replies: [], announcements: []).keeping([previous, reply]).isEmpty)
    }
}

private actor AnnouncementTransport: HTTPTransport {
    let status: Int
    var requests: [URLRequest] = []
    init(status: Int) { self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
extension ServerAnnouncementsTests {
    private func client(_ transport: any HTTPTransport) throws -> JellyfinClient {
        let server = try ServerAddress("https://example.test/jellyfin")
        return JellyfinClient(server: server, identity: .init(deviceID: "test", deviceName: "Test"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture", deviceID: "test"), transport: transport)
    }
    @Test func optionalEndpointIsAuthenticatedAndServerScoped() async throws {
        let transport = AnnouncementTransport(status: 404)
        #expect(try await client(transport).serverAnnouncements().isEmpty)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/jellyfin/support/announcement/me")
        #expect(requests.first?.value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture")
    }
    @Test func deniedFeedNeverRetriesAnonymously() async throws {
        let transport = AnnouncementTransport(status: 401)
        await #expect(throws: ClientError.unauthorized) { try await client(transport).serverAnnouncements() }
        #expect(await transport.requests.count == 1)
    }
}
