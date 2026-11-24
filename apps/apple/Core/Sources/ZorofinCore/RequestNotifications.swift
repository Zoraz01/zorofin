import Foundation
import CryptoKit

public struct RequestAvailabilityNotice: Identifiable, Codable, Sendable, Equatable {
    public let id: Int
    public let kind: RequestKind
    public let titleID: Int
    public let title: String
    public let posterURL: String?
    public let is4K: Bool
    public init(id: Int, kind: RequestKind, titleID: Int, title: String, posterURL: String? = nil, is4K: Bool = false) {
        self.id = id; self.kind = kind; self.titleID = titleID; self.title = title; self.posterURL = posterURL; self.is4K = is4K
    }
    public var message: String { is4K ? "Your 4K request is available." : "Your request is available." }
    init?(_ activity: RequestActivityItem, detail: RequestTitle) {
        guard activity.id > 0, [2, 5].contains(activity.requestStatus ?? 0),
              let kind = activity.kind, let titleID = activity.tmdbId, titleID == detail.id,
              let title = activity.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let receipt = detail.mediaInfo?.requests?.first(where: { $0.id == activity.id }),
              [2, 5].contains(receipt.status ?? 0), let is4K = receipt.is4k,
              Self.isAvailable(detail, receipt: receipt, is4K: is4K) else { return nil }
        self.init(id: activity.id, kind: kind, titleID: titleID, title: title,
                  posterURL: RequestArtwork.url(absolute: activity.posterUrl)?.absoluteString, is4K: is4K)
    }

    static func isAvailable(_ title: RequestTitle, receipt: RequestReceipt, is4K: Bool) -> Bool {
        let status = is4K ? title.mediaInfo?.status4k : title.mediaInfo?.status
        guard [4, 5].contains(status ?? 0) else { return false }
        // A show can be partly available while all seasons in this request are ready.
        // Conversely, another season being ready must not fulfill this request.
        if title.kind == .tv, let seasons = receipt.seasons, !seasons.isEmpty {
            return seasons.allSatisfy { requested in
                guard requested.seasonNumber >= 0,
                      let season = title.mediaInfo?.seasons?.first(where: { $0.seasonNumber == requested.seasonNumber }) else { return false }
                return (is4K ? season.status4k : season.status) == 5
            }
        }
        return status == 5
    }
}

public struct RequestAvailabilitySnapshot: Sendable {
    public let notices: [RequestAvailabilityNotice]
    public let hasOlder: Bool
}

public enum RequestNotificationError: LocalizedError {
    case noLongerAvailable, libraryLinkMissing
    public var errorDescription: String? {
        switch self {
        case .noLongerAvailable: "This request’s availability changed. Refresh Requests for its current status."
        case .libraryLinkMissing: "This request is available, but its library link is not ready. Search your library for the title."
        }
    }
}

public extension JellyfinClient {
    /// Read only this viewer's latest 100 requests. Availability comes from the
    /// matching receipt and requested quality/seasons, never download progress.
    /// Read IDs avoid repeating detail requests for acknowledged notifications.
    func requestAvailabilityNotifications(readIDs: Set<Int> = []) async throws -> RequestAvailabilitySnapshot {
        var candidates: [RequestActivityItem] = [], seen = Set<Int>()
        var totalPages = 1
        for page in 1...2 {
            try Task.checkCancellation()
            let result = try await request(RequestActivityPage.self, path: requestRoutes.path(.activity), query: [
                .init(name: "userOnly", value: "true"), .init(name: "take", value: "50"),
                .init(name: "skip", value: String((page - 1) * 50)), .init(name: "filter", value: "all")])
            totalPages = max(1, result.totalPages ?? 1)
            guard result.requests.count <= 50, totalPages <= 10_000 else { throw ClientError.invalidResponse }
            candidates += result.requests.filter {
                $0.id > 0 && !readIDs.contains($0.id) && seen.insert($0.id).inserted &&
                [2, 5].contains($0.requestStatus ?? 0) && $0.kind != nil && ($0.tmdbId ?? 0) > 0
            }
            if page >= totalPages { break }
        }
        // Coalesce standard/4K and season requests for the same title, with at
        // most four detail calls in flight. Ordering remains the activity order.
        let grouped = Dictionary(grouping: candidates) { "\($0.type!)-\($0.tmdbId!)" }
        let groups = Array(grouped.values)
        var resolved: [Int: RequestAvailabilityNotice] = [:]
        for start in stride(from: 0, to: groups.count, by: 4) {
            try Task.checkCancellation()
            let batch = groups[start..<min(start + 4, groups.count)]
            let notices = try await withThrowingTaskGroup(of: [RequestAvailabilityNotice].self) { group in
                for activities in batch {
                    group.addTask {
                        let first = activities[0]
                        let detail = try await requestTitle(kind: first.kind!, id: first.tmdbId!)
                        return activities.compactMap { RequestAvailabilityNotice($0, detail: detail) }
                    }
                }
                var result: [RequestAvailabilityNotice] = []
                for try await notices in group { result += notices }
                return result
            }
            for notice in notices { resolved[notice.id] = notice }
        }
        try Task.checkCancellation()
        return .init(notices: candidates.compactMap { resolved[$0.id] }, hasOlder: totalPages > 2)
    }

