import Foundation

// Native server administration. Every call uses the signed-in account's own
// token; the server enforces administrator rights. No web view, cookie or
// second token is involved.

public enum AdminDate {
    /// Jellyfin sends ISO 8601 with up to seven fractional digits.
    public static func parse(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let rest = text[text.index(after: dot)...].dropFirst(digits.count)
            text = String(text[..<dot]) + "." + String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
        }
        if !text.hasSuffix("Z") && text.range(of: "[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) == nil { text += "Z" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct AdminServerInfo: Decodable, Sendable, Equatable {
    public var id: String?
    public var serverName: String?
    public var version: String?
    public var operatingSystemDisplayName: String?
    public var hasPendingRestart: Bool?
    public var hasUpdateAvailable: Bool?
    public var canSelfRestart: Bool?
}

public struct AdminPlaybackSession: Decodable, Sendable, Identifiable, Equatable {
    public struct NowPlaying: Decodable, Sendable, Equatable {
        public var id: String?
        public var name: String?
        public var seriesName: String?
        public var type: String?
        public var runTimeTicks: Int64?
        public var title: String { [seriesName, name].compactMap { $0 }.joined(separator: " · ") }
    }
    public struct PlayState: Decodable, Sendable, Equatable {
        public var isPaused: Bool?
        public var positionTicks: Int64?
        public var playMethod: String?
    }
    public var id: String
    public var userName: String?
    public var client: String?
    public var deviceName: String?
    public var applicationVersion: String?
    public var lastActivityDate: String?
    public var nowPlayingItem: NowPlaying?
    public var playState: PlayState?
    public var progress: Double? {
        guard let total = nowPlayingItem?.runTimeTicks, total > 0, let position = playState?.positionTicks else { return nil }
        return min(1, max(0, Double(position) / Double(total)))
    }
}

public struct AdminLibrary: Decodable, Sendable, Identifiable, Equatable {
    public var name: String
    public var itemId: String?
    public var collectionType: String?
    public var locations: [String]?
    public var refreshStatus: String?
    public var refreshProgress: Double?
    public var id: String { itemId ?? name }
}

public struct AdminTask: Decodable, Sendable, Identifiable, Equatable {
    public struct Result: Decodable, Sendable, Equatable {
        public var endTimeUtc: String?
        public var status: String?
        public var errorMessage: String?
    }
    public var id: String
    public var name: String
    public var category: String?
    public var description: String?
    public var state: String?
    public var currentProgressPercentage: Double?
    public var isHidden: Bool?
    public var lastExecutionResult: Result?
    public var isRunning: Bool { state == "Running" || state == "Cancelling" }
}

public struct AdminUser: Decodable, Sendable, Identifiable, Equatable {
    public struct Policy: Decodable, Sendable, Equatable {
        public var isAdministrator: Bool?
        public var isDisabled: Bool?
        public init(isAdministrator: Bool?, isDisabled: Bool?) { self.isAdministrator = isAdministrator; self.isDisabled = isDisabled }
    }
    public var id: String
    public var name: String
    public var hasPassword: Bool?
    public var lastActivityDate: String?
    public var policy: Policy?
    public var isAdministrator: Bool { policy?.isAdministrator == true }
    public var isDisabled: Bool { policy?.isDisabled == true }
}

public struct AdminActivity: Decodable, Sendable, Identifiable, Equatable {
    public var id: Int64
    public var name: String
    public var shortOverview: String?
    public var date: String?
    public var severity: String?
}

public struct AdminDevice: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String?
    public var appName: String?
    public var appVersion: String?
    public var lastUserName: String?
    public var dateLastActivity: String?
}

public struct AdminPlugin: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var version: String?
    public var status: String?
    public var description: String?
}

public struct AdminLogFile: Decodable, Sendable, Identifiable, Equatable {
    public var name: String
    public var size: Int64?
    public var dateModified: String?
    public var id: String { name }
}

/// Matches Jellyfin Web's refresh dialog choices.
public enum MetadataRefreshMode: String, CaseIterable, Sendable, Identifiable {
    case scan, missing, replaceMetadata, replaceAll
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .scan: "Scan for new and updated files"
        case .missing: "Search for missing metadata"
        case .replaceMetadata: "Replace all metadata"
        case .replaceAll: "Replace all metadata and images"
        }
    }
    var query: [URLQueryItem] {
        let full = self != .scan
        return [.init(name: "metadataRefreshMode", value: full ? "FullRefresh" : "Default"),
                .init(name: "imageRefreshMode", value: full ? "FullRefresh" : "Default"),
                .init(name: "replaceAllMetadata", value: String(self == .replaceMetadata || self == .replaceAll)),
                .init(name: "replaceAllImages", value: String(self == .replaceAll))]
    }
}

