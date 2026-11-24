import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), int(Int64), double(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct PlaybackOptions: Sendable {
    public var startTicks: Int64
    public var bitrate: Int
    public var audioIndex: Int?
    public var subtitleIndex: Int
    public init(startTicks: Int64 = 0, bitrate: Int = 40_000_000, audioIndex: Int? = nil, subtitleIndex: Int = -1) {
        self.startTicks = max(0, startTicks); self.bitrate = min(40_000_000, max(1_000_000, bitrate))
        self.audioIndex = audioIndex; self.subtitleIndex = max(-2, subtitleIndex)
    }
}

public enum PlaybackProfile {
    /// Deliberately narrow until physical devices have passed the codec matrix.
    public static func conservative(bitrate: Int) -> JSONValue {
        func condition(_ property: String, _ value: String, _ comparison: String = "LessThanEqual") -> JSONValue {
            .object(["Property": .string(property), "Value": .string(value),
                     "Condition": .string(comparison), "IsRequired": .bool(true)])
        }
        return .object([
            "Name": .string("Zorofin AVPlayer SDR"),
            "MaxStreamingBitrate": .int(Int64(bitrate)), "MaxStaticBitrate": .int(Int64(bitrate)),
            "DirectPlayProfiles": .array([.object([
                "Type": .string("Video"), "Container": .string("mp4,m4v"),
                "VideoCodec": .string("h264"), "AudioCodec": .string("aac")])]),
            "TranscodingProfiles": .array([.object([
                "Type": .string("Video"), "Container": .string("ts"), "Protocol": .string("hls"),
                "VideoCodec": .string("h264"), "AudioCodec": .string("aac"),
                "Context": .string("Streaming"), "MaxAudioChannels": .string("2"),
                "MinSegments": .int(2), "SegmentLength": .int(4),
                "CopyTimestamps": .bool(false), "EnableSubtitlesInManifest": .bool(false)])]),
            "CodecProfiles": .array([
                .object(["Type": .string("Video"), "Codec": .string("h264"), "Conditions": .array([
                    condition("VideoBitDepth", "8"), condition("Width", "1920"), condition("Height", "1080"),
                    condition("VideoLevel", "41"), condition("VideoFramerate", "30"),
                    condition("VideoProfile", "high|main|baseline|constrained baseline", "EqualsAny"),
                    condition("VideoRangeType", "SDR", "Equals"),
                    condition("IsInterlaced", "false", "Equals")])]),
                .object(["Type": .string("VideoAudio"), "Codec": .string("aac"),
                         "Conditions": .array([condition("AudioChannels", "2")])])]),
            "ContainerProfiles": .array([]),
            "SubtitleProfiles": .array(["subrip", "srt", "ass", "ssa", "pgssub", "dvdsub", "webvtt"].map {
                .object(["Format": .string($0), "Method": .string("Encode")])
            })
        ])
    }
    public static func request(userID: String, options: PlaybackOptions) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "UserId": .string(userID), "StartTimeTicks": .int(options.startTicks),
            "MaxStreamingBitrate": .int(Int64(options.bitrate)), "MaxAudioChannels": .int(2),
            "DeviceProfile": conservative(bitrate: options.bitrate),
            "SubtitleStreamIndex": .int(Int64(options.subtitleIndex)),
            "EnableDirectPlay": .bool(options.audioIndex == nil && options.subtitleIndex == -1),
            "EnableDirectStream": .bool(false), "EnableTranscoding": .bool(true),
            "AllowVideoStreamCopy": .bool(true), "AllowAudioStreamCopy": .bool(true),
            "AutoOpenLiveStream": .bool(false), "AlwaysBurnInSubtitleWhenTranscoding": .bool(true)
        ]
        if let audio = options.audioIndex { payload["AudioStreamIndex"] = .int(Int64(audio)) }
        return payload
    }
}

public struct PlaybackPlan: Sendable {
    public let itemID: String
    public let sourceID: String
    public let sessionID: String
    public let url: URL
    public let method: String
    public let liveStreamID: String?
    public let requiresClosing: Bool
    public let options: PlaybackOptions

