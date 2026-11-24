
import Foundation
import Testing
@testable import ZorofinCore

private actor AdminTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let admin: Bool
    let quickConnect: Bool
    let mismatch: Bool
    init(admin: Bool = true, quickConnect: Bool = true, mismatch: Bool = false) {
        self.admin = admin; self.quickConnect = quickConnect; self.mismatch = mismatch
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        var status = 200
        let body: String
        switch path {
        case "/base/Users/Me":
            let web = request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"web-fixture\"") == true
            body = "{\"Id\":\"\(web && mismatch ? "other-viewer" : "viewer")\",\"Name\":\"Admin\",\"Policy\":{\"IsAdministrator\":\(admin)}}"
        case "/base/System/Info/Public": body = #"{"Id":"server-id","Version":"12.2.0"}"#
        case "/base/QuickConnect/Initiate":
            status = quickConnect ? 200 : 401
            body = #"{"Authenticated":false,"Code":"123456","Secret":"secret-fixture"}"#
        case "/base/QuickConnect/Authorize": body = "true"
        case "/base/Users/AuthenticateWithQuickConnect": body = #"{"AccessToken":"web-fixture","User":{"Id":"viewer","Name":"Admin"},"ServerId":"server-id"}"#
        case "/base/Sessions/Logout": body = ""
        default: body = ""; status = 404
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func adminClient(_ transport: AdminTransport) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    let session = Session(server: server, viewer: .init(id: "viewer", name: "Admin"), token: "native-fixture", deviceID: "native-device")
    return JellyfinClient(server: server, identity: .init(deviceID: "native-device", deviceName: "Phone"), session: session, transport: transport)
}

