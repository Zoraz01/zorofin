import Foundation
import Testing
@testable import ZorofinCore

private actor LooksTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    let response: String
    init(status: Int = 200, _ response: String) { self.status = status; self.response = response }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private func looksClient(_ transport: any HTTPTransport) throws -> JellyfinClient {
    let address = try ServerAddress("https://media.example/jellyfin")
    return JellyfinClient(server: address, identity: .init(deviceID: "fixture", deviceName: "Test"),
        session: .init(server: address, viewer: .init(id: "viewer", name: "Viewer"), token: "viewer-token", deviceID: "fixture"), transport: transport)
}

@Suite("Server looks") struct ServerLooksTests {
    @Test func decodesAccentCardSizeAndEnforced() throws {
        let looks = try #require(ServerLooks.decode(Data(##"{"version":1,"colors":"ocean","accent":"#3d9cff","cardSize":"large","logo":"zorofin","enforced":false}"##.utf8)))
        #expect(looks.accent == 0x3d9cff)
        #expect(looks.cardSize == "large")
        #expect(looks.posterScale == 1.2)
        #expect(!looks.enforced)
    }
    @Test func zorofinGreenKeepsTheAppsOwnAndDefaultsAreSafe() throws {
        let green = try #require(ServerLooks.decode(Data(##"{"version":1,"colors":"zorofin","accent":"#42d779"}"##.utf8)))
        #expect(green.accent == nil)
        #expect(green.cardSize == "standard")
        #expect(green.enforced)
        let custom = try #require(ServerLooks.decode(Data(##"{"version":1,"colors":"custom","accent":"#42D779","cardSize":"huge"}"##.utf8)))
        #expect(custom.accent == nil)
        #expect(custom.posterScale == 1.0)
        #expect(ServerLooks.decode(Data(##"{"version":2,"accent":"#3d9cff"}"##.utf8)) == nil)
        #expect(ServerLooks.decode(Data(#"{"version":1,"accent":"blue"}"#.utf8))?.accent == nil)
    }
    @Test func darkAccentsAreLightenedUntilReadable() {
        let navy = ServerLooks.readableAccent(0x102060)
        #expect(navy != 0x102060)
        #expect(ServerLooks.luminance(navy) >= 0.22)
        #expect(navy & 0xff > (navy >> 16) & 0xff)
        #expect(ServerLooks.readableAccent(0x9d7bff) == 0x9d7bff)
    }
    @Test func fetchesThePluginLooksFileAndTreatsMissingAsNone() async throws {
        let transport = LooksTransport(##"{"version":1,"colors":"rose","accent":"#ff6b9a","cardSize":"compact","enforced":true}"##)
        let looks = try await looksClient(transport).serverLooks()
        #expect(looks?.accent == 0xff6b9a)
        #expect(looks?.posterScale == 0.85)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/jellyfin/Zorofin/Web/ui/looks.json")
        #expect(try await looksClient(LooksTransport(status: 404, "")).serverLooks() == nil)
    }
    @Test func cacheKeepsLooksPerServer() throws {
        let suite = "ServerLooksTests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cache = ServerLooksCache(suiteName: suite)
        let home = try ServerAddress("https://media.example/jellyfin"), other = try ServerAddress("https://other.example")
        let looks = ServerLooks(accent: 0xf5a524, cardSize: "large", enforced: false)
        cache.save(looks, server: home)
        #expect(cache.load(home) == looks)
        #expect(cache.load(other) == nil)
        cache.save(nil, server: home)
        #expect(cache.load(home) == nil)
    }
}