public enum AdministrationError: LocalizedError, Equatable, Sendable {
    case ownAccount, invalidInput
    public var errorDescription: String? {
        switch self {
        case .ownAccount: "You can’t change your own administrator access or remove your own account here."
        case .invalidInput: "Check the details and try again."
        }
    }
}

private struct ItemsEnvelope<Item: Decodable & Sendable>: Decodable, Sendable { var items: [Item] }

extension JellyfinClient {
    private func adminData(_ path: [String], query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                           accept: String = "application/json") async throws -> Data {
        guard session != nil else { throw ClientError.missingSession }
        return try await requestData(path, query: query, method: method, body: body, accept: accept)
    }
    private func adminDecode<T: Decodable>(_ type: T.Type, _ path: [String], query: [URLQueryItem] = []) async throws -> T {
        let data = try await adminData(path, query: query)
        do { return try Wire.decoder().decode(type, from: data) } catch { throw ClientError.invalidResponse }
    }

    // MARK: Dashboard

    public func adminServerInfo() async throws -> AdminServerInfo {
        try await adminDecode(AdminServerInfo.self, ["System", "Info"])
    }
    public func adminSessions() async throws -> [AdminPlaybackSession] {
        try await adminDecode([AdminPlaybackSession].self, ["Sessions"], query: [.init(name: "activeWithinSeconds", value: "960")])
    }
    public func adminLibraries() async throws -> [AdminLibrary] {
        try await adminDecode([AdminLibrary].self, ["Library", "VirtualFolders"])
    }
    public func scanAllLibraries() async throws {
        _ = try await adminData(["Library", "Refresh"], method: "POST")
    }
    public func refreshMetadata(itemID: String, mode: MetadataRefreshMode, recursive: Bool = true) async throws {
        _ = try await adminData(["Items", itemID, "Refresh"],
            query: mode.query + [.init(name: "recursive", value: String(recursive))], method: "POST")
    }
    public func adminTasks() async throws -> [AdminTask] {
        try await adminDecode([AdminTask].self, ["ScheduledTasks"], query: [.init(name: "isHidden", value: "false")])
            .filter { $0.isHidden != true }
    }
    public func startTask(_ id: String) async throws { _ = try await adminData(["ScheduledTasks", "Running", id], method: "POST") }
    public func stopTask(_ id: String) async throws { _ = try await adminData(["ScheduledTasks", "Running", id], method: "DELETE") }

    public func adminActivity(limit: Int = 60) async throws -> [AdminActivity] {
        try await adminDecode(ItemsEnvelope<AdminActivity>.self, ["System", "ActivityLog", "Entries"],
            query: [.init(name: "startIndex", value: "0"), .init(name: "limit", value: String(min(200, max(1, limit))))]).items
    }
    public func adminDevices() async throws -> [AdminDevice] {
        try await adminDecode(ItemsEnvelope<AdminDevice>.self, ["Devices"]).items
    }
    public func deleteDevice(_ id: String) async throws {
        guard id != identity.deviceID else { throw AdministrationError.ownAccount }
        _ = try await adminData(["Devices"], query: [.init(name: "id", value: id)], method: "DELETE")
    }
    public func adminPlugins() async throws -> [AdminPlugin] {
        try await adminDecode([AdminPlugin].self, ["Plugins"])
    }
    public func adminLogs() async throws -> [AdminLogFile] {
        try await adminDecode([AdminLogFile].self, ["System", "Logs"])
    }
    /// The tail of a server log. Large files are trimmed to keep the view responsive.
    public func adminLog(_ name: String, maxCharacters: Int = 200_000) async throws -> String {
        guard !name.isEmpty, name.count <= 255, !name.contains("/"), !name.contains("\\") else { throw AdministrationError.invalidInput }
        let data = try await adminData(["System", "Logs", "Log"], query: [.init(name: "name", value: name)], accept: "text/plain")
        let text = String(decoding: data, as: UTF8.self)
        return text.count > maxCharacters ? String(text.suffix(maxCharacters)) : text
    }
    public func restartServer() async throws { _ = try await adminData(["System", "Restart"], method: "POST") }
    public func shutDownServer() async throws { _ = try await adminData(["System", "Shutdown"], method: "POST") }

    // MARK: Users

