import Foundation
import Testing
@testable import ZorofinCore

private actor ReadsTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status = 200
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body: Data
        if request.httpMethod == "POST" {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let replies = (payload["replies"] as? [[String: String]] ?? []).map { $0["id"]! + "|" + $0["updatedAt"]! }
            body = try JSONSerialization.data(withJSONObject: ["initialized": payload["initialize"] as? Bool ?? false, "requests": payload["requests"] ?? [], "replies": replies])
        } else { body = Data(#"{"initialized":true,"requests":[41],"replies":["Tfixture|2026-11-09T20:00:00.000Z"]}"#.utf8) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private func readsClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    return .init(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"), session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture-token", deviceID: "fixture"), transport: transport)
}
@Suite("Account notification read contract") struct NotificationReadsTests {
    @Test func getAndExactVersionReplyKeys() async throws {
        let transport = ReadsTransport(), client = try readsClient(transport)
        let state = try await client.notificationReads()
        let reply = SupportReply(id: "Tfixture", status: "answered", issueType: "Playback", message: "First", updatedAt: "2026-11-09T20:00:00.000Z")
        #expect(state.initialized && state.requests == [41] && state.replies.contains(reply.accountReadKey))
        let later = SupportReply(id: reply.id, status: reply.status, issueType: reply.issueType, message: "Later", updatedAt: "2026-11-09T20:00:00.001Z")
        #expect(!state.replies.contains(later.accountReadKey))
        #expect(await transport.requests.first?.url?.path == "/base/Zorofin/Notifications/Read")
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token") == true)
    }
    @Test func postChunksAndInitializesOnlyAfterAllChunks() async throws {
        let transport = ReadsTransport(), client = try readsClient(transport)
        let timestamp = "2026-11-09T20:00:00.000+00:00"
        let reply = SupportReply(id: "Tfixture", status: "answered", issueType: "Playback", message: "Read", updatedAt: timestamp)
        let result = try await client.markNotificationReads(requests: Array(1...1001), replies: [reply], initialize: true)
        let calls = await transport.requests
        #expect(calls.count == 4 && result.initialized && result.requests.count == 1001)
        for (index, request) in calls.enumerated() {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect((payload["requests"] as! [Int]).count + (payload["replies"] as! [[String: String]]).count <= 500)
            #expect(payload["initialize"] as? Bool == (index == calls.count - 1))
            #expect(payload["viewerId"] == nil)
        }
        #expect(result.replies == ["Tfixture|" + timestamp])
    }
    @Test func accountInitializedDeviceDoesNotAutoReadItsFirstSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ServerAddress("https://media.example"), store = NotificationHistoryStore(root: root)
        let notice = RequestAvailabilityNotice(id: 1, kind: .movie, titleID: 10, title: "Sample")
        let state = try await store.receiveRequests([notice], initializeSnapshot: false, server: server, viewerID: "viewer")
        #expect(state.requestsInitialized && !state.readRequestIDs.contains(1))
        #expect(try await store.seeRequest(1, server: server, viewerID: "viewer") == [1])
    }
}
