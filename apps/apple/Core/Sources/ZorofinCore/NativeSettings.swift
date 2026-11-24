import Foundation
import CryptoKit

public extension JSONValue {
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

/// Device preferences are scoped to the selected server and viewer, never global.
public struct NativePreferences: Codable, Equatable, Sendable {
    public var bitrate = 40_000_000
    public var posterScale = 1.0
    public var showTitles = true
    public var showProgress = true
    public var showRatings = false
    // Optional keeps saved preferences from older builds decodable; nil means enabled.
    public var homeScreenPreviews: Bool?
    // Optional additions preserve existing preference files and their saved values.
    public var showQualityBadges: Bool?
    public var hideAvailableRequests: Bool?
    public var subtitleAppearance: SubtitleAppearance?
    public var reduceMotion = false
    public var pictureInPicture = true
    public var pauseInBackground = true
    public var skipBack = 10
    public var skipForward = 30
    public var playbackSpeed = 1.0
    public var showUnreadBadge = true
    public init() {}
    public var isValid: Bool {
        [2,4,8,12,20,40].map { $0 * 1_000_000 }.contains(bitrate) &&
        [0.85,1.0,1.2].contains(posterScale) && [5,10,15,30,60].contains(skipBack) &&
        [5,10,15,30,60].contains(skipForward) && [0.5,0.75,1,1.25,1.5,2].contains(playbackSpeed) &&
        (subtitleAppearance?.isValid ?? true)
    }
}

public actor NativePreferenceStore {
    private let root: URL?
    private let defaults: UserDefaults?
    private static let prefix = "ZorofinPreferences-v1."

    public init(root: URL? = nil) {
        #if os(tvOS)
        // tvOS only permits persistent local preferences through UserDefaults.
        // Artwork/library caches remain separate and may be evicted by the OS.
        self.root = root
        defaults = root == nil ? .standard : nil
        #else
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZorofinPreferences-v1", isDirectory: true)
        defaults = nil
        #endif
    }
    // Isolated defaults domains let tests exercise the TV backend on macOS.
    init(defaultsSuiteName: String) {
        root = nil
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }
    private func key(server: ServerAddress, viewerID: String) -> String {
        SHA256.hash(data: Data((server.storageKey + "\n" + viewerID).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func load(server: ServerAddress, viewerID: String) throws -> NativePreferences {
        let key = key(server: server, viewerID: viewerID)
        let data: Data
        if let defaults {
            guard let saved = defaults.data(forKey: Self.prefix + key) else { return .init() }
            data = saved
        } else if let root {
            let url = root.appendingPathComponent(key + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
            data = try Data(contentsOf: url)
        } else { throw SettingsError.invalidInput }
        let value = try JSONDecoder().decode(NativePreferences.self, from: data)
        guard value.isValid else { throw SettingsError.invalidInput }
        return value
    }
    public func save(_ value: NativePreferences, server: ServerAddress, viewerID: String) throws {
        guard value.isValid else { throw SettingsError.invalidInput }
        let key = key(server: server, viewerID: viewerID)
        let data = try JSONEncoder().encode(value)
        if let defaults {
            let storageKey = Self.prefix + key
            let existingBytes = defaults.dictionaryRepresentation().reduce(0) { total, entry in
                total + (entry.key.hasPrefix(Self.prefix) && entry.key != storageKey ?
                    (entry.value as? Data)?.count ?? 0 : 0)
            }
            // Keep our tiny settings well below tvOS's 512 KB warning threshold.
            guard existingBytes + data.count <= 128 * 1024 else { throw SettingsError.storageFull }
            defaults.set(data, forKey: storageKey)
        } else if let root {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent(key + ".json"), options: .atomic)
        } else { throw SettingsError.invalidInput }
    }
}

public enum SettingsError: LocalizedError, Equatable, Sendable {
    case invalidInput, unconfirmed, changedElsewhere, storageFull
    public var errorDescription: String? {
        switch self {
        case .invalidInput: "Check the settings and try again."
        case .storageFull: "This device has reached its saved-settings limit."
        case .unconfirmed: "The server may have saved the change, but confirmation was lost. Reload settings before trying again."
        case .changedElsewhere: "These settings changed on another device. Reload before saving again."
        }
    }
}

public struct ViewerSettings: Sendable, Equatable {
    public var name: String
    public var hasImage: Bool
    public var hasPassword: Bool
    public var canEdit: Bool
    public var configuration: [String: JSONValue]
    public init(name: String, hasImage: Bool = false, hasPassword: Bool = true, canEdit: Bool = true, configuration: [String: JSONValue] = [:]) {
        self.name = name; self.hasImage = hasImage; self.hasPassword = hasPassword; self.canEdit = canEdit; self.configuration = configuration
    }
    public func string(_ key: String, fallback: String = "") -> String { configuration[key]?.string ?? fallback }
    public func bool(_ key: String, fallback: Bool = false) -> Bool { configuration[key]?.bool ?? fallback }

    /// Mirror account language/mode preferences while keeping explicit per-title choices authoritative.
    public func playbackOptions(_ original: PlaybackOptions, item: MediaItem) -> PlaybackOptions {
        var result = original
        let source = item.mediaSources?.first
        let audio = source?.mediaStreams?.filter { $0.type == "Audio" } ?? []
        let subtitles = source?.mediaStreams?.filter { $0.type == "Subtitle" } ?? []
        if result.audioIndex == nil {
            // Jellyfin's per-viewer defaults already include remembered selections.
            let serverChoice = audio.first { $0.index == source?.defaultAudioStreamIndex }
            let fileDefault = audio.first { $0.isDefault == true } ?? audio.first
            var choice = serverChoice
            if choice == nil, !bool("PlayDefaultAudioTrack", fallback: true) {
                let preference = string("AudioLanguagePreference")
                choice = audio.first { Self.sameLanguage($0.language, preference) }
            }
            // Leave the file's default implicit to preserve direct playback.
            if let choice, choice.index != fileDefault?.index { result.audioIndex = choice.index }
        }
        let selectedAudio = audio.first { $0.index == result.audioIndex } ??
            audio.first { $0.index == source?.defaultAudioStreamIndex } ?? audio.first { $0.isDefault == true } ?? audio.first
        guard result.subtitleIndex == -2 else { return result }
        if string("SubtitleMode", fallback: "Default") == "None" { result.subtitleIndex = -1; return result }
        if original.audioIndex == nil, let serverChoice = source?.defaultSubtitleStreamIndex,
           serverChoice == -1 || subtitles.contains(where: { $0.index == serverChoice }) {
            // A remembered Off choice is meaningful too. Explicit audio choices
            // recompute the language fallback instead of using the previous audio.
            result.subtitleIndex = serverChoice
            return result
        }
        let preference = string("SubtitleLanguagePreference")
        let matching = subtitles.filter { Self.sameLanguage($0.language, preference) }
        let forced = subtitles.first { $0.isForced == true && Self.sameLanguage($0.language, selectedAudio?.language ?? preference) }
        let remembered = subtitles.first { $0.index == source?.defaultSubtitleStreamIndex }
        let selected: MediaStream?
        switch string("SubtitleMode", fallback: "Default") {
        case "None": selected = nil
        case "OnlyForced": selected = forced
        case "Always": selected = matching.first ?? remembered ?? subtitles.first
        case "Smart": selected = Self.sameLanguage(selectedAudio?.language, preference) ? forced : matching.first ?? forced
        default: selected = remembered ?? forced
        }
        result.subtitleIndex = selected?.index ?? -1
        return result
    }
    private static func sameLanguage(_ first: String?, _ second: String) -> Bool {
        func normalized(_ value: String) -> String {
            let base = value.lowercased().split(separator: "-").first.map(String.init) ?? ""
            return ["en":"eng", "es":"spa", "fr":"fra", "fre":"fra", "de":"deu", "ger":"deu",
                "ar":"ara", "ur":"urd", "hi":"hin", "ja":"jpn", "ko":"kor", "zh":"zho", "chi":"zho",
                "pt":"por", "it":"ita", "ru":"rus", "tr":"tur", "nl":"nld", "dut":"nld" ][base] ?? base
        }
        guard let first, !first.isEmpty, !second.isEmpty else { return false }
        return normalized(first) == normalized(second)
    }
}

public struct SettingsLanguage: Identifiable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

extension JellyfinClient {
    public func viewerSettings() async throws -> ViewerSettings {
        guard let session else { throw ClientError.missingSession }
        let data = try await requestData(["Users", "Me"], expectedStatus: 200)
        let user = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard user["Id"]?.string?.lowercased() == session.viewer.id.lowercased(),
              let name = user["Name"]?.string, let configuration = user["Configuration"]?.object else { throw ClientError.invalidResponse }
        return ViewerSettings(name: name, hasImage: user["PrimaryImageTag"]?.string != nil, hasPassword: user["HasPassword"]?.bool ?? true,
            canEdit: user["Policy"]?.object?["EnableUserPreferenceAccess"]?.bool != false, configuration: configuration)
    }

    /// Merge only edited fields into a fresh server snapshot. Unknown fields survive unchanged.
    public func saveViewerConfiguration(changes: [String: JSONValue], baseline: ViewerSettings) async throws -> ViewerSettings {
        let booleanKeys: Set<String> = ["PlayDefaultAudioTrack", "RememberAudioSelections", "RememberSubtitleSelections", "EnableNextEpisodeAutoPlay"]
        for (key,value) in changes {
            if booleanKeys.contains(key) { guard value.bool != nil else { throw SettingsError.invalidInput } }
            else if ["AudioLanguagePreference", "SubtitleLanguagePreference"].contains(key) {
                guard let language = value.string, language.count <= 12,
                      language.isEmpty || language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$", options: .regularExpression) != nil else { throw SettingsError.invalidInput }
            } else if key == "SubtitleMode" {
                guard ["Default","Always","OnlyForced","None","Smart"].contains(value.string) else { throw SettingsError.invalidInput }
            } else { throw SettingsError.invalidInput }
        }
        var current = try await viewerSettings()
        guard current.canEdit else { throw ClientError.forbidden }
        guard !changes.isEmpty else { return current }
        for (key,value) in changes {
            guard current.configuration[key] == baseline.configuration[key] || current.configuration[key] == value else { throw SettingsError.changedElsewhere }
            current.configuration[key] = value
        }
        try await settingsMutation(["Users", "Configuration"], body: JSONEncoder().encode(current.configuration))
        do {
            let confirmed = try await viewerSettings()
            guard changes.allSatisfy({ confirmed.configuration[$0.key] == $0.value }) else { throw SettingsError.unconfirmed }
            return confirmed
        } catch { throw SettingsError.unconfirmed }
    }

    public func changeOwnPassword(current: String, new: String) async throws {
        guard !new.isEmpty, new.count <= 1024, current.count <= 1024 else { throw SettingsError.invalidInput }
        let snapshot = try await viewerSettings()
        guard snapshot.canEdit else { throw ClientError.forbidden }
        // Explicit userId means an administrator changing their own password must also prove the old password.
        try await settingsMutation(["Users", "Password"], body: JSONEncoder().encode([
            "CurrentPw": JSONValue.string(current), "NewPw": .string(new), "ResetPassword": .bool(false)]))
    }

    private func settingsMutation(_ path: [String], body: Data) async throws {
        guard let session else { throw ClientError.missingSession }
        do {
            _ = try await requestData(path, query: [.init(name: "userId", value: session.viewer.id)], method: "POST",
                body: body, expectedStatus: 204)
        } catch let error as ClientError where [.unauthorized,.forbidden,.missingSession,.unsafeURL].contains(error) { throw error }
        catch { throw SettingsError.unconfirmed }
    }

    public func settingsLanguages() async throws -> [SettingsLanguage] {
        let data = try await requestData(["Localization", "Cultures"], expectedStatus: 200, cachePolicy: .detail)
        let values = try JSONDecoder().decode([[String: JSONValue]].self, from: data)
        var result: [SettingsLanguage] = []
        for value in values {
            guard let code = value["ThreeLetterISOLanguageName"]?.string ?? value["TwoLetterISOLanguageName"]?.string,
                  let name = value["DisplayName"]?.string, !result.contains(where: { $0.id == code }) else { continue }
            result.append(.init(id: code, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func followingEpisode(_ item: MediaItem) async throws -> MediaItem? {
        guard item.isEpisode, let series = item.seriesId, let session else { return nil }
        let page = try await request(ItemPage.self, path: ["Shows", series, "Episodes"], query: [
            .init(name: "userId", value: session.viewer.id), .init(name: "startItemId", value: item.id),
            .init(name: "isMissing", value: "false"), .init(name: "limit", value: "2"), .init(name: "fields", value: "MediaSources")])
        guard let index = page.items.firstIndex(where: { $0.id == item.id }), page.items.indices.contains(index + 1) else { return nil }
        let next = page.items[index + 1]
        guard next.isEpisode, next.seriesId == series, next.id != item.id else { return nil }
        return next
    }
}

public struct RequestAlertSettings: Decodable, Sendable {
    public struct Account: Decodable, Sendable { public let id: String; public let name: String }
    public struct Email: Decodable, Sendable { public let enabled: Bool; public let maskedAddress: String }
    public struct Push: Decodable, Sendable {
        public let enabled: Bool
        public let server: String
        public let topic: String?
        public let username: String?
    }
    public struct Credentials: Decodable, Sendable {
        public let server: String; public let topic: String; public let username: String; public let password: String
    }
    public let account: Account
    public let email: Email
    public let push: Push
    public let message: String?
    public var credentials: Credentials?
}

public enum RequestAlertAction: String, Sendable {
    case saveEmail = "email/save", removeEmail = "email/remove", testEmail = "email/test"
    case createPush = "push/create", resetPush = "push/reset", removePush = "push/remove", testPush = "push/test"
}

extension JellyfinClient {
    public func requestAlertSettings() async throws -> RequestAlertSettings {
        let data = try await requestData(["support","request-alerts"], extensionToken: true, expectedStatus: 200)
        return try decodeAlertSettings(data)
    }
    public func updateRequestAlerts(_ action: RequestAlertAction, email: String = "") async throws -> RequestAlertSettings {
        if action == .saveEmail {
            guard email.count <= 254, email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil else { throw SettingsError.invalidInput }
        }
        do {
            let data = try await requestData(["support","request-alerts"] + action.rawValue.split(separator: "/").map(String.init),
                method: "POST", body: JSONEncoder().encode(action == .saveEmail ? ["email": email] : [:]),
                extensionToken: true, expectedStatus: 200)
            return try decodeAlertSettings(data)
        } catch let error as ClientError where [.unauthorized,.forbidden,.missingSession,.unsafeURL].contains(error) { throw error }
        catch { throw SettingsError.unconfirmed }
    }
    private func decodeAlertSettings(_ data: Data) throws -> RequestAlertSettings {
        let result = try JSONDecoder().decode(RequestAlertSettings.self, from: data)
        guard result.account.id == session?.viewer.id else { throw ClientError.invalidResponse }
        return result
    }
}

extension JellyfinClient {
    public func ownProfileImage() async throws -> Data {
        guard let session else { throw ClientError.missingSession }
        return try await requestData(["Users",session.viewer.id,"Images","Primary"],
            query: [.init(name:"maxWidth",value:"256"),.init(name:"quality",value:"85")], accept:"image/jpeg")
    }
    public func updateOwnProfileImage(jpeg: Data?) async throws {
        guard let session else { throw ClientError.missingSession }
        if let jpeg { guard !jpeg.isEmpty, jpeg.count <= 2 * 1024 * 1024 else { throw SettingsError.invalidInput } }
        guard try await viewerSettings().canEdit else { throw ClientError.forbidden }
        do {
            _ = try await requestData(["UserImage"],query:[.init(name:"userId",value:session.viewer.id)],
                method: jpeg == nil ? "DELETE" : "POST",body:jpeg.map { Data($0.base64EncodedString().utf8) },
                expectedStatus:204,contentType:"image/jpeg")
        } catch let error as ClientError where [.unauthorized,.forbidden,.missingSession,.unsafeURL].contains(error) { throw error }
        catch { throw SettingsError.unconfirmed }
    }
}