    public func adminUsers() async throws -> [AdminUser] {
        try await adminDecode([AdminUser].self, ["Users"]).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private func guardOtherUser(_ id: String) throws {
        guard let session else { throw ClientError.missingSession }
        guard id.lowercased() != session.viewer.id.lowercased() else { throw AdministrationError.ownAccount }
    }
    /// Policy updates replace the whole policy, so start from a fresh copy and change one key.
    private func updatePolicy(userID: String, _ change: (inout [String: JSONValue]) -> Void) async throws {
        try guardOtherUser(userID)
        let data = try await adminData(["Users", userID])
        guard let user = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              user["Id"]?.string?.lowercased() == userID.lowercased(),
              var policy = user["Policy"]?.object else { throw ClientError.invalidResponse }
        change(&policy)
        _ = try await adminData(["Users", userID, "Policy"], method: "POST", body: JSONEncoder().encode(policy))
    }
    public func setUserDisabled(_ userID: String, disabled: Bool) async throws {
        try await updatePolicy(userID: userID) { $0["IsDisabled"] = .bool(disabled) }
    }
    public func setUserAdministrator(_ userID: String, administrator: Bool) async throws {
        try await updatePolicy(userID: userID) { $0["IsAdministrator"] = .bool(administrator) }
    }
    public func createUser(name: String, password: String) async throws -> AdminUser {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, password.count <= 1024 else { throw AdministrationError.invalidInput }
        let body = try JSONEncoder().encode(["Name": name, "Password": password])
        let data = try await adminData(["Users", "New"], method: "POST", body: body)
        do { return try Wire.decoder().decode(AdminUser.self, from: data) } catch { throw ClientError.invalidResponse }
    }
    public func deleteUser(_ userID: String) async throws {
        try guardOtherUser(userID)
        _ = try await adminData(["Users", userID], method: "DELETE")
    }
    /// An administrator sets another account's password without its current one.
    public func setPassword(userID: String, newPassword: String) async throws {
        try guardOtherUser(userID)
        guard !newPassword.isEmpty, newPassword.count <= 1024 else { throw AdministrationError.invalidInput }
        _ = try await adminData(["Users", "Password"], query: [.init(name: "userId", value: userID)], method: "POST",
            body: JSONEncoder().encode(["NewPw": JSONValue.string(newPassword), "ResetPassword": .bool(false)]))
    }
}

// MARK: Metadata

public struct MetadataDraft: Sendable, Equatable {
    public var id: String
    public var type: String
    public var name = ""
    public var originalTitle = ""
    public var sortName = ""
    public var overview = ""
    public var tagline = ""
    public var year = ""
    public var premiereDate: Date?
    public var officialRating = ""
    public var communityRating = ""
    public var indexNumber = ""
    public var parentIndexNumber = ""
    public var genres = ""
    public var tags = ""
    public var studios = ""
    public var lockData = false
    /// The server's copy this draft was made from; untouched keys are sent back unchanged.
    public var source: [String: JSONValue]

    public var supportsIdentify: Bool { MetadataDraft.identifyTypes.contains(type) }
    public var hasEpisodeNumbers: Bool { type == "Episode" || type == "Season" }
    static let identifyTypes: Set<String> = ["Movie", "Series", "BoxSet", "MusicAlbum", "MusicArtist", "MusicVideo", "Book", "Trailer", "Person"]

