import Foundation
import Testing
@testable import ZorofinCore

private let cacheServer = try! ServerAddress("https://cache.example/jellyfin")
private let pageJSON = #"{"Items":[{"Id":"movie-1","Name":"Fixture movie","MediaSources":[{"Id":"source","Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"Height":1600,"VideoRangeType":"HDR10"}],"OpenToken":"private-open-token","TranscodingUrl":"/stream?api_key=private-stream-token"}]}],"TotalRecordCount":1,"UnknownSecret":"not-for-disk"}"#
private actor CacheTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status = 200
    var payload = Data(pageJSON.utf8)
    var delay: Duration = .zero
    func configure(status: Int = 200, payload: String = pageJSON, delay: Duration = .zero) {
        self.status = status; self.payload = Data(payload.utf8); self.delay = delay
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay != .zero { try await Task.sleep(for: delay) }
        return (payload, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private func cachedClient(_ transport: CacheTransport, _ cache: LibraryResponseCache, viewer: String = "viewer-1") -> JellyfinClient {
    JellyfinClient(server: cacheServer, identity: .init(deviceID: "device", deviceName: "Fixture"),
        session: .init(server: cacheServer, viewer: .init(id: viewer, name: "Fixture"), token: "private-session-token", deviceID: "device"),
        transport: transport, responseCache: cache)
}
private func temporaryCacheDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("zorofin-cache-test-" + UUID().uuidString) }

@Suite("Account-scoped native caching") struct CacheTests {
    @Test func freshReadsAndConcurrentWaitersShareOneRequest() async throws {
        let transport = CacheTransport(), cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: nil)
        await transport.configure(delay: .milliseconds(40))
        let client = cachedClient(transport, cache)
        async let first = client.items(type: "Movie")
        async let second = client.items(type: "Movie")
        let pages = try await [first, second]
        #expect(pages.allSatisfy { $0.items.first?.id == "movie-1" })
        _ = try await client.items(type: "Movie")
        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        #expect(!request.url!.absoluteString.contains("MediaSources"))
        #expect(request.url!.absoluteString.contains("MediaStreams"))
    }
    @Test func snapshotNeverFetchesAndStaleDataRevalidates() async throws {
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer", root: nil)
        let transport = CacheTransport()
        await #expect(throws: LibraryCacheMiss.self) { try await cachedClient(transport, cache).readingCache().items() }
        #expect(await transport.requests.isEmpty)
        let stale = LibraryCachePolicy(storage: .memory, lifetime: 0, snapshotLifetime: 60)
        _ = try await cache.value("page", policy: stale) { Data("old".utf8) }
        #expect(await cache.snapshot("page", policy: stale) == Data("old".utf8))
        let fresh = try await cache.value("page", policy: stale) { Data("new".utf8) }
        #expect(fresh == Data("new".utf8))
    }
    @Test func restartUsesSanitizedDiskPagesAndNoCredentials() async throws {
        let root = temporaryCacheDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = CacheTransport(), cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: root)
        _ = try await cachedClient(transport, cache).items()
        let reopened = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: root)
        let page = try await cachedClient(transport, reopened).items()
        #expect(page.items.first?.name == "Fixture movie")
        #expect(page.items.first?.mediaSources == nil)
        #expect(page.items.first?.quality().thumbnailBadges == ["4K", "HDR10"])
        #expect(page.items.first?.quality().container == "MKV")
        #expect(await transport.requests.count == 1)
        let directory = root.appendingPathComponent(cache.scope)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        #expect(!contents.contains("token") && !contents.contains("Token") && !contents.contains("UnknownSecret"))
        #expect(!files[0].absoluteString.contains("viewer-1") && !files[0].absoluteString.contains("cache.example"))
    }
    @Test func customHomeRowsSurviveRestartWithoutPlaybackSources() async throws {
        let root = temporaryCacheDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let transport = CacheTransport()
        let feed = HomeFeed(generatedAt: "2026-10-17T00:00:00Z", preferences: .init(), rows: [
            HomeRow(id: "curated", title: "Curated", description: "", cards: [
                HomeRowCard(id: "movie", item: MediaItem(id: "movie", name: "Fixture"), subtitle: "")
            ])
        ])
        let payload = String(data: try Wire.encoder().encode(feed), encoding: .utf8)!
        await transport.configure(payload: payload)
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: root)
        _ = try await cachedClient(transport, cache).homeFeed()
        let reopened = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: root)
        let result = try await cachedClient(transport, reopened).readingCache().homeFeed()
        #expect(result.rows.first?.cards.first?.item.id == "movie")
        #expect(await transport.requests.count == 1)
    }
    @Test func scopesSeparateAccountsServersAndBasePaths() async throws {
        let root = temporaryCacheDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let first = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: root)
        let second = LibraryResponseCache(server: cacheServer, viewerID: "viewer-2", root: root)
        let third = LibraryResponseCache(server: try ServerAddress("https://cache.example/other"), viewerID: "viewer-1", root: root)
        let fourth = LibraryResponseCache(server: try ServerAddress("https://other.example/jellyfin"), viewerID: "viewer-1", root: root)
        #expect(Set([first.scope, second.scope, third.scope, fourth.scope]).count == 4)
        _ = try await first.value("same", policy: .artwork) { Data([1]) }
        #expect(await second.snapshot("same", policy: .artwork) == nil)
        let transport = CacheTransport()
        let mismatched = cachedClient(transport, first, viewer: "viewer-2")
        #expect(mismatched.responseCache == nil)
        _ = try await mismatched.items(); _ = try await mismatched.items()
        #expect(await transport.requests.count == 2)
    }
    @Test func mutationsInvalidateMetadataButKeepArtwork() async throws {
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: nil)
        let transport = CacheTransport(), client = cachedClient(transport, cache)
        _ = try await client.items()
        _ = try await cache.value("art", policy: .artwork) { Data([1, 2]) }
        await transport.configure(payload: #"{"IsFavorite":true}"#)
        _ = try await client.favorite(itemID: "movie-1", value: true)
        await #expect(throws: LibraryCacheMiss.self) { try await client.readingCache().items() }
        #expect(await cache.snapshot("art", policy: .artwork) == Data([1, 2]))
    }
    @Test func authenticationAndPermissionChecksAlwaysUseNetwork() async throws {
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: nil)
        let transport = CacheTransport(), client = cachedClient(transport, cache)
        await transport.configure(payload: #"{"Id":"viewer-1","Name":"Fixture"}"#)
        _ = try await client.currentViewer(); _ = try await client.currentViewer()
        #expect(await transport.requests.count == 2)
        await transport.configure(status: 401)
        await #expect(throws: ClientError.unauthorized) { try await client.items() }
        await #expect(throws: ClientError.unauthorized) { try await client.items() }
        #expect(await transport.requests.count == 4)
        await #expect(throws: LibraryCacheMiss.self) { try await client.readingCache().items() }
    }
    @Test func malformedResponsesAreEvicted() async throws {
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: nil)
        let transport = CacheTransport(), client = cachedClient(transport, cache)
        await transport.configure(payload: "not-json")
        await #expect(throws: ClientError.invalidResponse) { try await client.items() }
        await transport.configure()
        #expect(try await client.items().items.count == 1)
        #expect(await transport.requests.count == 2)
    }
    @Test func forbiddenResourceEvictsItsSnapshotWithoutEvictingOtherLibraryReads() async throws {
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: nil)
        let transport = CacheTransport(), client = cachedClient(transport, cache)
        _ = try await client.items()
        _ = try await client.requestData(["restricted"], cachePolicy: .detail)
        let deniedKey = try cacheServer.endpoint(["restricted"]).absoluteString
        #expect(await cache.snapshot(deniedKey, policy: .detail) != nil)
        await transport.configure(status: 403)
        // A fresh permission check can omit a cache policy entirely.
        await #expect(throws: ClientError.forbidden) { _ = try await client.requestData(["restricted"]) }
        #expect(await cache.snapshot(deniedKey, policy: .detail) == nil)
        #expect(try await client.readingCache().items().items.count == 1)
        #expect(await transport.requests.count == 3)
    }
    @Test func memoryOnlyDetailIsNeverPersisted() async throws {
        let root = temporaryCacheDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer", root: root)
        _ = try await cache.value("detail", policy: .detail) { Data("private-playback-source".utf8) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
    @Test func logoutCancelsPendingWritesAndErasesFiles() async throws {
        let root = temporaryCacheDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer", root: root)
        _ = try await cache.value("art", policy: .artwork) { Data([1]) }
        let started = AsyncStream<Void>.makeStream()
        let pending = Task {
            try await cache.value("late", policy: .artwork) {
                started.continuation.yield(())
                // An uncooperative transport must still not recreate logout files.
                try? await Task.sleep(for: .milliseconds(100))
                return Data([2])
            }
        }
        var signals = started.stream.makeAsyncIterator()
        await signals.next(); started.continuation.finish()
        await cache.close(purge: true)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(cache.scope).path))
        #expect(await cache.snapshot("art", policy: .artwork) == nil)
    }
    @Test func metadataInvalidationKeepsPendingArtworkAlive() async throws {
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer", root: nil)
        let started = AsyncStream<Void>.makeStream()
        let pending = Task {
            try await cache.value("art", policy: .artwork) {
                started.continuation.yield(())
                try await Task.sleep(for: .milliseconds(25))
                return Data([7])
            }
        }
        var signals = started.stream.makeAsyncIterator()
        await signals.next(); started.continuation.finish()
        await cache.invalidateMetadata()
        #expect(try await pending.value == Data([7]))
        #expect(await cache.snapshot("art", policy: .artwork) == Data([7]))
    }
    @Test func diskAndMemoryBudgetsAreEnforced() async throws {
        let root = temporaryCacheDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer", root: root, memoryLimit: 8, diskLimit: 12)
        for index in 0..<5 { _ = try await cache.value("art-\(index)", policy: .artwork) { Data(repeating: UInt8(index), count: 8) } }
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(cache.scope), includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        #expect(total <= 12)
        #expect(await cache.snapshot("art-0", policy: .artwork) == nil)
        #expect(await cache.snapshot("art-4", policy: .artwork) != nil)
    }
    @Test func cancellingOneWaiterDoesNotCancelOtherReaders() async throws {
        let cache = LibraryResponseCache(server: cacheServer, viewerID: "viewer-1", root: nil), transport = CacheTransport()
        await transport.configure(delay: .milliseconds(50))
        let client = cachedClient(transport, cache)
        let first = Task { try await client.items() }
        let second = Task { try await client.items() }
        try await Task.sleep(for: .milliseconds(10)); first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.items.count == 1)
        #expect(await transport.requests.count == 1)
    }
}

