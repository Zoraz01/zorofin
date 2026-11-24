import Foundation
import Testing
@testable import ZorofinCore

private actor AdminFixtureTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var routes: [String: (Int, String)]
    init(_ routes: [String: (Int, String)]) { self.routes = routes }
    func set(_ key: String, _ value: (Int, String)) { routes[key] = value }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let key = (request.httpMethod ?? "GET") + " " + request.url!.path
        let (status, body) = routes[key] ?? (404, "")
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func adminClient(_ transport: any HTTPTransport, server: String = "https://media.example/base") throws -> JellyfinClient {
    let address = try ServerAddress(server)
    let identity = ClientIdentity(deviceID: "fixture-device", deviceName: "Fixture phone")
    let session = Session(server: address, viewer: Viewer(id: "admin-id", name: "Admin"), token: "fixture-token", deviceID: identity.deviceID)
    return JellyfinClient(server: address, identity: identity, session: session, transport: transport)
}

private func json(_ data: Data?) throws -> [String: JSONValue] {
    try JSONDecoder().decode([String: JSONValue].self, from: data ?? Data())
}

@Suite("Native server administration") struct ServerAdministrationTests {
    @Test func jellyfinDatesWithSevenFractionDigitsParse() {
        let date = AdminDate.parse("2026-11-03T05:58:58.1234567Z")
        #expect(date != nil)
        #expect(AdminDate.parse("2026-11-03T05:58:58Z") != nil)
        #expect(AdminDate.parse("2026-11-03T05:58:58") != nil)
        #expect(AdminDate.parse("") == nil)
        #expect(AdminDate.parse("not a date") == nil)
    }

