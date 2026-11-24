import Foundation
import Testing
@testable import ZorofinCore

private actor ProfileTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    let body: String
    init(status: Int = 200, body: String = "true") { self.status = status; self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private func profileClient(_ transport: any HTTPTransport, authenticated: Bool = true) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/jellyfin")
    let identity = ClientIdentity(deviceID: "fixture-device", deviceName: "Fixture phone")
    let session = Session(server: server, viewer: Viewer(id: "fixture-viewer", name: "Viewer"),
                          token: "fixture-token", deviceID: identity.deviceID)
    return JellyfinClient(server: server, identity: identity, session: authenticated ? session : nil, transport: transport)
}

@Suite("Profile account boundaries") struct ProfileTests {
    @Test func olderSavedViewerDoesNotGainAdministrationAccess() throws {
        let old = try JSONDecoder().decode(Viewer.self, from: Data(#"{"id":"viewer","name":"Viewer"}"#.utf8))
        #expect(old.policy?.isAdministrator != true)
        let current = try Wire.decoder().decode(Viewer.self,
            from: Data(#"{"Id":"viewer","Name":"Viewer","Policy":{"IsAdministrator":true}}"#.utf8))
        #expect(current.policy?.isAdministrator == true)
        let ordinary = try Wire.decoder().decode(Viewer.self,
            from: Data(#"{"Id":"viewer","Name":"Viewer","Policy":{"IsAdministrator":false}}"#.utf8))
        #expect(ordinary.policy?.isAdministrator == false)
    }

    @Test func quickConnectApprovesOnlyTheSignedInAccount() async throws {
        let transport = ProfileTransport()
        #expect(try await profileClient(transport).authorizeQuickConnect(code: "123456"))
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = requests[0]
        #expect(request.url?.path == "/jellyfin/QuickConnect/Authorize")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("Token=\"fixture-token\"") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query == [.init(name: "code", value: "123456")])
    }

    @Test(arguments: ["", "12345", "1234567", "１２３４５６", "12345\n", "12345a"])
    func invalidQuickConnectCodesNeverSend(_ code: String) async throws {
        let transport = ProfileTransport()
        await #expect(throws: ClientError.invalidQuickConnectCode) {
            try await profileClient(transport).authorizeQuickConnect(code: code)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func quickConnectFalseDoesNotClaimAuthorization() async throws {
        let transport = ProfileTransport(body: "false")
        #expect(try await !profileClient(transport).authorizeQuickConnect(code: "123456"))
        #expect(await transport.requests.count == 1)
    }

    @Test func quickConnectRequiresSessionAndRespectsDenial() async throws {
        let transport = ProfileTransport(status: 403, body: "denied")
        await #expect(throws: ClientError.missingSession) {
            try await profileClient(transport, authenticated: false).authorizeQuickConnect(code: "123456")
        }
        #expect(await transport.requests.isEmpty)
        await #expect(throws: ClientError.forbidden) {
            try await profileClient(transport).authorizeQuickConnect(code: "123456")
        }
        #expect(await transport.requests.count == 1)
    }
}
