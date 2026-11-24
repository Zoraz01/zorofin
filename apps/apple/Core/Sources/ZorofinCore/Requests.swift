import Foundation
import CryptoKit

public enum RequestKind: String, Codable, Sendable, CaseIterable { case movie, tv }

/// Availability and request progress are distinct from the viewer's selection.
public enum RequestSeasonState: String, Sendable, Equatable {
    case missing, partlyAvailable, pendingApproval, requested, available, unknown
    public var requestable: Bool { self == .missing || self == .partlyAvailable }
    public var label: String {
        switch self {
        case .missing: "Not available"
        case .partlyAvailable: "Partly available"
        case .pendingApproval: "Awaiting approval"
        case .requested: "Requested"
        case .available: "Available to watch"
        case .unknown: "Status unavailable"
        }
    }
}

public struct RequestTitle: Codable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var mediaType: String?
    public var title: String?
    public var name: String?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var releaseDate: String?
    public var firstAirDate: String?
    public var voteAverage: Double?
    public var runtime: Int?
    public var seasons: [RequestSeason]?
    public var externalIds: ExternalIDs?
    public var mediaInfo: RequestMediaInfo?
    public struct ExternalIDs: Codable, Sendable, Hashable { public var tvdbId: Int? }
    public var displayTitle: String { title ?? name ?? "Untitled" }
    public var kind: RequestKind? { mediaType.flatMap(RequestKind.init) ?? (mediaType == nil ? (name == nil ? .movie : .tv) : nil) }
    public var identity: String { "\(kind?.rawValue ?? "unknown")-\(id)" }
    public var year: String { String((releaseDate ?? firstAirDate ?? "").prefix(4)) }
    public func status(is4K: Bool = false) -> String { RequestMediaInfo.label(is4K ? mediaInfo?.status4k : mediaInfo?.status) }
    public func seasonState(_ number: Int, is4K: Bool = false) -> RequestSeasonState {
        let season = mediaInfo?.seasons?.first { $0.seasonNumber == number }
            ?? seasons?.first { $0.seasonNumber == number }
        let status = is4K ? season?.status4k : season?.status
        if status == 5 { return .available }
        let receipts = (mediaInfo?.requests ?? []).filter {
            ($0.is4k ?? false) == is4K && ($0.seasons ?? []).contains { $0.seasonNumber == number }
        }
        if status == 3 || receipts.contains(where: { $0.status == 2 }) { return .requested }
        if status == 2 || receipts.contains(where: { $0.status == 1 }) { return .pendingApproval }
        if status == 4 { return .partlyAvailable }
        if let status { return [1, 6, 7].contains(status) ? .missing : .unknown }
        // A series-wide status cannot prove which individual seasons can play.
        let overall = is4K ? mediaInfo?.status4k : mediaInfo?.status
        if overall == 5 { return .unknown }
        return .missing
    }
    /// One request flow; an existing version in either quality is not offered again.
    public func requestSeasonState(_ number: Int) -> RequestSeasonState {
        let standard = seasonState(number), highQuality = seasonState(number, is4K: true)
        for state in [RequestSeasonState.available, .requested, .pendingApproval, .partlyAvailable] {
            if standard == state || highQuality == state { return state }
        }
        return standard == .unknown || highQuality == .unknown ? .unknown : .missing
    }
    public func seasonBlocked(_ number: Int, is4K: Bool) -> Bool {
        !seasonState(number, is4K: is4K).requestable
    }
    public func eligibleSeasons(is4K: Bool, specials: Bool = false) -> [RequestSeason] {
        (seasons ?? []).filter { $0.seasonNumber >= (specials ? 0 : 1) && ($0.episodeCount ?? 0) > 0 && !seasonBlocked($0.seasonNumber, is4K: is4K) }
    }
}

public struct RequestSeason: Codable, Sendable, Hashable, Identifiable {
    public var seasonNumber: Int
    public var name: String?
    public var episodeCount: Int?
    public var status: Int?
    public var status4k: Int?
    public var id: Int { seasonNumber }
    public var displayName: String { name ?? (seasonNumber == 0 ? "Specials" : "Season \(seasonNumber)") }
}