    public init(source: [String: JSONValue]) throws {
        guard let id = source["Id"]?.string, !id.isEmpty else { throw ClientError.invalidResponse }
        self.id = id; self.source = source
        type = source["Type"]?.string ?? ""
        name = source["Name"]?.string ?? ""
        originalTitle = source["OriginalTitle"]?.string ?? ""
        sortName = source["ForcedSortName"]?.string ?? ""
        overview = source["Overview"]?.string ?? ""
        tagline = source["Taglines"]?.array?.first?.string ?? ""
        year = source["ProductionYear"]?.integer.map(String.init) ?? ""
        premiereDate = AdminDate.parse(source["PremiereDate"]?.string)
        officialRating = source["OfficialRating"]?.string ?? ""
        communityRating = source["CommunityRating"]?.number.map { String(format: "%g", $0) } ?? ""
        indexNumber = source["IndexNumber"]?.integer.map(String.init) ?? ""
        parentIndexNumber = source["ParentIndexNumber"]?.integer.map(String.init) ?? ""
        genres = (source["Genres"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
        tags = (source["Tags"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
        studios = (source["Studios"]?.array ?? []).compactMap { $0.object?["Name"]?.string }.joined(separator: ", ")
        lockData = source["LockData"]?.bool ?? false
    }

    private static func list(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    private static func text(_ value: String) -> JSONValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .null : .string(trimmed)
    }
    private static func integer(_ value: String, range: ClosedRange<Int>) throws -> JSONValue {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .null }
        guard let number = Int(trimmed), range.contains(number) else { throw AdministrationError.invalidInput }
        return .int(Int64(number))
    }

    /// Only fields the editor changed, in the server's own key names.
    public func changes(from baseline: MetadataDraft) throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        if name != baseline.name {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AdministrationError.invalidInput }
            result["Name"] = Self.text(name)
        }
        if originalTitle != baseline.originalTitle { result["OriginalTitle"] = Self.text(originalTitle) }
        if sortName != baseline.sortName { result["ForcedSortName"] = Self.text(sortName) }
        if overview != baseline.overview { result["Overview"] = Self.text(overview) }
        if tagline != baseline.tagline {
            let value = tagline.trimmingCharacters(in: .whitespacesAndNewlines)
            result["Taglines"] = .array(value.isEmpty ? [] : [.string(value)])
        }
        if year != baseline.year { result["ProductionYear"] = try Self.integer(year, range: 1800...3000) }
        if premiereDate != baseline.premiereDate { result["PremiereDate"] = premiereDate.map { .string(AdminDate.format($0)) } ?? .null }
        if officialRating != baseline.officialRating { result["OfficialRating"] = Self.text(officialRating) }
        if communityRating != baseline.communityRating {
            let trimmed = communityRating.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if trimmed.isEmpty { result["CommunityRating"] = .null }
            else {
                guard let value = Double(trimmed), (0...10).contains(value) else { throw AdministrationError.invalidInput }
                result["CommunityRating"] = .double(value)
            }
        }
        if indexNumber != baseline.indexNumber { result["IndexNumber"] = try Self.integer(indexNumber, range: 0...100_000) }
        if parentIndexNumber != baseline.parentIndexNumber { result["ParentIndexNumber"] = try Self.integer(parentIndexNumber, range: 0...10_000) }
        if genres != baseline.genres { result["Genres"] = .array(Self.list(genres).map { .string($0) }) }
        if tags != baseline.tags { result["Tags"] = .array(Self.list(tags).map { .string($0) }) }
        if studios != baseline.studios { result["Studios"] = .array(Self.list(studios).map { .object(["Name": .string($0)]) }) }
        if lockData != baseline.lockData { result["LockData"] = .bool(lockData) }
        return result
    }
}

public struct RemoteSearchResult: Codable, Sendable, Identifiable, Equatable {
    public var name: String?
    public var productionYear: Int?
    public var imageUrl: String?
    public var searchProviderName: String?
    public var overview: String?
    /// The full result is posted back unchanged when applied.
    public var raw: [String: JSONValue]
    public var id: String {
        let providers = raw["ProviderIds"]?.object?.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.string ?? "")" }.joined(separator: ",") ?? ""
        return [searchProviderName ?? "", name ?? "", String(productionYear ?? 0), providers].joined(separator: "|")
    }
    public init(from decoder: any Decoder) throws {
        let raw = try [String: JSONValue](from: decoder)
        self.raw = raw
        name = raw["Name"]?.string
        productionYear = raw["ProductionYear"]?.integer
        imageUrl = raw["ImageUrl"]?.string
        searchProviderName = raw["SearchProviderName"]?.string
        overview = raw["Overview"]?.string
    }
    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
}

public extension JSONValue {
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var integer: Int? {
        switch self {
        case .int(let value): Int(exactly: value)
        case .double(let value): Int(exactly: value)
        default: nil
        }
    }
    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }
}

extension JellyfinClient {
    private func rawItem(_ id: String) async throws -> [String: JSONValue] {
        guard let session else { throw ClientError.missingSession }
        let data = try await requestData(["Items", id], query: [.init(name: "userId", value: session.viewer.id)])
        guard let item = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              item["Id"]?.string?.lowercased() == id.lowercased() else { throw ClientError.invalidResponse }
        return item
    }

    public func metadataDraft(itemID: String) async throws -> MetadataDraft {
        try MetadataDraft(source: try await rawItem(itemID))
    }

    /// Merge edited fields into a fresh server copy, refusing if someone else changed them meanwhile.
    public func saveMetadata(_ draft: MetadataDraft, baseline: MetadataDraft) async throws -> MetadataDraft {
        guard draft.id == baseline.id else { throw AdministrationError.invalidInput }
        let changes = try draft.changes(from: baseline)
        guard !changes.isEmpty else { return baseline }
        var current = try await rawItem(draft.id)
        for (key, value) in changes {
            let before = baseline.source[key] ?? .null, now = current[key] ?? .null
            guard now == before || now == value else { throw SettingsError.changedElsewhere }
            current[key] = value
        }
        _ = try await requestData(["Items", draft.id], method: "POST", body: JSONEncoder().encode(current))
        await responseCache?.invalidateMetadata()
        return try await metadataDraft(itemID: draft.id)
    }

