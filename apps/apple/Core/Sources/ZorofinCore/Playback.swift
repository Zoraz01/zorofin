import Foundation
#if canImport(VideoToolbox)
import VideoToolbox
#endif

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
    /// Deliver text subtitles as WebVTT renditions in the HLS manifest instead
    /// of burning them in, so a subtitle choice no longer forces a full video
    /// encode. Only the streaming player sets this, for movies and episodes;
    /// downloads and Live TV keep burn-in.
    public var manifestSubtitles = false
    public init(startTicks: Int64 = 0, bitrate: Int = 40_000_000, audioIndex: Int? = nil, subtitleIndex: Int = -1) {
        self.startTicks = max(0, startTicks); self.bitrate = min(120_000_000, max(1_000_000, bitrate))
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
    /// Hardware HEVC decode distinguishes 4K-capable Apple players from the
    /// older compatibility path. Container, HDR and audio are not implied by 4K.
    public static var hardwareHEVC: Bool {
        #if canImport(VideoToolbox)
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        #else
        return false
        #endif
    }
    public static let hevcVideoRanges = "SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHDR10Plus|DOVIWithHLG|DOVIWithSDR"
    public static let manifestSubtitleFormats = ["subrip", "srt", "webvtt", "vtt", "ass", "ssa", "mov_text", "ttml"]
    public static func avPlayer(bitrate: Int, hevc: Bool, manifestSubtitles: Bool = false) -> JSONValue {
        guard hevc, case .object(var profile) = conservative(bitrate: bitrate) else {
            return conservative(bitrate: bitrate)
        }
        func condition(_ property: String, _ value: String, _ comparison: String = "LessThanEqual") -> JSONValue {
            .object(["Property": .string(property), "Value": .string(value),
                "Condition": .string(comparison), "IsRequired": .bool(true)])
        }
        profile["Name"] = .string("Zorofin AVPlayer 4K")
        profile["DirectPlayProfiles"] = .array([.object([
            "Type": .string("Video"), "Container": .string("mp4,m4v,mov"),
            "VideoCodec": .string("h264,hevc"), "AudioCodec": .string("aac,ac3,eac3")])])
        // Keep TS/H264 HLS available for live sources requiring the most compatible profile.
        let liveFallback: [JSONValue]
        if case .array(let profiles) = profile["TranscodingProfiles"] { liveFallback = profiles }
        else { liveFallback = [] }
        profile["TranscodingProfiles"] = .array([.object([
            "Type": .string("Video"), "Container": .string("mp4"), "Protocol": .string("hls"),
            // Copy Dolby audio into the remux instead of converting it to stereo
            // AAC; AVPlayer decodes or passes AC-3 and E-AC-3 through to the TV.
            "VideoCodec": .string("h264,hevc"), "AudioCodec": .string("aac,ac3,eac3"),
            "Context": .string("Streaming"), "MaxAudioChannels": .string("8"),
            "MinSegments": .int(2), "SegmentLength": .int(4),
            "CopyTimestamps": .bool(false), "EnableSubtitlesInManifest": .bool(manifestSubtitles)])] + liveFallback)
        if manifestSubtitles {
            // Image subtitles (PGS, DVD) cannot be WebVTT and are still burned in.
            profile["SubtitleProfiles"] = .array(manifestSubtitleFormats.map {
                JSONValue.object(["Format": .string($0), "Method": .string("Hls")])
            } + ["pgssub", "dvdsub", "dvbsub"].map {
                JSONValue.object(["Format": .string($0), "Method": .string("Encode")])
            })
        }
        // AVPlayer shows HDR10, HLG and Dolby Vision 5/8 on HDR TVs and tone-maps
        // them on SDR ones. Dolby Vision 7 (DOVIWithEL) and invalid metadata
        // still convert.
        profile["CodecProfiles"] = .array([("h264", "51", "8", "high|main|baseline|constrained baseline", "SDR"),
            ("hevc", "153", "10", "main|main 10", hevcVideoRanges)].map { codec, level, depth, profiles, ranges in
            JSONValue.object(["Type": .string("Video"), "Codec": .string(codec), "Conditions": .array([
                condition("Width", "3840"), condition("Height", "2160"),
                condition("VideoFramerate", "60"), condition("VideoLevel", level),
                condition("VideoBitDepth", depth), condition("VideoProfile", profiles, "EqualsAny"),
                condition("VideoRangeType", ranges, "EqualsAny"), condition("IsInterlaced", "false", "Equals")])])
        } + [
            // AVPlayer rejects hev1/dvhe-tagged MP4 files; those remux to HLS instead.
            JSONValue.object(["Type": .string("Video"), "Codec": .string("hevc"), "Container": .string("mp4,m4v,mov"),
                "Conditions": .array([.object(["Property": .string("VideoCodecTag"), "Value": .string("hvc1|dvh1"),
                    "Condition": .string("EqualsAny"), "IsRequired": .bool(false)])])])
        ] + ["h264", "hevc"].flatMap { codec in
            // HD sports can retain 60fps; preserve the separate conservative
            // 4K30 ceiling until the full device matrix is accepted.
            [("Width", "1921"), ("Height", "1081")].map { dimension, limit in
                JSONValue.object(["Type": .string("Video"), "Codec": .string(codec),
                    "ApplyConditions": .array([condition(dimension, limit, "GreaterThanEqual")]),
                    "Conditions": .array([condition("VideoFramerate", "30")])])
            }
        } + ["aac", "ac3", "eac3"].map { codec in
            .object(["Type": .string("VideoAudio"), "Codec": .string(codec),
                "Conditions": .array([condition("AudioChannels", codec == "eac3" ? "8" : "6")])])
        })
        return .object(profile)
    }
    public static func request(userID: String, options: PlaybackOptions) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "UserId": .string(userID), "StartTimeTicks": .int(options.startTicks),
            "MaxStreamingBitrate": .int(Int64(options.bitrate)), "MaxAudioChannels": .int(hardwareHEVC ? 8 : 2),
            "DeviceProfile": avPlayer(bitrate: options.bitrate, hevc: hardwareHEVC,
                                      manifestSubtitles: options.manifestSubtitles),
            "SubtitleStreamIndex": .int(Int64(options.subtitleIndex)),
            "EnableDirectPlay": .bool(options.audioIndex == nil && options.subtitleIndex == -1),
            // Keep remux-only viewers eligible for HLS negotiation. PlaybackPlan
            // still rejects HTTP-only conversion returned by the server.
            "EnableDirectStream": .bool(true), "EnableTranscoding": .bool(true),
            "AllowVideoStreamCopy": .bool(true), "AllowAudioStreamCopy": .bool(true),
            "AutoOpenLiveStream": .bool(false),
            "AlwaysBurnInSubtitleWhenTranscoding": .bool(!(hardwareHEVC && options.manifestSubtitles))
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
        } else if source.supportsTranscoding == true || source.supportsDirectStream == true,
                  let reference = source.transcodingUrl,
                  source.transcodingSubProtocol.map({ $0.lowercased() == "hls" })
                    ?? (URLComponents(string: reference)?.path.lowercased().hasSuffix(".m3u8") == true) {
            method = "Transcode"
            target = try client.server.mediaURL(reference, token: session.token)
        } else { throw ClientError.unsupportedPlayback }
        return PlaybackPlan(itemID: itemID, sourceID: sourceID, sessionID: playSessionID, url: target,
            method: method, liveStreamID: source.liveStreamId, requiresClosing: source.requiresClosing == true,
            options: options)
    }

    public var conversionReasons: [String] {
        guard method != "DirectPlay" else { return [] }
        let labels = ["ContainerNotSupported": "Container is not supported", "VideoCodecNotSupported": "Video codec is not supported",
            "AudioCodecNotSupported": "Audio codec is not supported", "ContainerBitrateExceedsLimit": "Source bitrate exceeds the quality limit",
            "VideoLevelNotSupported": "Video level exceeds device support", "VideoFramerateNotSupported": "Frame rate exceeds device support",
            "SubtitleCodecNotSupported": "Subtitles need conversion", "VideoRangeTypeNotSupported": "HDR format is not supported"]
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "TranscodeReasons" }?.value ?? ""
        return raw.split(separator: ",").map(String.init).filter { $0.range(of: "^[A-Za-z]{1,80}$", options: .regularExpression) != nil }.map { labels[$0] ?? $0 }
    }

    /// Reasons that only change the container, audio or subtitle delivery.
    /// Jellyfin still copies the video for these, although it reports every
    /// HLS stream, remux or real encode, as "Transcode".
    static let remuxOnlyReasons: Set<String> = ["ContainerNotSupported", "AudioCodecNotSupported",
        "AudioChannelsNotSupported", "AudioProfileNotSupported", "AudioSampleRateNotSupported",
        "AudioBitDepthNotSupported", "AudioBitrateNotSupported", "SecondaryAudioNotSupported", "AudioIsExternal"]

    /// True when the server sends the original video and only repackages the rest.
    /// Unknown or video-related reasons, a bitrate cap and burned-in subtitles all
    /// count as a real encode, so the label never claims a copy it cannot show.
    public var copiesVideo: Bool {
        guard method == "Transcode" else { return true }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let reasons = (query.first { $0.name == "TranscodeReasons" }?.value ?? "").split(separator: ",").map(String.init)
        guard !reasons.isEmpty else { return false }
        let subtitleMethod = query.first { $0.name.caseInsensitiveCompare("SubtitleMethod") == .orderedSame }?.value?.lowercased()
        let burnsSubtitles = subtitleMethod.map { $0 == "encode" } ?? (options.subtitleIndex >= 0)
        return reasons.allSatisfy { reason in
            reason == "SubtitleCodecNotSupported" ? !burnsSubtitles : Self.remuxOnlyReasons.contains(reason)
        }
    }

    /// Ready to show in the player's playback information.
    public var deliveryDescription: String {
        switch method {
        case "DirectPlay": "Direct play"
        case "DirectStream": "Direct stream"
        case "Transcode": copiesVideo ? "Remux (original video)" : "Transcoding"
        default: "Preparing"
        }
    }

    /// The same play session after a subtitle switch inside the HLS manifest.
    public func selectingSubtitle(_ index: Int) -> PlaybackPlan {
        var next = options
        next.subtitleIndex = index
        return PlaybackPlan(itemID: itemID, sourceID: sourceID, sessionID: sessionID, url: url, method: method,
                            liveStreamID: liveStreamID, requiresClosing: requiresClosing, options: next)
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
        let body = try JSONEncoder().encode(payload)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                _ = try await requestData(path, method: "POST", body: body)
                break
            } catch ClientError.unavailable(let status) where event == "stop"
                && [502, 503, 504].contains(status) && attempt < 2 {
                // The captured client and encoded final position stay identical.
                // Authentication errors and ambiguous network timeouts propagate.
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 250 : 750))
                attempt += 1
            }
        }
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