    public static func make(info: PlaybackInfo, source: MediaSource? = nil, itemID: String,
                            client: JellyfinClient, options: PlaybackOptions) throws -> PlaybackPlan {
        if let session = client.session, session.server != client.server { throw ClientError.unsafeURL }
        guard info.errorCode == nil, let session = client.session,
              let source = source ?? info.mediaSources?.first,
              let sourceID = source.id, let playSessionID = info.playSessionId,
              source.requiresOpening != true || source.liveStreamId != nil else { throw ClientError.unsupportedPlayback }
        let method: String
        let target: URL
        if source.supportsDirectPlay == true && options.audioIndex == nil && options.subtitleIndex == -1 {
            method = "DirectPlay"
            var query: [URLQueryItem] = [
                .init(name: "static", value: "true"), .init(name: "MediaSourceId", value: sourceID),
                .init(name: "DeviceId", value: client.identity.deviceID),
                .init(name: "PlaySessionId", value: playSessionID)]
            if let stream = source.liveStreamId { query.append(.init(name: "LiveStreamId", value: stream)) }
            let direct = try client.server.endpoint(["Videos", itemID, "stream"], query: query)
            target = try client.server.mediaURL(direct.absoluteString, token: session.token)
        } else if source.supportsTranscoding == true, let reference = source.transcodingUrl,
                  source.transcodingSubProtocol?.lowercased() == "hls" || reference.lowercased().contains(".m3u8") {
            method = "Transcode"
            target = try client.server.mediaURL(reference, token: session.token)
        } else { throw ClientError.unsupportedPlayback }
        return PlaybackPlan(itemID: itemID, sourceID: sourceID, sessionID: playSessionID, url: target,
            method: method, liveStreamID: source.liveStreamId, requiresClosing: source.requiresClosing == true,
            options: options)
    }

    public func report(positionTicks: Int64, paused: Bool, canSeek: Bool) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "ItemId": .string(itemID), "MediaSourceId": .string(sourceID),
            "PlaySessionId": .string(sessionID), "PositionTicks": .int(max(0, positionTicks)),
            "IsPaused": .bool(paused), "CanSeek": .bool(canSeek), "PlayMethod": .string(method),
            "SubtitleStreamIndex": .int(Int64(options.subtitleIndex))
        ]
        if let liveStreamID { result["LiveStreamId"] = .string(liveStreamID) }
        if let audio = options.audioIndex { result["AudioStreamIndex"] = .int(Int64(audio)) }
        return result
    }
}

public extension JellyfinClient {
    func playbackInfo(for item: MediaItem, options: PlaybackOptions) async throws -> PlaybackInfo {
        guard item.isPlayableVideo else { throw PlaybackSelectionError.unsupportedItem }
        // Channel detail DTOs can contain a placeholder file source whose ID is
        // not a tuner source. Resolve current live sources through PlaybackInfo.
        return try await playbackInfo(itemID: item.id, options: options,
                               sourceID: item.isLive ? nil : item.mediaSources?.first?.id)
    }

    func playbackInfo(itemID: String, options: PlaybackOptions, sourceID: String? = nil) async throws -> PlaybackInfo {
        guard let session else { throw ClientError.missingSession }
        // Both supported server versions only apply track selections when the
        // request identifies their media source. Discover it when the caller
        // has no detail metadata; never assume the item ID is the source ID.
        let selectedID: String
        if let sourceID, !sourceID.isEmpty { selectedID = sourceID }
        else {
            let discovered = try await request(PlaybackInfo.self, path: ["Items", itemID, "PlaybackInfo"],
                query: [.init(name: "userId", value: session.viewer.id)])
            guard discovered.errorCode == nil, let id = discovered.mediaSources?.first?.id, !id.isEmpty else {
                throw ClientError.unsupportedPlayback
            }
            selectedID = id
        }
        var payload = PlaybackProfile.request(userID: session.viewer.id, options: options)
        payload["MediaSourceId"] = .string(selectedID)
        return try await request(PlaybackInfo.self, path: ["Items", itemID, "PlaybackInfo"], method: "POST",
            body: JSONEncoder().encode(payload))
    }
    func openLive(source: MediaSource, info: PlaybackInfo, itemID: String, options: PlaybackOptions) async throws -> MediaSource {
        guard let session, let openToken = source.openToken, let sessionID = info.playSessionId else {
            throw ClientError.unsupportedPlayback
        }
        var body = PlaybackProfile.request(userID: session.viewer.id, options: options)
        body["OpenToken"] = .string(openToken); body["PlaySessionId"] = .string(sessionID); body["ItemId"] = .string(itemID)
        return try await request(LiveStreamResponse.self, path: ["LiveStreams", "Open"], method: "POST",
            body: JSONEncoder().encode(body)).mediaSource
    }
    func closeLive(_ id: String) async throws {
        _ = try await requestData(["LiveStreams", "Close"], query: [.init(name: "liveStreamId", value: id)], method: "POST")
    }
    func reportPlayback(_ event: String, payload: [String: JSONValue]) async throws {
        let path = event == "start" ? ["Sessions", "Playing"] : ["Sessions", "Playing", event == "stop" ? "Stopped" : "Progress"]
        _ = try await requestData(path, method: "POST", body: JSONEncoder().encode(payload))
        // Do not serve a pre-completion Resume/Next Up snapshot after the server
        // has acknowledged the final position, including automatic episode changes.
        if event == "stop" { await responseCache?.invalidateMetadata() }
    }
}

public enum MediaTime {
    public static func ticks(seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64(min(seconds * 10_000_000, Double(Int64.max / 2)))
    }
    public static func seconds(ticks: Int64) -> Double { Double(max(0, ticks)) / 10_000_000 }
}
