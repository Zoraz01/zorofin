import Foundation
import Testing
@testable import ZorofinCore

private actor DownloadTransport: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private func downloadClient(_ transport: DownloadTransport = DownloadTransport()) throws -> JellyfinClient {
    let server = try ServerAddress("https://media.example/base")
    return JellyfinClient(server: server, identity: .init(deviceID: "device", deviceName: "Fixture"),
        session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "secret", deviceID: "device"),
        transport: transport)
}

private func episode(_ id: String, season: Int, number: Int, series: String = "show") -> MediaItem {
    var item = MediaItem(id: id, name: "Episode \(number)", type: "Episode")
    item.seriesId = series; item.seriesName = "Show"; item.parentIndexNumber = season; item.indexNumber = number
    return item
}

@Suite("Offline downloads") struct OfflineDownloadsTests {
    @Test func directPlaySourcesSaveTheOriginalFile() throws {
        let info = try Wire.decoder().decode(PlaybackInfo.self, from: Data(#"""
        {"PlaySessionId":"play","MediaSources":[{"Id":"source","Container":"mov,mp4,m4a","Size":2048,"SupportsDirectPlay":true}]}
        """#.utf8))
        let plan = try DownloadPlan.make(info: info, itemID: "movie", client: downloadClient(), options: .init(bitrate: 40_000_000))
        #expect(plan.method == .file)
        #expect(plan.fileExtension == "mov")
        #expect(plan.expectedBytes == 2048)
        #expect(plan.playSessionID == "play")
        #expect(plan.url.path == "/base/Videos/movie/stream")
        let query = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.contains(.init(name: "static", value: "true")))
        #expect(query.contains(.init(name: "ApiKey", value: "secret")))
    }

    @Test func otherSourcesSaveTheHLSTranscode() throws {
        let info = try Wire.decoder().decode(PlaybackInfo.self, from: Data(#"""
        {"PlaySessionId":"play","MediaSources":[{"Id":"source","Container":"mkv","SupportsDirectPlay":false,"SupportsTranscoding":true,"TranscodingUrl":"/base/videos/movie/master.m3u8?MediaSourceId=source&api_key=old","TranscodingSubProtocol":"hls"}]}
        """#.utf8))
        let plan = try DownloadPlan.make(info: info, itemID: "movie", client: downloadClient(), options: .init(bitrate: 8_000_000))
        #expect(plan.method == .stream)
        #expect(plan.url.path.hasSuffix("master.m3u8"))
        let query = URLComponents(url: plan.url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(!query.contains { $0.name == "api_key" })
        #expect(query.contains(.init(name: "ApiKey", value: "secret")))
    }

    @Test func liveSourcesAreNeverDownloaded() throws {
        let info = try Wire.decoder().decode(PlaybackInfo.self, from: Data(#"""
        {"PlaySessionId":"play","MediaSources":[{"Id":"source","RequiresOpening":true,"OpenToken":"x","SupportsDirectPlay":true}]}
        """#.utf8))
        #expect(throws: ClientError.unsupportedPlayback) {
            try DownloadPlan.make(info: info, itemID: "channel", client: downloadClient(), options: .init())
        }
        #expect(!MediaItem(id: "c", name: "Channel", type: "TvChannel").isDownloadable)
        #expect(!MediaItem(id: "s", name: "Show", type: "Series").isDownloadable)
        #expect(MediaItem(id: "m", name: "Movie", type: "Movie").isDownloadable)
        #expect(episode("e", season: 1, number: 1).isDownloadable)
    }

    @Test func offlineProgressFollowsJellyfinResumeRules() {
        #expect(OfflineProgress.resolve(position: 30, duration: 6000) == (0, false))
        #expect(OfflineProgress.resolve(position: 3000, duration: 6000) == (MediaTime.ticks(seconds: 3000), false))
        #expect(OfflineProgress.resolve(position: 5500, duration: 6000) == (0, true))
        #expect(OfflineProgress.resolve(position: .nan, duration: 6000) == (0, false))
        var record = DownloadRecord(accountKey: "a", item: .init(id: "m", name: "Movie"), quality: .high)
        record.item.runTimeTicks = MediaTime.ticks(seconds: 6000)
        record.recordPlayback(positionSeconds: 1200, durationSeconds: nil)
        #expect(record.pendingSync && record.resumeTicks == MediaTime.ticks(seconds: 1200))
        record.recordPlayback(positionSeconds: 5900, durationSeconds: 6000)
        #expect(record.offlinePlayed == true && record.resumeTicks == 0)
    }

    @Test func catalogKeepsAccountsSeparateAndListsActiveFirst() throws {
        let server = try ServerAddress("https://media.example/base")
        let first = DownloadAccount.key(server: server, viewerID: "one")
        let second = DownloadAccount.key(server: server, viewerID: "two")
        #expect(first != second && first.count == 16)
        #expect(first == DownloadAccount.key(server: server, viewerID: "one"))
        var catalog = DownloadCatalog()
        var done = DownloadRecord(accountKey: first, item: .init(id: "old", name: "Old"), quality: .high, createdAt: .init(timeIntervalSince1970: 1))
        done.status = .completed; done.bytesWritten = 100; done.completedAt = .init(timeIntervalSince1970: 5)
        catalog.upsert(done)
        catalog.upsert(DownloadRecord(accountKey: first, item: .init(id: "new", name: "New"), quality: .high, createdAt: .init(timeIntervalSince1970: 2)))
        catalog.upsert(DownloadRecord(accountKey: second, item: .init(id: "other", name: "Other"), quality: .saver))
        #expect(catalog.records(accountKey: first).map(\.item.id) == ["new", "old"])
        #expect(catalog.usedBytes(accountKey: first) == 100 && catalog.usedBytes(accountKey: second) == 0)
        catalog.update(DownloadRecord.id(accountKey: first, itemID: "new")) { $0.pendingSync = true }
        #expect(catalog.pendingSync(accountKey: first).map(\.item.id) == ["new"])
        #expect(catalog.removeAll(accountKey: first).count == 2)
        #expect(catalog.records.map(\.item.id) == ["other"])
        let data = try JSONEncoder().encode(catalog)
        #expect(try JSONDecoder().decode(DownloadCatalog.self, from: data) == catalog)
    }

    @Test func episodesGroupUnderTheirShowInEpisodeOrder() {
        let records = [episode("b", season: 2, number: 1), MediaItem(id: "m", name: "Movie"), episode("a", season: 1, number: 3)]
            .map { DownloadRecord(accountKey: "a", item: $0, quality: .high) }
        let groups = DownloadGroup.groups(records)
        #expect(groups.count == 2)
        #expect(groups[0].isSeries && groups[0].records.map(\.item.id) == ["a", "b"])
        #expect(!groups[1].isSeries && groups[1].title == "Movie")
    }

    @Test func sizeEstimatesNeverExceedTheSource() {
        var source = MediaSource(); source.bitrate = 4_000_000; source.size = 9_000
        let hour = MediaTime.ticks(seconds: 3600)
        #expect(DownloadQuality.original.estimatedBytes(runTimeTicks: hour, source: source) == 9_000)
        #expect(DownloadQuality.high.estimatedBytes(runTimeTicks: hour, source: source) == Int64(1_800_000_000))
        #expect(DownloadQuality.saver.estimatedBytes(runTimeTicks: nil, source: nil) == nil)
    }

    @Test func syncAndCleanupUseStandardJellyfinEndpoints() async throws {
        let transport = DownloadTransport()
        let client = try downloadClient(transport)
        try await client.syncOfflineProgress(itemID: "movie", positionTicks: 42, played: false)
        try await client.stopEncoding(playSessionID: "play")
        let requests = await transport.requests
        #expect(requests.map { $0.httpMethod ?? "" } == ["POST", "DELETE"])
        #expect(requests[0].url!.path == "/base/UserItems/movie/UserData")
        let body = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
        #expect(body["PlaybackPositionTicks"] as? Int == 42 && body["Played"] as? Bool == false)
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(requests[1].url!.path == "/base/Videos/ActiveEncodings")
        #expect(query.contains(.init(name: "playSessionId", value: "play")) && query.contains(.init(name: "deviceId", value: "device")))
    }
}