/// Deterministic in-process URLProtocol: no sockets, accounts or shared services.
private final class ChunkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let values = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String, _ fallback: Int) -> Int { values.first { $0.name == name }?.value.flatMap(Int.init) ?? fallback }
        if value("hold", 0) == 1 { return }
        let count = value("bytes", 512_000), chunk = value("chunk", 8192)
        let headers = value("declared", 0) == 1 ? ["Content-Length": String(count)] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: value("status", 200), httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        for offset in stride(from: 0, to: count, by: chunk) {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: min(chunk, count - offset)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
private func chunkConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkProtocol.self]
    return configuration
}
@Suite("Chunked bounded transport") struct TransportCacheTests {
    @Test func assemblesChunksAndPreservesHTTPStatus() async throws {
        let transport = URLSessionTransport(server: cacheServer, configuration: chunkConfiguration())
        let (data, response) = try await transport.send(URLRequest(url: URL(string: "https://cache.example/jellyfin/?bytes=512003&status=403")!))
        #expect(data == Data(repeating: 65, count: 512003)); #expect(response.statusCode == 403)
    }
    @Test(arguments: [false, true]) func rejectsOversizedBody(declared: Bool) async throws {
        let transport = URLSessionTransport(server: cacheServer, configuration: chunkConfiguration(), limit: 100)
        await #expect(throws: ClientError.responseTooLarge) {
            try await transport.send(URLRequest(url: URL(string: "https://cache.example/jellyfin/?bytes=101&chunk=7&declared=\(declared ? 1 : 0)")!))
        }
    }
    @Test func cancellationCompletesWithoutWaitingForBody() async throws {
        let transport = URLSessionTransport(server: cacheServer, configuration: chunkConfiguration())
        let pending = Task { try await transport.send(URLRequest(url: URL(string: "https://cache.example/jellyfin/?hold=1")!)) }
        try await Task.sleep(for: .milliseconds(10)); pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZOROFIN_RUN_CACHE_BENCHMARK"] == "1"))
    func fixtureBenchmark() async throws {
        let request = URLRequest(url: URL(string: "https://cache.example/jellyfin/?bytes=512000")!)
        let oldSession = URLSession(configuration: chunkConfiguration())
        defer { oldSession.invalidateAndCancel() }
        let transport = URLSessionTransport(server: cacheServer, configuration: chunkConfiguration())
        let clock = ContinuousClock()
        var old: [Double] = [], new: [Double] = []
        func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
        for _ in 0..<7 {
            let start = clock.now
            let (bytes, _) = try await oldSession.bytes(for: request)
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            old.append(ms(start.duration(to: clock.now)))
            let begin = clock.now
            let (chunked, _) = try await transport.send(request)
            new.append(ms(begin.duration(to: clock.now)))
            #expect(data == chunked)
        }
        print("CACHE BENCHMARK synthetic 512KB, 7 runs, median: byte iterator=\(old.sorted()[3])ms; chunks=\(new.sorted()[3])ms")
    }
}