@Suite("Embedded administration account boundaries") struct AdminWebTests {
    @Test(arguments: ["https://media.example", "https://media.example/jellyfin", "http://127.0.0.1:8096/media%20server"])
    func dashboardURLRetainsServerBasePathWithoutCredentials(_ address: String) throws {
        let server = try ServerAddress(address, allowsLocalHTTP: true)
        let url = try server.dashboardWebURL()
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.fragment == "/dashboard")
        #expect(parts.query == nil)
        #expect(parts.user == nil && parts.password == nil)
        #expect(parts.percentEncodedPath == (try #require(URLComponents(url: server.endpoint(["web"]), resolvingAgainstBaseURL: false))).percentEncodedPath + "/")
        let access = AdminWebSession(server: server, viewer: .init(id: "a", name: "A"), serverID: "id", browserClient: nil)
        #expect(access.permitsNavigation(to: url))
    }

    @Test func isolatedSessionUsesFreshPermissionsAndASeparateToken() async throws {
        let transport = AdminTransport()
        let access = try await adminClient(transport).adminWebSession()
        #expect(!access.requiresSignIn)
        #expect(access.browserClient?.session?.token == "web-fixture")
        #expect(access.browserClient?.identity.deviceID != "native-device")
        let requests = await transport.requests
        #expect(requests.first?.url?.path == "/base/Users/Me")
        #expect(requests.filter { $0.url?.path == "/base/QuickConnect/Authorize" }.count == 1)
        let auth = requests.first { $0.url?.path == "/base/QuickConnect/Authorize" }
        #expect(auth?.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"native-fixture\"") == true)
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"web-fixture\"") == true)
        await access.close()
        let logout = await transport.requests.last
        #expect(logout?.url?.path == "/base/Sessions/Logout")
        #expect(logout?.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"web-fixture\"") == true)
    }

    @Test func ordinaryViewerCannotCreateAnAdminBrowser() async throws {
        let transport = AdminTransport(admin: false)
        await #expect(throws: ClientError.forbidden) { try await adminClient(transport).adminWebSession() }
        #expect(await transport.requests.count == 1)
    }

    @Test func disabledQuickConnectFallsBackWithoutSharingNativeToken() async throws {
        let transport = AdminTransport(quickConnect: false)
        let access = try await adminClient(transport).adminWebSession()
        #expect(access.requiresSignIn)
        #expect(try access.bootstrapScript() == nil)
        await access.close()
        #expect(await transport.requests.count == 3)
    }

    @Test func wrongWebViewerIsRevokedAndNeverPresented() async throws {
        let transport = AdminTransport(mismatch: true)
        await #expect(throws: ClientError.forbidden) { try await adminClient(transport).adminWebSession() }
        let last = await transport.requests.last
        #expect(last?.url?.path == "/base/Sessions/Logout")
        #expect(last?.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"web-fixture\"") == true)
    }

    @Test(arguments: ["https://media.example/base/web/#/dashboard", "https://media.example:443/base/web/index.html#!/metadata", "https://media.example/base/System/Info"])
    func allowsSelectedServerAndHashRoutes(_ url: String) throws {
        let server = try ServerAddress("https://media.example/base")
        let access = AdminWebSession(server: server, viewer: .init(id: "a", name: "A"), serverID: "id", browserClient: nil)
        #expect(access.permitsNavigation(to: URL(string: url)!))
    }

    @Test(arguments: ["https://elsewhere.example/base/web/", "http://media.example/base/web/", "https://media.example:444/base/web/", "https://media.example/other/web/", "https://media.example/baseball/web/", "https://user:password@media.example/base/web/", "https://media.example/base/%2e%2e/other/", "https://media.example/base/web/?ApiKey=fixture", "https://media.example/base/web/?api_key=fixture", "javascript:alert(1)", "file:///private/file"])
    func blocksEscapesAndCredentialURLs(_ url: String) throws {
        let access = AdminWebSession(server: try ServerAddress("https://media.example/base"), viewer: .init(id: "a", name: "A"), serverID: "id", browserClient: nil)
        #expect(!access.permitsNavigation(to: URL(string: url)!))
    }

    @Test func bootstrapSerializesOnlyTheWebToken() async throws {
        let transport = AdminTransport()
        let access = try await adminClient(transport).adminWebSession()
        let generated = try access.bootstrapScript()
        let script = try #require(generated)
        #expect(!script.contains("native-fixture"))
        #expect(!script.contains("web-fixture"))
        let encoded = try #require(script.components(separatedBy: "atob('").dropFirst().first?.components(separatedBy: "')").first)
        let data = try #require(Data(base64Encoded: encoded))
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["origin"] as? String == "https://media.example")
        let credentials = try #require(value["credentials"] as? [String: Any])
        let servers = try #require(credentials["Servers"] as? [[String: Any]])
        #expect(servers.count == 1)
        #expect(servers[0]["Id"] as? String == "server-id")
        #expect(servers[0]["ManualAddress"] as? String == "https://media.example/base")
        #expect(servers[0]["AccessToken"] as? String == "web-fixture")
        #expect(servers[0]["UserId"] as? String == "viewer")
        await access.close()
    }
    @Test func bootstrapNormalizesDefaultPortsAndEncodedBasePaths() throws {
        let server = try ServerAddress("https://media.example:443/media%20server")
        let identity = ClientIdentity(deviceID: "web-device", deviceName: "Web")
        let viewer = Viewer(id: "viewer", name: "Admin")
        let session = Session(server: server, viewer: viewer, token: "fixture-only", deviceID: identity.deviceID)
        let browser = JellyfinClient(server: server, identity: identity, session: session)
        let access = AdminWebSession(server: server, viewer: viewer, serverID: "server-id", browserClient: browser)
        let generated = try access.bootstrapScript()
        let script = try #require(generated)
        let encoded = try #require(script.components(separatedBy: "atob('").dropFirst().first?.components(separatedBy: "')").first)
        let data = try #require(Data(base64Encoded: encoded))
        let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["origin"] as? String == "https://media.example")
        #expect(value["webPath"] as? String == "/media%20server/web/")
    }

}
