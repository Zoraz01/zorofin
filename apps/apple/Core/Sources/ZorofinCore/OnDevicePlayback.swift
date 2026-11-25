import Foundation

/// Files AVPlayer can't take as they are (MKV with DTS or TrueHD audio, Blu-ray
/// PGS or styled ASS subtitles) are opened on the device by the app's
/// AetherEngine player instead of being converted by the server. AVPlayer keeps
/// everything it already plays directly or through a remux.
///
/// The rule is deliberately narrow: a movie or episode file the server would
/// otherwise send through HLS, whose video the device decodes in hardware, and
/// whose only reasons to convert are the container, the audio or the subtitles.
/// Anything else (a quality cap, Live TV, an unusual video format) keeps the
/// server path the app has always used.
public enum OnDevicePlayback {
    /// Server conversion reasons the on-device player removes.
    public static let removableReasons: Set<String> = PlaybackPlan.remuxOnlyReasons.union(["SubtitleCodecNotSupported"])
    /// Subtitle formats the player draws itself.
    public static let drawnSubtitles: Set<String> = ["pgssub", "pgs", "ass", "ssa", "subrip", "srt", "webvtt", "vtt", "dvdsub", "dvbsub", "mov_text"]

    /// True when `plan` should be replaced by the on-device player.
    /// - Parameters:
    ///   - hardwareHEVC: the device decodes HEVC in hardware (`PlaybackProfile.hardwareHEVC`).
    ///   - maxBitrate: the viewer's quality limit; a source above it keeps the server's encode.
    public static func shouldUse(plan: PlaybackPlan, source: MediaSource?, isLive: Bool,
                                 hardwareHEVC: Bool, maxBitrate: Int) -> Bool {
        guard !isLive, plan.method == "Transcode", let source, source.requiresOpening != true,
              source.liveStreamId == nil, let streams = source.mediaStreams else { return false }
        if let bitrate = source.bitrate, bitrate > maxBitrate { return false }
        guard let video = streams.first(where: { $0.type == "Video" && $0.isAttachedPic != true }),
              let codec = video.codec?.lowercased() else { return false }
        switch codec {
        case "h264": break
        case "hevc", "h265": guard hardwareHEVC else { return false }
        default: return false
        }
        // Dolby Vision profile 7 (dual layer) still converts on the server.
        if video.videoRangeType?.uppercased().contains("WITHEL") == true { return false }
        if video.isInterlaced == true { return false }
        let reasons = transcodeReasons(plan.url)
        guard !reasons.isEmpty, reasons.allSatisfy(removableReasons.contains) else { return false }
        if plan.options.subtitleIndex >= 0 {
            guard let subtitle = streams.first(where: { $0.index == plan.options.subtitleIndex && $0.type == "Subtitle" }),
                  let format = subtitle.codec?.lowercased(), drawnSubtitles.contains(format) else { return false }
        }
        return true
    }

    static func transcodeReasons(_ url: URL) -> [String] {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "TranscodeReasons" }?.value ?? ""
        return value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What the on-device player opens: the original file, and the subtitle to show.
    public struct Request: Sendable, Equatable {
        public let url: URL
        /// Sent with every request; the URL carries no token.
        public let headers: [String: String]
        public let audioStreamIndex: Int?
        public let subtitle: Subtitle
        public let startSeconds: Double
    }

    public enum Subtitle: Sendable, Equatable {
        case off
        /// A track inside the file, by its stream index (Jellyfin's index is the file's).
        case embedded(Int)
        /// Keep the embedded decoder available while Jellyfin extracts this same bitmap stream.
        case embeddedPGS(Int, extractionPath: [String], language: String?)
        /// A sidecar file Jellyfin serves.
        case external(URL, language: String?)
    }

    public static func request(plan: PlaybackPlan, source: MediaSource, client: JellyfinClient) throws -> Request {
        guard let session = client.session, session.server == client.server else { throw ClientError.missingSession }
        let url = try client.server.endpoint(["Videos", plan.itemID, "stream"], query: [
            .init(name: "static", value: "true"), .init(name: "MediaSourceId", value: plan.sourceID),
            .init(name: "DeviceId", value: client.identity.deviceID), .init(name: "PlaySessionId", value: plan.sessionID)])
        let headers = ["Authorization": client.identity.authorization(token: session.token)]
        return Request(url: url, headers: headers, audioStreamIndex: plan.options.audioIndex,
                       subtitle: try subtitle(plan.options.subtitleIndex, plan: plan, source: source, server: client.server),
                       startSeconds: MediaTime.seconds(ticks: plan.options.startTicks))
    }

    /// The subtitle to show for a Jellyfin stream index (negative for none).
    public static func subtitle(_ index: Int, plan: PlaybackPlan, source: MediaSource?, server: ServerAddress) throws -> Subtitle {
        guard index >= 0, let stream = source?.mediaStreams?.first(where: { $0.index == index && $0.type == "Subtitle" }) else { return .off }
        let format = stream.codec?.lowercased() ?? "srt"
        if stream.isExternal != true {
            if format == "pgssub" || format == "pgs" {
                return .embeddedPGS(index, extractionPath: ["Videos", plan.itemID, plan.sourceID, "Subtitles",
                    String(index), "0", "Stream.pgssub"], language: stream.language)
            }
            return .embedded(index)
        }
        let ext = ["subrip": "srt", "webvtt": "vtt", "pgssub": "sup"][format] ?? format
        return .external(try server.endpoint(["Videos", plan.itemID, plan.sourceID, "Subtitles",
            String(index), "0", "Stream." + ext]), language: stream.language)
    }
}

extension JellyfinClient {
    /// A cold PGS request can wait for a whole-file subtitle extraction before receiving headers.
    /// Keep this larger budget local to subtitle transfers, with the usual server-bound redirects.
    public func preparePGSFile(path: [String]) async throws -> URL {
        let transfer = URLSessionTransport(server: server, configuration: .ephemeral,
                                           limit: 64 * 1024 * 1024, resourceTimeout: 180)
        return try await preparePGSFile(path: path, transport: transfer)
    }

    func preparePGSFile(path: [String], transport: any HTTPTransport) async throws -> URL {
        let transfer = JellyfinClient(server: server, identity: identity, session: session, transport: transport)
        let data = try await transfer.requestData(path, accept: "application/octet-stream", requestTimeout: 90)
        // The SUP header is "PG", two timestamps, segment type and its 16-bit payload size.
        guard data.count >= 13, data.starts(with: [0x50, 0x47]),
              data.count >= 13 + Int(data[11]) * 256 + Int(data[12])
        else { throw ClientError.invalidResponse }
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("sup")
        try data.write(to: url, options: .atomic)
        return url
    }
}

public extension PlaybackPlan {
    /// The same play session, reported to Jellyfin as Direct Play of the original file.
    func playedOnDevice(url: URL) -> PlaybackPlan {
        PlaybackPlan(itemID: itemID, sourceID: sourceID, sessionID: sessionID, url: url, method: "DirectPlay",
                     liveStreamID: liveStreamID, requiresClosing: requiresClosing, options: options)
    }
}
