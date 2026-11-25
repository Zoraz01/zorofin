import Foundation

/// Offline copies of movies and episodes for iPhone and iPad.
///
/// Downloads reuse the same PlaybackInfo negotiation as streaming. A title the
/// device can play directly is saved as its original file; anything else is
/// saved from the server's HLS transcode at the chosen quality, so every saved
/// copy is something AVPlayer already plays. Records are scoped to one server
/// and viewer and never mix accounts.
public enum DownloadQuality: String, CaseIterable, Codable, Sendable, Identifiable {
    case original, high, standard, saver
    public var id: String { rawValue }
    /// `PlaybackOptions` clamps this to the highest bitrate the player allows.
    public var bitrate: Int {
        switch self {
        case .original: 120_000_000
        case .high: 20_000_000
        case .standard: 8_000_000
        case .saver: 4_000_000
        }
    }
    public var title: String {
        switch self {
        case .original: "Original"
        case .high: "High"
        case .standard: "Standard"
        case .saver: "Data saver"
        }
    }
    public var detail: String {
        switch self {
        case .original: "Best available. Saves the original file when this device can play it."
        case .high: "Up to 20 Mbps"
        case .standard: "Up to 8 Mbps"
        case .saver: "Up to 4 Mbps. Smallest files."
        }
    }
    /// A size estimate for the confirmation menu. Never larger than the source.
    public func estimatedBytes(runTimeTicks: Int64?, source: MediaSource?) -> Int64? {
        let seconds = MediaTime.seconds(ticks: runTimeTicks ?? 0)
        if self == .original, let size = source?.size, size > 0 { return size }
        guard seconds > 0 else { return nil }
        var rate = Double(PlaybackOptions(bitrate: bitrate).bitrate)
        if let sourceRate = source?.bitrate, sourceRate > 0 { rate = min(rate, Double(sourceRate)) }
        return Int64(rate * seconds / 8)
    }
}

public enum DownloadMethod: String, Codable, Sendable {
    /// The original file, saved with a plain background download.
    case file
    /// An HLS transcode, saved with AVAssetDownloadURLSession.
    case stream
}

public enum DownloadStatus: String, Codable, Sendable {
    case queued, downloading, completed, failed
    public var isActive: Bool { self == .queued || self == .downloading }
}

public struct DownloadRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var accountKey: String
    public var item: MediaItem
    public var quality: DownloadQuality
    public var audioIndex: Int?
    public var subtitleIndex: Int
    public var method: DownloadMethod?
    public var status: DownloadStatus
    public var failure: String?
    public var progress: Double
    public var bytesWritten: Int64
    public var expectedBytes: Int64?
    /// Paths are relative to the app's home directory, because the sandbox
    /// container path changes between installs and restores.
    public var mediaPath: String?
    public var artworkPath: String?
    public var playSessionID: String?
    public var createdAt: Date
    public var completedAt: Date?
    public var offlinePositionTicks: Int64?
    public var offlinePlayed: Bool?
    /// The saved position or watched state still needs to reach the server.
    public var pendingSync: Bool

    public init(accountKey: String, item: MediaItem, quality: DownloadQuality,
                audioIndex: Int? = nil, subtitleIndex: Int = -1, createdAt: Date = Date()) {
        self.id = Self.id(accountKey: accountKey, itemID: item.id)
        self.accountKey = accountKey; self.item = item; self.quality = quality
        self.audioIndex = audioIndex; self.subtitleIndex = subtitleIndex
        self.status = .queued; self.progress = 0; self.bytesWritten = 0
        self.createdAt = createdAt; self.pendingSync = false
    }
    public static func id(accountKey: String, itemID: String) -> String { accountKey + ":" + itemID }

    public var isPlayable: Bool { status == .completed && mediaPath != nil }
    /// Offline progress wins over the snapshot taken when the download started.
    public var resumeTicks: Int64 {
        if offlinePlayed == true { return 0 }
        return max(0, offlinePositionTicks ?? item.resumeTicks)
    }

    public mutating func recordPlayback(positionSeconds: Double, durationSeconds: Double?) {
        let result = OfflineProgress.resolve(position: positionSeconds,
            duration: durationSeconds ?? item.runTimeTicks.map(MediaTime.seconds))
        offlinePositionTicks = result.positionTicks
        offlinePlayed = result.played
        pendingSync = true
    }
}

/// Matches Jellyfin's default resume rules: under 5% starts over, and 90% or
/// more counts as watched.
public enum OfflineProgress {
    public static func resolve(position: Double, duration: Double?) -> (positionTicks: Int64, played: Bool) {
        guard position.isFinite, position > 0 else { return (0, false) }
        guard let duration, duration.isFinite, duration > 0 else { return (MediaTime.ticks(seconds: position), false) }
        let fraction = position / duration
        if fraction >= 0.9 { return (0, true) }
        if fraction < 0.05 { return (0, false) }
        return (MediaTime.ticks(seconds: position), false)
    }
}