public struct RequestMediaInfo: Codable, Sendable, Hashable {
    public var status: Int?
    public var status4k: Int?
    public var jellyfinMediaId: String?
    public var jellyfinMediaId4k: String?
    public var seasons: [RequestSeason]?
    public var requests: [RequestReceipt]?
    public static func label(_ status: Int?) -> String {
        switch status { case nil, 1: "Not requested"; case 2: "Pending approval"; case 3: "Requested"
        case 4: "Partly available"; case 5: "Available"; case 6: "Unavailable"; case 7: "Removed"; default: "Status unavailable" }
    }
}

public struct RequestReceipt: Codable, Sendable, Hashable {
    public var id: Int?
    public var status: Int?
    public var is4k: Bool?
    public var seasons: [RequestSeason]?
}

public struct RequestPage: Decodable, Sendable {
    public var results: [RequestTitle]
    public var totalPages: Int?
}

public struct RequestAccess: Decodable, Sendable {
    public var active: Bool?
    public var userFound: Bool?
    public var reason: String?
    public var available: Bool { active == true && userFound == true }
}

public struct RequestConfiguration: Decodable, Sendable {
    public var jellyseerrEnable4KRequests: Bool?
    public var jellyseerrEnable4KTvRequests: Bool?
    public func allows4K(_ kind: RequestKind) -> Bool {
        (kind == .movie ? jellyseerrEnable4KRequests : jellyseerrEnable4KTvRequests) == true
    }
}

public struct RequestSeasonSettings: Decodable, Sendable {
    public var partialRequestsEnabled: Bool?
    public var enableSpecialEpisodes: Bool?
}

public struct RequestQuota: Decodable, Sendable {
    public struct Limit: Decodable, Sendable {
        public var limit: Int?
        public var used: Int?
        public var days: Int?
        public var restricted: Bool?
        public var remaining: Int? { guard let limit, limit > 0, let used else { return nil }; return max(0, limit - used) }
    }
    public var movie: Limit?
    public var tv: Limit?
    public func limit(_ kind: RequestKind) -> Limit? { kind == .movie ? movie : tv }
}

public struct RequestActivityPage: Decodable, Sendable {
    public var requests: [RequestActivityItem]
    public var totalPages: Int?
}

public struct RequestActivityItem: Decodable, Sendable, Identifiable {
    public var id: Int
    public var type: String?
    public var tmdbId: Int?
    public var title: String?
    public var posterUrl: String?
    public var year: Int?
    public var mediaStatus: String?
    public var requestStatus: Int?
    public var is4k: Bool?
    public var requestedBy: String?
    public var isComingSoon: Bool?
    public var isOrphaned: Bool?
    public var kind: RequestKind? { type.flatMap(RequestKind.init) }
    public var statusLabel: String {
        if requestStatus == 1 { return "Pending approval" }
        if requestStatus == 3 { return "Declined" }
        if requestStatus == 4 { return "Request failed" }
        if mediaStatus == "Available" { return "Available" }
        if isOrphaned == true { return "Needs attention" }
        if isComingSoon == true { return "Waiting for release" }
        switch mediaStatus { case "Partially Available": return "Partly available"; case "Pending": return "Pending approval"
        case "Processing", "Approved": return "Requested"; case "Deleted": return "Removed"
        case "Failed": return "Request failed"; case "Declined": return "Declined"; default: return "Status unavailable" }
    }
}

public struct RequestQueue: Decodable, Sendable {
    public var items: [Download]
    public struct Download: Decodable, Sendable {
        public var tmdbId: Int?
        public var source: String?
        public var progress: Double?
        public var status: String?
        public var label: String {
            let text = (status ?? "").lowercased()
            if text.contains("error") || text.contains("warning") || text.contains("failed") { return "Download needs attention" }
            if text.contains("import") || (progress ?? 0) >= 100 { return "Adding to library" }
            if text.contains("paused") { return "Download paused" }
            if let progress, progress.isFinite, progress > 0 { return "Downloading · \(Int(min(99, max(0, progress))))%" }
            return "Download queued"
        }
    }
    // The queue is never shown on its own: join only records the request API permits this viewer to see.
    public func label(for item: RequestActivityItem) -> String? {
        guard item.requestStatus == 2, item.mediaStatus != "Available", let id = item.tmdbId, let kind = item.kind else { return nil }
        return items.first { $0.tmdbId == id && $0.source?.lowercased() == (kind == .movie ? "radarr" : "sonarr") }?.label
    }
}