    /// Items an administrator can edit: search everything, or browse one folder.
    public func metadataItems(search: String? = nil, parentID: String? = nil, start: Int = 0) async throws -> ItemPage {
        guard let session else { throw ClientError.missingSession }
        var query: [URLQueryItem] = [
            .init(name: "userId", value: session.viewer.id),
            .init(name: "limit", value: "50"), .init(name: "startIndex", value: String(max(0, start))),
            .init(name: "fields", value: "Overview"), .init(name: "enableImageTypes", value: "Primary"),
            .init(name: "imageTypeLimit", value: "1"),
            .init(name: "sortBy", value: parentID == nil ? "SortName" : "ParentIndexNumber,IndexNumber,SortName")]
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            query += [.init(name: "searchTerm", value: String(search.prefix(256))), .init(name: "recursive", value: "true"),
                      .init(name: "includeItemTypes", value: "Movie,Series,Season,Episode,BoxSet,MusicAlbum,MusicArtist,Audio,MusicVideo,Book,Video")]
        }
        if let parentID { query.append(.init(name: "parentId", value: parentID)) }
        return try await request(ItemPage.self, path: ["Items"], query: query)
    }

    public func remoteSearch(_ draft: MetadataDraft, name: String, year: String) async throws -> [RemoteSearchResult] {
        guard draft.supportsIdentify else { throw AdministrationError.invalidInput }
        var info: [String: JSONValue] = ["Name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let value = Int(year.trimmingCharacters(in: .whitespaces)) { info["Year"] = .int(Int64(value)) }
        if let providers = draft.source["ProviderIds"] { info["ProviderIds"] = providers }
        let body: [String: JSONValue] = ["SearchInfo": .object(info), "ItemId": .string(draft.id), "IncludeDisabledProviders": .bool(true)]
        let data = try await requestData(["Items", "RemoteSearch", draft.type], method: "POST", body: JSONEncoder().encode(body))
        do { return try JSONDecoder().decode([RemoteSearchResult].self, from: data) } catch { throw ClientError.invalidResponse }
    }

    public func applyRemoteResult(_ result: RemoteSearchResult, itemID: String, replaceImages: Bool) async throws {
        _ = try await requestData(["Items", "RemoteSearch", "Apply", itemID],
            query: [.init(name: "replaceAllImages", value: String(replaceImages))], method: "POST", body: JSONEncoder().encode(result))
        await responseCache?.invalidateMetadata()
    }
}

// MARK: Account approvals (optional signup gateway)

public struct AccountRequest: Decodable, Sendable, Identifiable, Equatable {
    public var id: String
    public var username: String
    public var status: String
    public var createdAt: Date?
    public var isPending: Bool { !["approved", "denied"].contains(status) }
    public var statusTitle: String {
        switch status {
        case "approved": "Approved"
        case "denied": "Denied"
        case "failed": "Setup needs attention"
        case "provisioning": "Setting up"
        case "approving": "Approving"
        case "denying": "Denying"
        case "pending": "Waiting for review"
        default: "Needs attention"
        }
    }
    enum CodingKeys: String, CodingKey { case id, username, status, createdAt = "created_at" }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .id) { id = text } else { id = String(try c.decode(Int64.self, forKey: .id)) }
        username = try c.decode(String.self, forKey: .username)
        status = try c.decode(String.self, forKey: .status)
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)).map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

private struct AccountRequestEnvelope: Decodable { var requests: [AccountRequest] }

extension JellyfinClient {
    /// The gateway checks the viewer's own token is an administrator on every call.
    /// Decisions also require the server's own origin, as the website sends.
    public func accountRequests() async throws -> [AccountRequest] {
        let data = try await requestData(["signup", "api", "admin", "requests"], extensionToken: true, expectedStatus: 200)
        do { return try JSONDecoder().decode(AccountRequestEnvelope.self, from: data).requests } catch { throw ClientError.invalidResponse }
    }
    public func decideAccountRequest(_ id: String, approve: Bool) async throws {
        _ = try await requestData(["signup", "api", "admin", "requests", id, approve ? "approve" : "deny"], method: "POST",
            body: Data("{}".utf8), extensionToken: true, expectedStatus: 200, sameOrigin: true)
    }
}