public enum DownloadAccount {
    /// A stable folder-safe key for one server and viewer.
    public static func key(server: ServerAddress, viewerID: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (server.storageKey + "\n" + viewerID).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public struct DownloadPlan: Sendable {
    public let url: URL
    public let method: DownloadMethod
    public let playSessionID: String
    public let expectedBytes: Int64?
    public let fileExtension: String

    public static func make(info: PlaybackInfo, itemID: String, client: JellyfinClient,
                            options: PlaybackOptions) throws -> DownloadPlan {
        let source = info.mediaSources?.first
        guard source?.requiresOpening != true, source?.liveStreamId == nil else { throw ClientError.unsupportedPlayback }
        let plan = try PlaybackPlan.make(info: info, source: source, itemID: itemID, client: client, options: options)
        if plan.method == "DirectPlay" {
            let containers = (source?.container ?? "").lowercased().split(separator: ",").map(String.init)
            let ext = containers.first { ["mp4", "m4v", "mov"].contains($0) } ?? "mp4"
            return DownloadPlan(url: plan.url, method: .file, playSessionID: plan.sessionID,
                                expectedBytes: source?.size, fileExtension: ext)
        }
        return DownloadPlan(url: plan.url, method: .stream, playSessionID: plan.sessionID,
                            expectedBytes: nil, fileExtension: "movpkg")
    }
}

/// The on-disk index of every download on this device.
public struct DownloadCatalog: Codable, Equatable, Sendable {
    public private(set) var records: [DownloadRecord] = []
    public init(records: [DownloadRecord] = []) { self.records = records }

    public func record(_ id: String) -> DownloadRecord? { records.first { $0.id == id } }
    public func record(accountKey: String, itemID: String) -> DownloadRecord? {
        record(DownloadRecord.id(accountKey: accountKey, itemID: itemID))
    }
    /// Active downloads first, then newest finished titles.
    public func records(accountKey: String) -> [DownloadRecord] {
        records.filter { $0.accountKey == accountKey }.sorted { lhs, rhs in
            if lhs.status.isActive != rhs.status.isActive { return lhs.status.isActive }
            return (lhs.completedAt ?? lhs.createdAt) > (rhs.completedAt ?? rhs.createdAt)
        }
    }
    public func usedBytes(accountKey: String? = nil) -> Int64 {
        records.filter { accountKey == nil || $0.accountKey == accountKey }.reduce(0) { $0 + max(0, $1.bytesWritten) }
    }
    public func pendingSync(accountKey: String) -> [DownloadRecord] {
        records.filter { $0.accountKey == accountKey && $0.pendingSync }
    }
    public mutating func upsert(_ record: DownloadRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
    }
    public mutating func update(_ id: String, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
    }
    @discardableResult public mutating func remove(_ id: String) -> DownloadRecord? {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        return records.remove(at: index)
    }
    @discardableResult public mutating func removeAll(accountKey: String) -> [DownloadRecord] {
        let removed = records.filter { $0.accountKey == accountKey }
        records.removeAll { $0.accountKey == accountKey }
        return removed
    }
}

/// Movies stay as single titles; episodes are grouped under their show.
public struct DownloadGroup: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var records: [DownloadRecord]
    public var isSeries: Bool

    public static func groups(_ records: [DownloadRecord]) -> [DownloadGroup] {
        var result: [DownloadGroup] = []
        var seriesIndex: [String: Int] = [:]
        for record in records {
            if record.item.isEpisode {
                let key = record.item.seriesId ?? record.item.seriesName ?? record.item.id
                if let index = seriesIndex[key] { result[index].records.append(record); continue }
                seriesIndex[key] = result.count
                result.append(.init(id: "series-" + key, title: record.item.seriesName ?? record.item.name,
                                    records: [record], isSeries: true))
            } else {
                result.append(.init(id: record.id, title: record.item.name, records: [record], isSeries: false))
            }
        }
        for index in result.indices where result[index].isSeries {
            result[index].records.sort {
                ($0.item.parentIndexNumber ?? 0, $0.item.indexNumber ?? 0) < ($1.item.parentIndexNumber ?? 0, $1.item.indexNumber ?? 0)
            }
        }
        return result
    }
}

public extension MediaItem {
    /// Live channels and folders cannot be saved for offline playback.
    var isDownloadable: Bool { (type == "Movie" || isEpisode) && !isLive }
}

public extension JellyfinClient {
    /// Never trust the policy in a persisted login or the library cache. Unknown
    /// permission is denied; a response for another viewer cannot authorize work.
    func contentDownloadPermission() async throws -> Bool {
        guard let session else { throw ClientError.missingSession }
        let viewer = try await currentViewer()
        try Task.checkCancellation()
        guard viewer.id == session.viewer.id else { throw ClientError.invalidResponse }
        return viewer.policy?.enableContentDownloading == true
    }

    /// Saves offline progress on the server once the device is back online.
    func syncOfflineProgress(itemID: String, positionTicks: Int64, played: Bool) async throws {
        guard let session else { throw ClientError.missingSession }
        let body: [String: JSONValue] = ["PlaybackPositionTicks": .int(max(0, positionTicks)), "Played": .bool(played)]
        _ = try await requestData(["UserItems", itemID, "UserData"],
            query: [.init(name: "userId", value: session.viewer.id)], method: "POST",
            body: JSONEncoder().encode(body))
        await responseCache?.invalidateMetadata()
    }
    /// Ends the server-side transcode for a play session: a finished or cancelled
    /// download, or a streaming start that failed before reporting playback.
    func stopEncoding(playSessionID: String) async throws {
        _ = try await requestData(["Videos", "ActiveEncodings"], query: [
            .init(name: "deviceId", value: identity.deviceID),
            .init(name: "playSessionId", value: playSessionID)], method: "DELETE")
    }
}