    /// Resolve fresh at the tap, keeping the requested standard/4K version and
    /// current server permissions authoritative. Never auto-play or auto-submit.
    func requestNotificationItem(_ notice: RequestAvailabilityNotice) async throws -> MediaItem {
        let title = try await requestTitle(kind: notice.kind, id: notice.titleID)
        guard let receipt = title.mediaInfo?.requests?.first(where: { $0.id == notice.id }),
              [2, 5].contains(receipt.status ?? 0), receipt.is4k == notice.is4K,
              RequestAvailabilityNotice.isAvailable(title, receipt: receipt, is4K: notice.is4K) else {
            throw RequestNotificationError.noLongerAvailable
        }
        guard let id = notice.is4K ? title.mediaInfo?.jellyfinMediaId4k : title.mediaInfo?.jellyfinMediaId,
              !id.isEmpty else { throw RequestNotificationError.libraryLinkMissing }
        return try await item(id, fresh: true)
    }
}

/// Only read receipts are persisted: no titles, artwork, hosts or credentials.
/// One actor serializes read-modify-write so concurrent acknowledgements survive.
public actor RequestNotificationReadStore {
    private let root: URL?
    private let defaults: UserDefaults?
    private static let prefix = "ZorofinRequestRead-v1."
    public init(root: URL? = nil) {
        #if os(tvOS)
        self.root = root; defaults = root == nil ? .standard : nil
        #else
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZorofinRequestRead-v1", isDirectory: true)
        defaults = nil
        #endif
    }
    init(defaultsSuiteName: String) { root = nil; defaults = UserDefaults(suiteName: defaultsSuiteName)! }
    private func key(server: ServerAddress, viewerID: String) -> String {
        Self.prefix + SHA256.hash(data: Data((server.storageKey + "\n" + viewerID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func readIDs(server: ServerAddress, viewerID: String) throws -> Set<Int> {
        let key = key(server: server, viewerID: viewerID)
        let data: Data
        if let defaults {
            guard let saved = defaults.data(forKey: key) else { return [] }
            data = saved
        } else if let root {
            let url = root.appendingPathComponent(key + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 else { throw SettingsError.storageFull }
            data = try Data(contentsOf: url)
        } else { throw SettingsError.invalidInput }
        guard data.count <= 128 * 1024 else { throw SettingsError.storageFull }
        let ids = try JSONDecoder().decode([Int].self, from: data)
        guard ids.allSatisfy({ $0 > 0 }), ids.count <= 20_000 else { throw SettingsError.invalidInput }
        return Set(ids)
    }
    public func markRead(_ id: Int, server: ServerAddress, viewerID: String) throws -> Set<Int> {
        guard id > 0 else { throw SettingsError.invalidInput }
        var ids = try readIDs(server: server, viewerID: viewerID)
        ids.insert(id)
        let data = try JSONEncoder().encode(ids.sorted())
        guard ids.count <= 20_000, data.count <= 128 * 1024 else { throw SettingsError.storageFull }
        let key = key(server: server, viewerID: viewerID)
        if let defaults {
            let otherBytes = defaults.dictionaryRepresentation().reduce(0) { result, pair in
                result + (pair.key.hasPrefix(Self.prefix) && pair.key != key ? (pair.value as? Data)?.count ?? 0 : 0)
            }
            guard otherBytes + data.count <= 128 * 1024 else { throw SettingsError.storageFull }
            defaults.set(data, forKey: key)
        } else if let root {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent(key + ".json")
            try data.write(to: url, options: .atomic)
            var mutableURL = url, values = URLResourceValues(); values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
        } else { throw SettingsError.invalidInput }
        return ids
    }
}
