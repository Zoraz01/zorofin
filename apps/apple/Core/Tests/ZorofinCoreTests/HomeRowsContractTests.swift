import Foundation
import Testing
@testable import ZorofinCore

private func pluginFeed(_ rows: [HomeRow] = []) -> HomeFeed {
    var prefs = HomePreferences(); prefs.teams = ["Boston Celtics"]
    return HomeFeed(generatedAt: "2026-11-05T12:00:00Z", preferences: prefs, rows: rows)
}
private actor ContractTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status = 200
    var payload = try! JSONEncoder().encode(pluginFeed())
    let version: Int?
    let enabled: Bool
    init(version: Int? = 2, enabled: Bool = true) { self.version = version; self.enabled = enabled }
    func configure(status: Int = 200, payload: Data? = nil) {
        self.status = status
        if let payload { self.payload = payload }
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        var data = Data(), code = 200
        if path.hasSuffix("/Capabilities") {
            // Use JSONSerialization so capability and feed schema versions stay independent.
            var features: [String: Any] = ["homeSections": ["version": 1, "enabled": true],
                "support": ["version": 2, "enabled": true], "requests": ["version": 2, "enabled": true]]
            if let version { features["homeRows"] = ["version": version, "enabled": enabled] }
            data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "features": features])
        } else if path.hasSuffix("/Zorofin/Home/Rows") || path.hasSuffix("/support/home/rows") {
            if status == 0 { throw URLError(.timedOut) }
            data = payload; code = status
        } else if path.contains("/DisplayPreferences/") {
            data = Data(#"{"Id":"zorofin-home","CustomPrefs":{"other":"keep","zorofinTeams":"[\"Boston Celtics\"]"}}"#.utf8)
        } else if path.hasSuffix("/support/home/preferences") {
            data = try JSONEncoder().encode(HomePreferences())
        } else if request.url?.query?.contains("Movie") == true {
            data = Data(#"{"Items":[{"Id":"local","Name":"Local short film","Type":"Movie","LocationType":"FileSystem","RunTimeTicks":36000000000,"UserData":{"Played":false}}],"TotalRecordCount":1}"#.utf8)
        } else { data = Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}
private func contractClient(_ transport: any HTTPTransport, viewer: String = "viewer", token: String = "viewer-token",
                            base: String = "https://example.test/jellyfin", cache: LibraryResponseCache? = nil) throws -> JellyfinClient {
    let server = try ServerAddress(base)
    return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
        session: .init(server: server, viewer: .init(id: viewer, name: "Viewer"), token: token, deviceID: "fixture"),
        transport: transport, responseCache: cache)
}

@Suite("Home row capability switchover") struct HomeRowsContractTests {
    @Test(arguments: [0, 1, 2, 3])
    func capabilityVersionsRemainModuleSpecific(version: Int) async throws {
        let transport = ContractTransport(version: version)
        let features = try await contractClient(transport).discoverFeatures().features
        #expect(features.homeRowsContract == HomeRowsContract(rawValue: version))
        #expect(!features.support)
        #expect(features.requests)
    }
    @Test func absentDisabledAndWebOnlyStayOff() async throws {
        for transport in [ContractTransport(version: nil), ContractTransport(enabled: false)] {
            #expect(try await contractClient(transport).discoverFeatures().features.homeRowsContract == nil)
        }
        #expect(ServerFeatures(homeRows: true).homeRowsContract == .legacy)
        #expect(ServerFeatures(homeRowsContract: .legacy) != ServerFeatures(homeRowsContract: .plugin))
    }
    @Test(arguments: [HomeRowsContract.legacy, .plugin])
    func authenticatedBasePathAndSchemaOne(contract: HomeRowsContract) async throws {
        let transport = ContractTransport()
        let feed = try await contractClient(transport).homeFeed(contract: contract)
        #expect(feed.schemaVersion == 1)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/jellyfin/" + contract.path.joined(separator: "/"))
        #expect(request.url?.query == (contract == .plugin ? "taste=true" : nil))
        #expect(request.value(forHTTPHeaderField: "X-Jellyfin-Token") == "viewer-token")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("viewer-token") == true)
        #expect(request.timeoutInterval == 5)
    }
    @Test func pluginSuccessOwnsOmittedEmptyAndUnavailableRows() async throws {
        for rows in [[HomeRow](), [.init(id: "showcase", title: "4K", description: "", state: "empty", cards: []),
                                   .init(id: "sports", title: "Teams", description: "", state: "unavailable", cards: [])]] {
            let transport = ContractTransport()
            await transport.configure(payload: try JSONEncoder().encode(pluginFeed(rows)))
            let result = try await contractClient(transport).loadHomeRows(contract: .plugin)
            #expect(result.feed.rows.map(\.id) == rows.map(\.id))
            #expect(result.serverError == nil)
            #expect(await transport.requests.count == 1)
        }
    }
    @Test(arguments: [0, 401, 403, 404, 503])
    func failureFallsBackWithoutLegacyProbeAndRecovers(status: Int) async throws {
        let transport = ContractTransport()
        await transport.configure(status: status)
        let client = try contractClient(transport)
        let failed = try await client.loadHomeRows(contract: .plugin)
        #expect(failed.serverError != nil)
        #expect(failed.feed.rows.contains { $0.id == "short-movies" && $0.cards.first?.item.id == "local" })
        #expect(await transport.requests.allSatisfy { !$0.url!.path.contains("/support/") && !$0.url!.path.contains("/Sections") })
        await transport.configure()
        let recovered = try await client.loadHomeRows(contract: .plugin)
        #expect(recovered.serverError == nil)
        #expect(recovered.feed.rows.isEmpty)
    }
    @Test func pluginRowsKeepALaunchSnapshotButAlwaysFetch() async throws {
        let server = try ServerAddress("https://example.test/jellyfin")
        let cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let transport = ContractTransport(), client = try contractClient(transport, cache: cache)
        await #expect(throws: LibraryCacheMiss.self) { try await client.readingCache().homeFeed(contract: .plugin) }
        _ = try await client.homeFeed(contract: .plugin)
        _ = try await client.homeFeed(contract: .plugin)
        #expect(await transport.requests.count == 2)
        #expect(try await client.readingCache().homeFeed(contract: .plugin).schemaVersion == 1)
        _ = try await client.homeFeed(contract: .plugin, fresh: true)
        #expect(await transport.requests.last?.url?.query == "fresh=true&taste=true")
    }
    @Test func pluginNeverUsesOrPopulatesLegacyHomeCache() async throws {
        let server = try ServerAddress("https://example.test/jellyfin")
        let cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let transport = ContractTransport(), client = try contractClient(transport, cache: cache)
        _ = try await client.homeFeed() // Seed legacy cache.
        _ = try await client.homeFeed(contract: .plugin)
        await transport.configure(status: 404)
        await #expect(throws: ClientError.unavailable(404)) { try await client.homeFeed(contract: .plugin) }
        await #expect(throws: LibraryCacheMiss.self) { try await client.readingCache().homeFeed(contract: .plugin) }
        #expect(try await client.readingCache().homeFeed().schemaVersion == 1)
        #expect(await transport.requests.filter { $0.url!.path.hasSuffix("/Zorofin/Home/Rows") }.count == 2)
    }
    @Test func malformedSchemaAndDuplicateRowsReject() async throws {
        var wrongSchema = pluginFeed()
        wrongSchema = HomeFeed(schemaVersion: 2, generatedAt: wrongSchema.generatedAt, preferences: wrongSchema.preferences, rows: [])
        let duplicate = HomeRow(id: "popular", title: "Popular", description: "", cards: [])
        for payload in [try JSONEncoder().encode(wrongSchema), try JSONEncoder().encode(pluginFeed([duplicate, duplicate])),
                        Data(#"{"schemaVersion":1,"rows":"bad"}"#.utf8)] {
            let transport = ContractTransport()
            await transport.configure(payload: payload)
            await #expect(throws: (any Error).self) { try await contractClient(transport).homeFeed(contract: .plugin) }
        }
    }
    @Test func teamsUseSharedDisplayPreferencesWithoutV2Writes() async throws {
        let transport = ContractTransport(), client = try contractClient(transport)
        #expect(try await client.homeTeams(serverFallback: false) == ["Boston Celtics"])
        try await client.saveHomeTeams(["New York Knicks"])
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url!.path == "/jellyfin/DisplayPreferences/zorofin-home" })
        let write = try #require(requests.last)
        let body = try JSONSerialization.jsonObject(with: #require(write.httpBody)) as! [String: Any]
        #expect((body["CustomPrefs"] as? [String: String])?["other"] == "keep")
        #expect((body["CustomPrefs"] as? [String: String])?["zorofinTeams"] == #"["New York Knicks"]"#)
    }
    @Test func cacheAndTokensStayWithinTheirServerAndAccount() async throws {
        let server = try ServerAddress("https://example.test/jellyfin")
        let oldCache = LibraryResponseCache(server: server, viewerID: "old", root: nil)
        let transport = ContractTransport()
        let client = try contractClient(transport, viewer: "new", token: "new-token", base: "https://other.test/base", cache: oldCache)
        #expect(client.responseCache == nil)
        _ = try await client.homeFeed(contract: .plugin)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host == "other.test")
        #expect(request.url?.path == "/base/Zorofin/Home/Rows")
        #expect(request.value(forHTTPHeaderField: "X-Jellyfin-Token") == "new-token")
    }
}
