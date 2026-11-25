import Foundation
import Testing
@testable import ZorofinCore

/// Holds authorized reads until a simultaneous, optional Home request is denied.
/// The ordering is deterministic and does not depend on server/network timing.
private actor HomePermissionRaceTransport: HTTPTransport {
    let denialStatus: Int
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var waitingForReads: (Int, CheckedContinuation<Void, Never>)?

    init(denialStatus: Int) { self.denialStatus = denialStatus }

    func waitForReads(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { waitingForReads = (count, $0) }
    }

    func releaseReads() {
        let readers = pending; pending = []
        for reader in readers { reader.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let denied = request.url!.path.contains("/LiveTv/") || request.url!.path.hasSuffix("/Zorofin/Home/Rows")
        if !denied {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                if let (count, waiter) = waitingForReads, pending.count >= count {
                    waitingForReads = nil; waiter.resume()
                }
            }
        }
        let payload = request.url!.path.hasSuffix("/NextUp") ? #"{"Items":[],"TotalRecordCount":0}"# :
            #"{"Items":[{"Id":"movie-1","Name":"Fixture movie","Type":"Movie"}],"TotalRecordCount":1}"#
        return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: denied ? denialStatus : 200,
                                                  httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Home permission isolation") struct HomePermissionRaceTests {
    @Test(arguments: [403, 401])
    func deniedOptionalFeatureOnlyCancelsHomeForExpiredAuthentication(status: Int) async throws {
        let server = try ServerAddress("https://home.example/jellyfin")
        let cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let transport = HomePermissionRaceTransport(denialStatus: status)
        let client = JellyfinClient(server: server, identity: .init(deviceID: "test", deviceName: "Fixture"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Fixture"), token: "fixture", deviceID: "test"),
            transport: transport, responseCache: cache)
        let movies = Task { try await client.items(type: "Movie") }
        let continued = Task { try await client.continueWatching() }
        await transport.waitForReads(3)
        await #expect(throws: status == 403 ? ClientError.forbidden : ClientError.unauthorized) {
            _ = try await client.liveTVSnapshot()
        }
        await transport.releaseReads()

        if status == 403 {
            #expect(try await movies.value.items.map(\.id) == ["movie-1"])
            #expect(try await continued.value.items.map(\.id) == ["movie-1"])
            #expect(try await client.readingCache().resume().items.map(\.id) == ["movie-1"])
        } else {
            await #expect(throws: CancellationError.self) { _ = try await movies.value }
            await #expect(throws: CancellationError.self) { _ = try await continued.value }
            await #expect(throws: LibraryCacheMiss.self) { _ = try await client.readingCache().resume() }
        }
    }
}


@Suite("Optional Home authentication isolation") struct OptionalHomePermissionTests {
    @Test(arguments: [401, 403])
    func deniedPluginKeepsConcurrentCoreReads(status: Int) async throws {
        let server = try ServerAddress("https://home.example/jellyfin")
        let cache = LibraryResponseCache(server: server, viewerID: "viewer", root: nil)
        let transport = HomePermissionRaceTransport(denialStatus: status)
        let client = JellyfinClient(server: server, identity: .init(deviceID: "test", deviceName: "Fixture"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Fixture"), token: "fixture", deviceID: "test"),
            transport: transport, responseCache: cache)
        let movies = Task { try await client.items(type: "Movie") }
        await transport.waitForReads(1)
        await #expect(throws: status == 401 ? ClientError.unauthorized : ClientError.forbidden) {
            _ = try await client.homeFeed(contract: .plugin)
        }
        await transport.releaseReads()
        #expect(try await movies.value.items.map(\.id) == ["movie-1"])
    }
}