public enum RequestFailure: Error, LocalizedError, Equatable {
    case unavailable, invalidSelection, alreadyRequested, quota, unconfirmed, rejected, storage, inProgress
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Requests is unavailable for this account. Contact your server owner."
        case .invalidSelection: "These choices changed. Reload the title and select missing seasons."
        case .alreadyRequested: "This title or selection is already available or requested. Refresh its status."
        case .quota: "This selection exceeds your request limit. Try fewer seasons or wait for your limit to reset."
        case .unconfirmed: "Delivery is unconfirmed. Check request activity or refresh this title. This app will not send it again automatically."
        case .rejected: "The server did not accept this request. Refresh the title and check your permissions or request limit."
        case .storage: "The app could not save the request receipt. No new request will be sent until storage is available."
        case .inProgress: "This request may still be processing. Wait a minute, then refresh its status before allowing another attempt."
        }
    }
}

public struct RequestIntent: Codable, Sendable, Hashable {
    public let mediaType: RequestKind
    public let mediaId: Int
    public let is4k: Bool
    public let seasons: [Int]?
    public let tvdbId: Int?
    public init(kind: RequestKind, id: Int, is4K: Bool = false, seasons: [Int] = [], tvdbID: Int? = nil) {
        mediaType = kind; mediaId = id; is4k = is4K
        self.seasons = kind == .tv ? Array(Set(seasons)).sorted() : nil
        tvdbId = kind == .tv && (tvdbID ?? 0) > 0 ? tvdbID : nil
    }
    func overlaps(_ other: Self) -> Bool {
        mediaType == other.mediaType && mediaId == other.mediaId && is4k == other.is4k &&
            (mediaType == .movie || !Set(seasons ?? []).isDisjoint(with: other.seasons ?? []))
    }
    public func validate(title: RequestTitle, settings: RequestSeasonSettings?, quota: RequestQuota?) throws {
        guard mediaId > 0, title.id == mediaId, title.kind == mediaType else { throw RequestFailure.invalidSelection }
        if mediaType == .movie {
            guard [1, 6, 7].contains((is4k ? title.mediaInfo?.status4k : title.mediaInfo?.status) ?? 1),
                  !(title.mediaInfo?.requests ?? []).contains(where: { ($0.is4k ?? false) == is4k && [1, 2].contains($0.status ?? 0) }) else { throw RequestFailure.alreadyRequested }
        } else {
            guard let settings else { throw RequestFailure.unavailable }
            let eligible = Set(title.eligibleSeasons(is4K: is4k, specials: settings.enableSpecialEpisodes == true).map(\.seasonNumber))
            let selected = Set(seasons ?? [])
            guard !selected.isEmpty, selected.isSubset(of: eligible),
                  settings.partialRequestsEnabled == true || selected == eligible else { throw RequestFailure.invalidSelection }
        }
        let limit = quota?.limit(mediaType)
        guard limit?.restricted != true, limit?.remaining.map({ $0 >= (mediaType == .movie ? 1 : seasons?.count ?? 0) }) ?? true else { throw RequestFailure.quota }
    }
}

public extension JellyfinClient {
    func requestAccess() async throws -> RequestAccess { try await request(RequestAccess.self, path: requestRoutes.path(.userStatus)) }
    func requestConfiguration() async throws -> RequestConfiguration { try await request(RequestConfiguration.self, path: requestRoutes.path(.configuration)) }
    func requestQuota() async throws -> RequestQuota { try await request(RequestQuota.self, path: requestRoutes.path(.quota)) }
    func requestSeasonSettings() async throws -> RequestSeasonSettings { try await request(RequestSeasonSettings.self, path: requestRoutes.path(.seasonSettings)) }
    func requestTitles(category: String = "trending", query: String = "", page: Int = 1) async throws -> RequestPage {
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        let allowed = ["trending", "movies", "tv", "upcoming"]
        guard allowed.contains(category), (1...500).contains(page) else { throw ClientError.invalidResponse }
        let path: [String]
        var parameters = [URLQueryItem(name: "page", value: String(page))]
        if term.isEmpty { path = requestRoutes.path(.discover(category == "upcoming" ? ["movies", "upcoming"] : [category])) }
        else { path = requestRoutes.path(.search); parameters += [.init(name: "query", value: term)] }
        return try await request(RequestPage.self, path: path, query: parameters,
            cachePolicy: .init(storage: .memory, lifetime: 60, snapshotLifetime: 60))
    }
    func requestTitle(kind: RequestKind, id: Int) async throws -> RequestTitle {
        guard id > 0 else { throw ClientError.invalidResponse }
        var title = try await request(RequestTitle.self, path: requestRoutes.path(.title(kind, id)))
        guard title.id == id else { throw ClientError.invalidResponse }
        title.mediaType = kind.rawValue
        return title
    }
    func requestActivity(mine: Bool = true, page: Int = 1, filter: String = "all") async throws -> RequestActivityPage {
        guard (1...500).contains(page), ["all", "pending", "approved", "processing", "available"].contains(filter) else { throw ClientError.invalidResponse }
        return try await request(RequestActivityPage.self, path: requestRoutes.path(.activity), query: [
            .init(name: "userOnly", value: mine ? "true" : "false"), .init(name: "take", value: "24"),
            .init(name: "skip", value: String((page - 1) * 24)), .init(name: "filter", value: filter)])
    }
    func requestQueue() async throws -> RequestQueue { try await request(RequestQueue.self, path: requestRoutes.path(.queue)) }
}