    @Test func dashboardListsDecodeServerShapes() async throws {
        let transport = AdminFixtureTransport([
            "GET /base/System/Info": (200, #"{"Id":"s","ServerName":"Home","Version":"12.4.0","HasPendingRestart":false}"#),
            "GET /base/Sessions": (200, #"[{"Id":"1","UserName":"Sam","Client":"Zorofin","DeviceName":"iPhone","NowPlayingItem":{"Name":"Pilot","SeriesName":"Show","RunTimeTicks":100},"PlayState":{"PositionTicks":25,"IsPaused":true}}]"#),
            "GET /base/ScheduledTasks": (200, #"[{"Id":"t1","Name":"Scan media library","State":"Running","CurrentProgressPercentage":40.5,"Category":"Library"},{"Id":"t2","Name":"Hidden","State":"Idle","IsHidden":true}]"#),
            "GET /base/System/ActivityLog/Entries": (200, #"{"Items":[{"Id":12,"Name":"Sam signed in","Date":"2026-11-03T05:00:00.0000000Z","Severity":"Information"}],"TotalRecordCount":1}"#),
            "GET /base/Library/VirtualFolders": (200, #"[{"Name":"Movies","ItemId":"lib1","CollectionType":"movies","Locations":["/m"]}]"#),
        ])
        let client = try adminClient(transport)
        #expect(try await client.adminServerInfo().serverName == "Home")
        let sessions = try await client.adminSessions()
        #expect(sessions.first?.nowPlayingItem?.title == "Show · Pilot")
        #expect(sessions.first?.progress == 0.25)
        let tasks = try await client.adminTasks()
        #expect(tasks.map(\.id) == ["t1"])
        #expect(tasks.first?.isRunning == true)
        #expect(try await client.adminActivity().first?.id == 12)
        #expect(try await client.adminLibraries().first?.id == "lib1")
        let sessionQuery = await transport.requests[1].url?.query
        #expect(sessionQuery == "activeWithinSeconds=960")
    }

    @Test func policyChangesKeepEveryOtherPolicyField() async throws {
        let transport = AdminFixtureTransport([
            "GET /base/Users/other": (200, #"{"Id":"other","Name":"Sam","Policy":{"IsAdministrator":false,"IsDisabled":false,"EnableLiveTvAccess":true,"BlockedTags":["x"]}}"#),
            "POST /base/Users/other/Policy": (204, ""),
        ])
        try await adminClient(transport).setUserDisabled("other", disabled: true)
        let requests = await transport.requests
        #expect(requests.count == 2)
        let policy = try json(requests[1].httpBody)
        #expect(policy["IsDisabled"] == .bool(true))
        #expect(policy["EnableLiveTvAccess"] == .bool(true))
        #expect(policy["BlockedTags"] == .array([.string("x")]))
        #expect(policy["IsAdministrator"] == .bool(false))
    }

    @Test func administratorsCannotLockThemselvesOut() async throws {
        let transport = AdminFixtureTransport([:])
        let client = try adminClient(transport)
        await #expect(throws: AdministrationError.ownAccount) { try await client.setUserDisabled("ADMIN-ID", disabled: true) }
        await #expect(throws: AdministrationError.ownAccount) { try await client.setUserAdministrator("admin-id", administrator: false) }
        await #expect(throws: AdministrationError.ownAccount) { try await client.deleteUser("admin-id") }
        await #expect(throws: AdministrationError.ownAccount) { try await client.deleteDevice("fixture-device") }
        #expect(await transport.requests.isEmpty)
    }

    @Test func passwordResetTargetsTheChosenAccountOnly() async throws {
        let transport = AdminFixtureTransport(["POST /base/Users/Password": (204, "")])
        try await adminClient(transport).setPassword(userID: "other", newPassword: "new secret")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.query == "userId=other")
        let body = try json(request.httpBody)
        #expect(body["NewPw"] == .string("new secret"))
        #expect(body["CurrentPw"] == nil)
    }

    @Test func refreshModesMatchTheWebDialog() async throws {
        let transport = AdminFixtureTransport(["POST /base/Items/item1/Refresh": (204, "")])
        try await adminClient(transport).refreshMetadata(itemID: "item1", mode: .replaceAll)
        let query = try #require(await transport.requests.first?.url?.query)
        #expect(query.contains("metadataRefreshMode=FullRefresh"))
        #expect(query.contains("replaceAllMetadata=true"))
        #expect(query.contains("replaceAllImages=true"))
        #expect(query.contains("recursive=true"))
        #expect(MetadataRefreshMode.scan.query.contains(.init(name: "metadataRefreshMode", value: "Default")))
    }

    static let item = #"{"Id":"item1","Type":"Movie","Name":"Old","Overview":"Text","ProductionYear":2001,"PremiereDate":"2001-05-04T00:00:00.0000000Z","CommunityRating":7.5,"Genres":["Drama"],"Tags":[],"Studios":[{"Name":"A","Id":"s1"}],"LockData":false,"ProviderIds":{"Tmdb":"9"},"People":[{"Name":"P"}]}"#

    @Test func metadataDraftSendsOnlyEditedFields() throws {
        let source = try JSONDecoder().decode([String: JSONValue].self, from: Data(Self.item.utf8))
        let baseline = try MetadataDraft(source: source)
        #expect(baseline.year == "2001")
        #expect(baseline.communityRating == "7.5")
        #expect(baseline.studios == "A")
        #expect(baseline.supportsIdentify)
        var draft = baseline
        #expect(try draft.changes(from: baseline).isEmpty)
        draft.name = "New"; draft.genres = "Drama, Comedy, drama"; draft.year = ""; draft.lockData = true
        let changes = try draft.changes(from: baseline)
        #expect(changes["Name"] == .string("New"))
        #expect(changes["Genres"] == .array([.string("Drama"), .string("Comedy")]))
        #expect(changes["ProductionYear"] == .null)
        #expect(changes["LockData"] == .bool(true))
        #expect(changes.count == 4)
        draft.year = "abc"
        #expect(throws: AdministrationError.invalidInput) { try draft.changes(from: baseline) }
        draft.year = ""; draft.name = "  "
        #expect(throws: AdministrationError.invalidInput) { try draft.changes(from: baseline) }
    }

    @Test func savingMergesIntoAFreshCopyAndDetectsConflicts() async throws {
        let transport = AdminFixtureTransport([
            "GET /base/Items/item1": (200, Self.item),
            "POST /base/Items/item1": (204, ""),
        ])
        let client = try adminClient(transport)
        let baseline = try await client.metadataDraft(itemID: "item1")
        var draft = baseline
        draft.overview = "Updated"
        _ = try await client.saveMetadata(draft, baseline: baseline)
        let post = try #require(await transport.requests.first { $0.httpMethod == "POST" })
        let body = try json(post.httpBody)
        #expect(body["Overview"] == .string("Updated"))
        #expect(body["People"] == .array([.object(["Name": .string("P")])]))
        #expect(body["ProviderIds"] == .object(["Tmdb": .string("9")]))

        await transport.set("GET /base/Items/item1", (200, Self.item.replacingOccurrences(of: #""Overview":"Text""#, with: #""Overview":"Other device""#)))
        await #expect(throws: SettingsError.changedElsewhere) { try await client.saveMetadata(draft, baseline: baseline) }
    }

    @Test func identifyPostsTheChosenResultBackUnchanged() async throws {
        let transport = AdminFixtureTransport([
            "POST /base/Items/RemoteSearch/Movie": (200, #"[{"Name":"Film","ProductionYear":2001,"ProviderIds":{"Tmdb":"9"},"SearchProviderName":"TheMovieDb","Extra":1}]"#),
            "POST /base/Items/RemoteSearch/Apply/item1": (204, ""),
        ])
        let client = try adminClient(transport)
        let draft = try MetadataDraft(source: JSONDecoder().decode([String: JSONValue].self, from: Data(Self.item.utf8)))
        let results = try await client.remoteSearch(draft, name: "Film", year: "2001")
        #expect(results.first?.name == "Film")
        try await client.applyRemoteResult(try #require(results.first), itemID: "item1", replaceImages: false)
        let requests = await transport.requests
        let search = try json(requests[0].httpBody)
        #expect(search["ItemId"] == .string("item1"))
        #expect(search["SearchInfo"]?.object?["Year"] == .int(2001))
        let applied = try json(requests[1].httpBody)
        #expect(applied["Extra"] == .int(1))
        #expect(requests[1].url?.query == "replaceAllImages=false")
    }

    @Test func accountDecisionsSendTheViewerTokenAndServerOrigin() async throws {
        let transport = AdminFixtureTransport([
            "GET /signup/api/admin/requests": (200, #"{"requests":[{"id":"r1","username":"newbie","status":"pending","created_at":1762149538000,"reviewed_at":null,"error_code":null}]}"#),
            "POST /signup/api/admin/requests/r1/approve": (200, #"{"status":"approved"}"#),
        ])
        let client = try adminClient(transport, server: "https://zorofin.example")
        let requests = try await client.accountRequests()
        #expect(requests.first?.isPending == true)
        #expect(requests.first?.createdAt != nil)
        try await client.decideAccountRequest("r1", approve: true)
        let decision = try #require(await transport.requests.last)
        #expect(decision.value(forHTTPHeaderField: "Origin") == "https://zorofin.example")
        #expect(decision.value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token")
        #expect(decision.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try ServerAddress("https://zorofin.example:8443/base").origin == "https://zorofin.example:8443")
    }
}
