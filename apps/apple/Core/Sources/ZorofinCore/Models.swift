import Foundation

public enum Wire {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let name = path.last!.stringValue
            return Key(stringValue: name.prefix(1).lowercased() + name.dropFirst())
        }
        return decoder
    }
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            let name = path.last!.stringValue
            return Key(stringValue: name.prefix(1).uppercased() + name.dropFirst())
        }
        return encoder
    }
}

public struct PublicSystemInfo: Codable, Sendable {
    public var serverName: String?
    public var version: String?
    public var id: String?
}

public struct Viewer: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var policy: ViewerPolicy?
    public init(id: String, name: String, policy: ViewerPolicy? = nil) {
        self.id = id; self.name = name; self.policy = policy
    }
}

public struct ViewerPolicy: Codable, Hashable, Sendable {
    public var isAdministrator: Bool?
    public var syncPlayAccess: String?
    public var enableContentDownloading: Bool?
    public init(isAdministrator: Bool = false) { self.isAdministrator = isAdministrator }
}

public struct LoginResponse: Codable, Sendable {
    public var accessToken: String
    public var user: Viewer
    public var serverId: String?
}

public struct Session: Codable, Sendable {
    public var server: ServerAddress
    public var viewer: Viewer
    public var token: String
    public var deviceID: String
    public init(server: ServerAddress, viewer: Viewer, token: String, deviceID: String) {
        self.server = server; self.viewer = viewer; self.token = token; self.deviceID = deviceID
    }
}

public struct QuickConnectState: Decodable, Sendable {
    public var authenticated: Bool
    public var secret: String
    public var code: String
}

public struct ItemPage: Codable, Sendable {
    public var items: [MediaItem]
    public var totalRecordCount: Int?
    public var startIndex: Int?
    public init(items: [MediaItem], totalRecordCount: Int? = nil) {
        self.items = items; self.totalRecordCount = totalRecordCount
    }
}

public struct UserData: Codable, Hashable, Sendable {
    public var playbackPositionTicks: Int64?
    public var lastPlayedDate: String?
    public var playedPercentage: Double?
    public var isFavorite: Bool?
    public var played: Bool?
    /// Jellyfin's thumbs-up; Zorofin's watchlist ("Watch later").
    public var likes: Bool?
    public init(playbackPositionTicks: Int64? = nil, isFavorite: Bool? = nil, played: Bool? = nil) {
        self.playbackPositionTicks = playbackPositionTicks; self.isFavorite = isFavorite; self.played = played
    }
}

public struct Person: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var role: String?
    public var type: String?
    public var primaryImageTag: String?
}

public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var type: String?
    public var overview: String?
    public var productionYear: Int?
    public var officialRating: String?
    public var communityRating: Double?
    public var runTimeTicks: Int64?
    public var imageTags: [String: String]?
    public var backdropImageTags: [String]?
    public var parentBackdropItemId: String?
    public var parentBackdropImageTags: [String]?
    public var seriesId: String?
    public var seriesName: String?
    public var seasonId: String?
    public var indexNumber: Int?
    public var parentIndexNumber: Int?
    public var genres: [String]?
    public var taglines: [String]?
    public var userData: UserData?
    public var mediaSources: [MediaSource]?
    public var mediaStreams: [MediaStream]?
    public var container: String?
    public var people: [Person]?
    public var channelNumber: String?
    public var currentProgram: LiveProgram?
    /// Jellyfin local trailer extras; 0 means a preview lookup can be skipped.
    public var localTrailerCount: Int?

    public init(id: String, name: String, type: String = "Movie", overview: String? = nil,
                productionYear: Int? = nil, userData: UserData? = nil) {
        self.id = id; self.name = name; self.type = type; self.overview = overview
        self.productionYear = productionYear; self.userData = userData
    }
    public var isSeries: Bool { type == "Series" }
    public var isEpisode: Bool { type == "Episode" }
    public var isLive: Bool { type == "TvChannel" }
    public var displayTitle: String { isEpisode ? (seriesName ?? name) : name }
    public var episodeLabel: String {
        guard isEpisode else { return "" }
        return "S\(parentIndexNumber ?? 1) E\(indexNumber ?? 1) · \(name)"
    }
    public var resumeTicks: Int64 { max(0, userData?.playbackPositionTicks ?? 0) }
    public var durationLabel: String {
        let minutes = Int((runTimeTicks ?? 0) / 600_000_000)
        guard minutes > 0 else { return "" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

public struct MediaStream: Codable, Hashable, Sendable {
    public var index: Int
    public var type: String?
    public var codec: String?
    public var displayTitle: String?
    public var language: String?
    public var isDefault: Bool?
    public var isExternal: Bool?
    public var isForced: Bool?
    public var isHearingImpaired: Bool?
    public var width: Int?
    public var height: Int?
    public var videoRange: String?
    public var videoRangeType: String?
    public var bitDepth: Int?
    public var bitRate: Int?
    public var channels: Int?
    public var channelLayout: String?
    public var profile: String?
    public var audioSpatialFormat: String?
    public var averageFrameRate: Double?
    public var isInterlaced: Bool?
    public var isAttachedPic: Bool?
}

public struct MediaSource: Codable, Hashable, Sendable {
    public var id: String?
    public var container: String?
    public var size: Int64?
    public var bitrate: Int?
    public var supportsDirectPlay: Bool?
    public var supportsDirectStream: Bool?
    public var supportsTranscoding: Bool?
    public var transcodingUrl: String?
    public var transcodingSubProtocol: String?
    public var requiresOpening: Bool?
    public var requiresClosing: Bool?
    public var openToken: String?
    public var liveStreamId: String?
    public var defaultAudioStreamIndex: Int?
    public var defaultSubtitleStreamIndex: Int?
    public var mediaStreams: [MediaStream]?
}

public struct PlaybackInfo: Codable, Sendable {
    public var mediaSources: [MediaSource]?
    public var playSessionId: String?
    public var errorCode: String?
}

public struct LiveStreamResponse: Decodable, Sendable {
    public var mediaSource: MediaSource
}