/// Durable guard, not an invented server idempotency contract. Persist BEFORE sending,
/// including crashes/cancellation; never replay POSTs. Contains no names, hosts or tokens.
@globalActor public actor RequestJournalStorage {
    public static let shared = RequestJournalStorage()
}

@RequestJournalStorage public final class RequestJournal: Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public let id: UUID
        public let intent: RequestIntent
        public var receiptID: Int?
        public let created: Date
    }
    private let file: URL
    private static var inFlight: Set<UUID> = []
    public nonisolated init(server: ServerAddress, viewerID: String, root: URL) {
        let hash = SHA256.hash(data: Data((server.storageKey + "\n" + viewerID).utf8)).map { String(format: "%02x", $0) }.joined()
        file = root.appendingPathComponent(hash + ".json")
    }
    public func entries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do { return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)) }
        catch { throw RequestFailure.storage }
    }
    private func save(_ entries: [Entry]) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            var location = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
        } catch { throw RequestFailure.storage }
    }
    public func begin(_ intent: RequestIntent) throws -> Entry {
        var saved = try entries()
        if let existing = saved.first(where: { $0.intent.overlaps(intent) }) {
            throw existing.receiptID == nil ? RequestFailure.unconfirmed : RequestFailure.alreadyRequested
        }
        let entry = Entry(id: UUID(), intent: intent, receiptID: nil, created: Date())
        saved.append(entry); try save(saved); Self.inFlight.insert(entry.id); return entry
    }
    public func accepted(_ id: UUID, receiptID: Int) throws {
        var saved = try entries()
        guard let index = saved.firstIndex(where: { $0.id == id }) else { throw RequestFailure.storage }
        saved[index].receiptID = receiptID; try save(saved); Self.inFlight.remove(id)
    }
    public func rejected(_ id: UUID) throws { try save(entries().filter { $0.id != id }); Self.inFlight.remove(id) }
    func finishedUnconfirmed(_ id: UUID) { Self.inFlight.remove(id) }
    /// Used only after the viewer explicitly acknowledges uncertain delivery and
    /// fresh server checks still permit this exact selection. Does not send anything.
    func clearUnconfirmed(_ intents: Set<RequestIntent>) throws {
        let saved = try entries()
        let clearing = saved.filter { $0.receiptID == nil && intents.contains($0.intent) }
        guard clearing.allSatisfy({ !Self.inFlight.contains($0.id) && Date().timeIntervalSince($0.created) >= 60 }) else { throw RequestFailure.inProgress }
        try save(saved.filter { $0.receiptID != nil || !intents.contains($0.intent) })
    }
    public func reconcile(_ title: RequestTitle) throws {
        var saved = try entries(); var changed = false
        for index in saved.indices where saved[index].intent.mediaId == title.id && saved[index].intent.mediaType == title.kind {
            let intent = saved[index].intent
            if let match = title.mediaInfo?.requests?.first(where: {
                ($0.id ?? 0) > 0 && ($0.is4k ?? false) == intent.is4k && [1, 2, 5].contains($0.status ?? 0) &&
                (intent.mediaType == .movie || Set(intent.seasons ?? []).isSubset(of: Set(($0.seasons ?? []).map(\.seasonNumber))))
            }), saved[index].receiptID != match.id { saved[index].receiptID = match.id; changed = true }
        }
        let terminalIDs = Set((title.mediaInfo?.requests ?? []).filter { [3, 4].contains($0.status ?? 0) }.compactMap(\.id))
        let remaining = saved.filter { entry in
            !(entry.intent.mediaId == title.id && entry.intent.mediaType == title.kind && entry.receiptID.map(terminalIDs.contains) == true)
        }
        if changed || remaining.count != saved.count { try save(remaining) }
    }
}

