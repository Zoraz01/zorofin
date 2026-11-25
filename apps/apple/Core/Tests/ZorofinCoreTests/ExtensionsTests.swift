import Foundation
import Testing
@testable import ZorofinCore

private actor ExtensionTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw ClientError.network }
        let response = responses.removeFirst()
        return (Data(response.1.utf8), HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!)
    }
}

private func extensionClient(_ transport: any HTTPTransport, token: String = "fixture-token",
                             address: String = "https://media.example/jellyfin") throws -> JellyfinClient {
    let server = try ServerAddress(address)
    return JellyfinClient(server: server, identity: .init(deviceID: "test", deviceName: "test"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: token, deviceID: "test"), transport: transport)
}

@Suite("Optional server services") struct ExtensionTests {
    @Test func plainServerHasNoExtras() async throws {
        let transport = ExtensionTransport([(404, ""), (404, ""), (200, #"{"notifications":[]}"#)])
        let result = try await extensionClient(transport).discoverFeatures()
        #expect(result.features == ServerFeatures())
        #expect(!result.needsRetry)
        // Only the two explicit capability routes are tried, never unrelated service probes.
        #expect(await transport.requests.count == 2)
        #expect(await transport.requests[0].httpMethod == "GET")
    }

    @Test(arguments: ["media.example", "  MEDIA.example/  ", "https://media.example", "https://media.example:443/"])
    func enteredAddressIsCanonicalized(_ input: String) throws {
        #expect(try ServerAddress.fromUserInput(input).url.host == "media.example")
    }

    @Test func bareGenericAddressRetainsBasePathAndExistingHTTPRules() throws {
        let server = try ServerAddress.fromUserInput("media.example/jellyfin")
        #expect(server.url.absoluteString == "https://media.example/jellyfin/")
        #expect(throws: ClientError.invalidServer) { try ServerAddress.fromUserInput(" ") }
        #expect(throws: ClientError.invalidServer) { try ServerAddress.fromUserInput("media.example@evil.example") }
        #expect(throws: ClientError.insecureServer) { try ServerAddress.fromUserInput("http://media.example", allowsLocalHTTP: true) }
        #expect(try ServerAddress.fromUserInput("http://192.168.1.2:8096", allowsLocalHTTP: true).url.scheme == "http")
    }

    @Test func selectedSchemePreservesAddressPortAndBasePath() throws {
        let server = try ServerAddress.fromUserInput("  192.168.1.20:8096/jellyfin  ",
            defaultScheme: .http, allowsLocalHTTP: true)
        #expect(server.url.absoluteString == "http://192.168.1.20:8096/jellyfin/")
        #expect(try ServerAddress.fromUserInput("media.example:8920/jellyfin").url.absoluteString
            == "https://media.example:8920/jellyfin/")
        #expect(try ServerAddress.fromUserInput("https://media.example/jellyfin", defaultScheme: .http,
            allowsLocalHTTP: true).url.scheme == "https")
        #expect(try ServerAddress.fromUserInput("http://[::1]:8096/jellyfin", defaultScheme: .https,
            allowsLocalHTTP: true).url.scheme == "http")
    }

    @Test func selectedHTTPDoesNotBypassAddressSafety() throws {
        #expect(throws: ClientError.insecureServer) {
            try ServerAddress.fromUserInput("media.example", defaultScheme: .http, allowsLocalHTTP: true)
        }
        #expect(throws: ClientError.insecureServer) {
            try ServerAddress.fromUserInput("192.168.1.20:8096", defaultScheme: .http)
        }
        for input in ["", "user:password@192.168.1.20", "192.168.1.20?ApiKey=secret", "ftp://192.168.1.20"] {
            #expect(throws: ClientError.invalidServer) {
                try ServerAddress.fromUserInput(input, defaultScheme: .http, allowsLocalHTTP: true)
            }
        }
    }

    @Test(arguments: ["192.168.1.50:8096", "10.0.0.5:8096/jellyfin", "100.101.102.103:8096",
                      "169.254.10.2:8096", "jellyfin.local:8096", "localhost:8096", "[fd12:3456::1]:8096",
                      "[fe80::1]:8096"])
    func bareLocalAddressFallsBackToHTTPAfterHTTPS(_ input: String) throws {
        let candidates = try ServerAddress.connectionCandidates(input)
        #expect(candidates.map { $0.url.scheme } == ["https", "http"])
        #expect(candidates[0].allowsLocalHTTP == false)
        #expect(candidates[1].allowsLocalHTTP)
        #expect(candidates[0].url.host == candidates[1].url.host)
        #expect(candidates[0].url.port == candidates[1].url.port)
        #expect(candidates[0].url.path == candidates[1].url.path)
    }

    @Test func httpFallbackIsLimitedToBareLocalAddresses() throws {
        // Public hosts and public IPs never fall back to HTTP.
        for input in ["media.example", "media.example:8096", "8.8.8.8:8096", "100.128.0.1:8096",
                      "172.32.0.1:8096", "[2001:db8::1]:8096"] {
            #expect(try ServerAddress.connectionCandidates(input).count == 1)
        }
        // A typed scheme or an explicit HTTP selection is used exactly as given.
        #expect(try ServerAddress.connectionCandidates("https://192.168.1.50:8096").map { $0.url.scheme } == ["https"])
        #expect(try ServerAddress.connectionCandidates("http://192.168.1.50:8096", allowsLocalHTTP: true)
            .map { $0.url.scheme } == ["http"])
        #expect(try ServerAddress.connectionCandidates("192.168.1.50:8096", defaultScheme: .http,
            allowsLocalHTTP: true).map { $0.url.scheme } == ["http"])
        #expect(throws: ClientError.insecureServer) {
            try ServerAddress.connectionCandidates("http://192.168.1.50:8096")
        }
        #expect(throws: ClientError.invalidServer) {
            try ServerAddress.connectionCandidates("user:pw@192.168.1.50:8096")
        }
    }

    @Test func localHostRecognisesPrivateRangesOnly() {
        for host in ["10.1.2.3", "127.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.50",
                     "169.254.1.1", "100.64.0.1", "100.127.255.255", "localhost", "nas.local",
                     "[::1]", "::1", "fd00::1", "[fc00::1]", "fe80::1", "febf::1", "fe80::1%en0"] {
            #expect(ServerAddress.isLocalHost(host), "\(host)")
        }
        for host in ["8.8.8.8", "100.63.0.1", "100.128.0.1", "172.15.0.1", "192.169.0.1",
                     "a.10.1.2.3", "10.1.2", "10.1.2.3.4", "1e1.0.0.1", "2001:db8::1", "fec0::1",
                     "fe80", "media.example", ""] {
            #expect(!ServerAddress.isLocalHost(host), "\(host)")
        }
    }

    @Test func existingServerAdapterAdvertisesExtrasWithoutAnAddressAllowlist() async throws {
        let body = #"{"schemaVersion":1,"features":{"support":{"version":1,"enabled":true},"requests":{"version":1,"enabled":true},"liveArtwork":{"version":1,"enabled":true},"enhancedSettings":{"version":1,"enabled":true},"accountApprovals":{"version":1,"enabled":true},"notificationSettings":{"version":1,"enabled":true}}}"#
        let transport = ExtensionTransport([(404, ""), (200, body)])
        let result = try await extensionClient(transport).discoverFeatures()
        #expect(result.features == .init(support: true, requests: true, liveArtwork: true,
            enhancedSettings: true, accountApprovals: true, notificationSettings: true))
        #expect(!result.needsRetry)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/jellyfin/Zorofin/Capabilities", "/jellyfin/support/capabilities"])
        #expect(requests.allSatisfy { $0.url?.host == "media.example" && $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token" })
    }

    @Test func discoveryDoesNotBypassSignInOrServerBinding() async throws {
        let transport = ExtensionTransport([])
        let other = try ServerAddress("https://elsewhere.example")
        let generic = try extensionClient(transport)
        let anonymous = JellyfinClient(server: other, identity: generic.identity, transport: transport)
        await #expect(throws: ClientError.missingSession) { try await anonymous.discoverFeatures() }
        let misplaced = JellyfinClient(server: other, identity: generic.identity, session: generic.session, transport: transport)
        await #expect(throws: ClientError.unsafeURL) { try await misplaced.discoverFeatures() }
        #expect(await transport.requests.isEmpty)
    }

    @Test func advertisedSupportStillRequiresServerPermission() async throws {
        let transport = ExtensionTransport([(200, #"{"schemaVersion":1,"features":{"support":{"version":1,"enabled":true}}}"#), (403, "")])
        let client = try extensionClient(transport)
        #expect(try await client.discoverFeatures().features.support)
        await #expect(throws: SupportError.rejected) {
            try await client.submitSupport(.init(issueType: "Other", description: "An issue"))
        }
        #expect(await transport.requests.count == 2)
    }

    @Test func disabledPrimaryManifestDoesNotConsultAdapter() async throws {
        let transport = ExtensionTransport([(200, #"{"schemaVersion":1,"features":{}}"#)])
        #expect(try await extensionClient(transport).discoverFeatures().features == .init())
        #expect(await transport.requests.count == 1)
    }

    @Test func invalidAdapterDoesNotEnableFeatures() async throws {
        let transport = ExtensionTransport([(404, ""), (200, #"{"notifications":[]}"#)])
        await #expect(throws: ClientError.invalidResponse) { try await extensionClient(transport).discoverFeatures() }
        #expect(await transport.requests.count == 2)
    }

    @Test func manifestRespectsVersionsAndExplicitDisable() async throws {
        let transport = ExtensionTransport([(200, #"{"schemaVersion":1,"features":{"support":{"version":1,"enabled":true},"notifications":{"version":2,"enabled":true},"requests":{"version":1,"enabled":false}}}"#)])
        let result = try await extensionClient(transport).discoverFeatures()
        #expect(result.features == ServerFeatures(support: true))
        #expect(await transport.requests.count == 1)
    }

    @Test(arguments: [#"{"schemaVersion":2,"features":{}}"#, "{}", "<html>Sign in</html>"])
    func invalidManifestNeverFallsBack(_ body: String) async throws {
        let transport = ExtensionTransport([(200, body)])
        await #expect(throws: ClientError.invalidResponse) { try await extensionClient(transport).discoverFeatures() }
        #expect(await transport.requests.count == 1)
    }

    @Test func deniedManifestNeverProbesLegacyRoutes() async throws {
        let transport = ExtensionTransport([(403, "")])
        await #expect(throws: ClientError.forbidden) { try await extensionClient(transport).discoverFeatures() }
        #expect(await transport.requests.count == 1)
    }

    @Test func futureExtensionDiscoveryUsesOnlyAuthenticatedSameServerReads() async throws {
        let transport = ExtensionTransport([(200, #"{"schemaVersion":1,"features":{"support":{"version":1,"enabled":true},"notifications":{"version":1,"enabled":true},"requests":{"version":1,"enabled":true}}}"#)])
        let result = try await extensionClient(transport).discoverFeatures()
        #expect(result.features == ServerFeatures(support: true, notifications: true, requests: true))
        #expect(!result.needsRetry)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/jellyfin/Zorofin/Capabilities"])
        #expect(requests.allSatisfy { $0.url?.host == "media.example" && $0.url?.query == nil && $0.httpMethod == "GET" && $0.httpBody == nil })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token" })
    }

    @Test func genericExtensionOutageDoesNotProbeOtherServices() async throws {
        let transport = ExtensionTransport([(503, "")])
        await #expect(throws: ClientError.unavailable(503)) { try await extensionClient(transport).discoverFeatures() }
        #expect(await transport.requests.count == 1)
    }

    @Test func unrelatedJSONDoesNotEnableSupport() async throws {
        let transport = ExtensionTransport([(200, "{}")])
        await #expect(throws: ClientError.invalidResponse) { try await extensionClient(transport).discoverFeatures() }
        #expect(await transport.requests.count == 1)
    }

    @Test func pluginRequestsVersionTwoUsesZorofinRoutes() async throws {
        let manifest = #"{"schemaVersion":1,"features":{"requests":{"version":2,"enabled":true}}}"#
        let transport = ExtensionTransport([(200, manifest), (200, #"{"active":true,"userFound":true}"#)])
        let client = try extensionClient(transport, address: "https://plugin-v2.example/jellyfin")
        #expect(try await client.discoverFeatures().features == ServerFeatures(requests: true))
        #expect(client.requestRoutes == .zorofin)
        #expect(try await client.requestAccess().available)
        #expect(await transport.requests.last?.url?.path == "/jellyfin/Zorofin/Requests/user-status")
    }

    @Test func enhancedRequestsVersionOneKeepsJellyfinEnhancedRoutes() async throws {
        let manifest = #"{"schemaVersion":1,"features":{"requests":{"version":1,"enabled":true}}}"#
        let transport = ExtensionTransport([(200, manifest), (200, "{}")])
        let client = try extensionClient(transport, address: "https://enhanced-v1.example/jellyfin")
        #expect(try await client.discoverFeatures().features == ServerFeatures(requests: true))
        #expect(client.requestRoutes == .enhanced)
        _ = try await client.requestQuota()
        #expect(await transport.requests.last?.url?.path == "/jellyfin/JellyfinEnhanced/jellyseerr/quota")
    }

    @Test(arguments: [#"{"version":3,"enabled":true}"#, #"{"version":2,"enabled":false}"#])
    func unknownOrDisabledRequestsStayOff(_ feature: String) async throws {
        let manifest = #"{"schemaVersion":1,"features":{"requests":"# + feature + "}}"
        let transport = ExtensionTransport([(200, manifest)])
        let client = try extensionClient(transport, address: "https://requests-off.example/jellyfin")
        #expect(try await client.discoverFeatures().features == ServerFeatures())
    }

    @Test func requestRoutesAreRememberedPerServerAndViewer() throws {
        let server = try ServerAddress("https://routes.example")
        RequestRoutes.remember(.zorofin, server: server, viewer: "a")
        #expect(RequestRoutes.current(server: server, viewer: "a") == .zorofin)
        #expect(RequestRoutes.current(server: server, viewer: "b") == .enhanced)
        #expect(RequestRoutes.current(server: try ServerAddress("https://other-routes.example"), viewer: "a") == .enhanced)
        RequestRoutes.remember(nil, server: server, viewer: "a")
        #expect(RequestRoutes.current(server: server, viewer: "a") == .enhanced)
    }

    @Test func everyRouteHasAPluginPath() {
        let routes: [RequestRoutes.Route] = [.userStatus, .configuration, .quota, .seasonSettings, .submit,
                                             .activity, .queue, .search, .discover(["movies", "upcoming"]), .title(.tv, 20)]
        let plugin = routes.map { RequestRoutes.zorofin.path($0).joined(separator: "/") }
        #expect(plugin == ["Zorofin/Requests/user-status", "Zorofin/Requests/config", "Zorofin/Requests/quota",
                           "Zorofin/Requests/settings/partial-requests", "Zorofin/Requests/request", "Zorofin/Requests/activity",
                           "Zorofin/Requests/queue", "Zorofin/Requests/search", "Zorofin/Requests/discover/movies/upcoming",
                           "Zorofin/Requests/tv/20"])
        #expect(routes.allSatisfy { RequestRoutes.enhanced.path($0).first == "JellyfinEnhanced" })
    }

    @Test func ticketIsOneCamelCasePostWithExplicitReceipt() async throws {
        let transport = ExtensionTransport([(202, #"{"ticketId":"Tabc12345","message":"Received"}"#)])
        let id = try await extensionClient(transport).submitSupport(.init(issueType: "Other", description: " Playback stopped ", affectedMedia: "Example"))
        #expect(id == "Tabc12345")
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/jellyfin/support/ticket")
        #expect(requests[0].value(forHTTPHeaderField: "X-Jellyfin-Token") == "fixture-token")
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
        #expect(body == ["issueType":"Other", "description":"Playback stopped", "affectedMedia":"Example"])
    }

    @Test(arguments: [(200, #"{"ticketId":"Tabc12345"}"#), (202, "{}"), (202, #"{"ticketId":"../other"}"#), (500, ""), (503, "")])
    func uncertainSubmissionIsNeverRetried(_ response: (Int, String)) async throws {
        let transport = ExtensionTransport([response])
        await #expect(throws: SupportError.outcomeUnknown) {
            try await extensionClient(transport).submitSupport(.init(issueType: "Other", description: "An issue"))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func lostConnectionAfterSendingIsUnconfirmed() async throws {
        let transport = ExtensionTransport([])
        await #expect(throws: SupportError.outcomeUnknown) {
            try await extensionClient(transport).submitSupport(.init(issueType: "Other", description: "An issue"))
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func rejectsReportUsingServerUTF16LimitsBeforeSending() async throws {
        let transport = ExtensionTransport([])
        let report = SupportReport(issueType: "Other", description: String(repeating: "😀", count: 751))
        #expect(!report.isValid)
        await #expect(throws: SupportError.invalidReport) { try await extensionClient(transport).submitSupport(report) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func readRequiresValidIDAnd204Acknowledgement() async throws {
        let transport = ExtensionTransport([(204, ""), (200, "{}")])
        let client = try extensionClient(transport)
        await #expect(throws: ClientError.unsafeURL) { try await client.markSupportReplyRead("Tabc12345\n") }
        await #expect(throws: ClientError.unsafeURL) { try await client.markSupportReplyRead("../other") }
        #expect(await transport.requests.isEmpty)
        try await client.markSupportReplyRead("Tabc12345")
        let request = await transport.requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/jellyfin/support/notifications/Tabc12345/read")
        await #expect(throws: ClientError.invalidResponse) { try await client.markSupportReplyRead("Tabc12345") }
    }

    @Test func replyDecodingRetainsAccountMessage() async throws {
        let transport = ExtensionTransport([(200, #"{"notifications":[{"id":"Tabc12345","status":"resolved","issueType":"Other","message":"Fixed","updatedAt":"2026-10-16T12:00:00Z"}]}"#)])
        let replies = try await extensionClient(transport).supportReplies()
        #expect(replies.count == 1)
        #expect(replies[0].message == "Fixed")
    }

    @Test func extensionCredentialsCannotCrossServersOrInjectHeaders() async throws {
        let transport = ExtensionTransport([])
        let original = try extensionClient(transport)
        let misplaced = JellyfinClient(server: try ServerAddress("https://elsewhere.example"), identity: original.identity,
                                        session: original.session, transport: transport)
        await #expect(throws: ClientError.unsafeURL) { try await misplaced.discoverFeatures() }
        await #expect(throws: ClientError.missingSession) { try await extensionClient(transport, token: "bad\r\nheader").discoverFeatures() }
        #expect(await transport.requests.isEmpty)
    }
}

@Suite("Sports capability") struct SportsCapabilityTests {
    @Test func advertisedSportsModuleIsDiscovered() async throws {
        let transport = ExtensionTransport([(200, #"{"schemaVersion":1,"features":{"sportsEvents":{"version":1,"enabled":true},"notificationReads":{"version":1,"enabled":true},"liveTvStreams":{"version":1,"enabled":true}}}"#)])
        let server = try ServerAddress("https://media.example/jellyfin")
        let client = JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Fixture"), session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture", deviceID: "fixture"), transport: transport)
        let result = try await client.discoverFeatures()
        #expect(result.features.sportsEvents && result.features.liveTvStreams && result.features.notificationReads)
        #expect(!ServerFeatures().sportsEvents)
    }
}