public actor RequestSubmissionService {
    private let client: JellyfinClient
    public let journal: RequestJournal
    public init(client: JellyfinClient, journal: RequestJournal) { self.client = client; self.journal = journal }
    public func allowAnotherAttempt(kind: RequestKind, id: Int, is4K: Bool) async throws {
        guard try await client.requestAccess().available else { throw RequestFailure.unavailable }
        let title = try await client.requestTitle(kind: kind, id: id)
        let quota = try await client.requestQuota()
        let settings = kind == .tv ? try await client.requestSeasonSettings() : nil
        let entries = try await journal.entries().filter { $0.receiptID == nil && $0.intent.mediaId == id && $0.intent.mediaType == kind && $0.intent.is4k == is4K }
        for entry in entries { try entry.intent.validate(title: title, settings: settings, quota: quota) }
        try await journal.clearUnconfirmed(Set(entries.map(\.intent)))
    }
    public func submit(_ intent: RequestIntent) async throws -> RequestReceipt {
        guard try await client.requestAccess().available else { throw RequestFailure.unavailable }
        if intent.is4k, try await !client.requestConfiguration().allows4K(intent.mediaType) { throw RequestFailure.invalidSelection }
        let title = try await client.requestTitle(kind: intent.mediaType, id: intent.mediaId)
        let quota = try await client.requestQuota()
        let settings = intent.mediaType == .tv ? try await client.requestSeasonSettings() : nil
        try intent.validate(title: title, settings: settings, quota: quota)
        try Task.checkCancellation()
        let entry = try await journal.begin(intent)
        do {
            let data = try await client.requestData(client.requestRoutes.path(.submit), method: "POST", body: JSONEncoder().encode(intent))
            let receipt = try JSONDecoder().decode(RequestReceipt.self, from: data)
            guard let id = receipt.id, id > 0 else { throw RequestFailure.unconfirmed }
            try await journal.accepted(entry.id, receiptID: id)
            return receipt
        } catch {
            await journal.finishedUnconfirmed(entry.id)
            // These explicit responses establish rejection. Conflicts, 5xx, malformed
            // success bodies, disconnects and cancellation can have side effects upstream.
            if let failure = error as? ClientError,
               failure == .unauthorized || failure == .forbidden || [400, 404, 422, 429].contains(where: { failure == .unavailable($0) }) {
                try await journal.rejected(entry.id)
                throw RequestFailure.rejected
            }
            throw RequestFailure.unconfirmed
        }
    }
}

/// Public TMDB artwork uses a separate, credential-free transport. Never follows
/// a server-supplied host or sends Jellyfin authorization to the image provider.
public enum RequestArtwork {
    public static func url(path: String?) -> URL? {
        guard let path, path.range(of: #"^/[A-Za-z0-9_-]+\.(jpg|png|webp)$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w342" + path)
    }
    public static func url(absolute: String?) -> URL? {
        guard let absolute, let url = URL(string: absolute), url.scheme == "https", url.host == "image.tmdb.org", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: #"^/t/p/(w[0-9]+|original)/[A-Za-z0-9_-]+\.(jpg|png|webp)$"#, options: .regularExpression) != nil else { return nil }
        return self.url(path: "/" + url.lastPathComponent)
    }
    public static func data(url: URL) async throws -> Data {
        guard self.url(absolute: url.absoluteString) == url else { throw ClientError.unsafeURL }
        let server = try ServerAddress("https://image.tmdb.org")
        var request = URLRequest(url: url); request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSessionTransport(server: server).send(request)
        guard response.statusCode == 200, data.count <= 4 * 1024 * 1024,
              response.mimeType?.hasPrefix("image/") == true else { throw ClientError.invalidResponse }
        return data
    }
}
