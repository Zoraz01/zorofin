import Foundation

/// Source-file facts, never a promise about the negotiated playback output.
/// Keep each version separate: combining versions can invent a 4K Dolby Vision file.
public struct MediaQuality: Hashable, Sendable {
    public let container: String?
    public let video: MediaStream?
    public let audio: MediaStream?
    public let size: Int64?
    public let bitrate: Int?

    init(source: MediaSource?, streams: [MediaStream], container: String?, audioIndex: Int? = nil) {
        self.container = Self.clean(source?.container ?? container)?.uppercased()
        video = streams.first { $0.type == "Video" && $0.isAttachedPic != true }
        let audioTracks = streams.filter { $0.type == "Audio" }
        audio = audioTracks.first { $0.index == (audioIndex ?? source?.defaultAudioStreamIndex) }
            ?? audioTracks.first { $0.isDefault == true } ?? audioTracks.first
        size = source?.size.flatMap { $0 > 0 ? $0 : nil }
        bitrate = source?.bitrate.flatMap { $0 > 0 ? $0 : nil }
    }
    public var resolution: String? {
        guard let video else { return nil }
        let width = video.width ?? 0, height = video.height ?? 0
        guard width > 0 || height > 0 else { return nil }
        // Width also recognizes cinematic crops, e.g. 3840 × 1600.
        if width >= 7680 || height >= 4320 { return "8K" }
        if width >= 3840 || height >= 2160 { return "4K" }
        if width >= 1920 || height >= 1080 { return video.isInterlaced == true ? "1080i" : "1080p" }
        if width >= 1280 || height >= 720 { return "720p" }
        return "SD"
    }
    public var dynamicRange: String? {
        let range = video?.videoRangeType?.uppercased() ?? ""
        switch range {
        case "DOVI", "DOVIWITHHDR10", "DOVIWITHHLG", "DOVIWITHSDR", "DOVIWITHEL",
             "DOVIWITHHDR10PLUS", "DOVIWITHELHDR10PLUS": return "Dolby Vision"
        case "HDR10PLUS": return "HDR10+"
        case "HDR10": return "HDR10"
        case "HLG": return "HLG"
        case "SDR": return "SDR"
        default:
            // Unknown and DOVIInvalid must never produce a Dolby Vision badge.
            switch video?.videoRange?.uppercased() {
            case "HDR": return "HDR"
            case "SDR": return "SDR"
            default: return nil
            }
        }
    }
    public var spatialAudio: String? {
        switch audio?.audioSpatialFormat?.uppercased() {
        case "DOLBYATMOS": return "Dolby Atmos"
        case "DTSX": return "DTS:X"
        case nil, "", "NONE":
            // Older Jellyfin versions expose this in Profile. EAC3/TrueHD alone
            // do not establish Atmos, nor does DTS alone establish DTS:X.
            let profile = audio?.profile?.uppercased() ?? ""
            if profile.contains("DOLBY ATMOS") { return "Dolby Atmos" }
            if profile.contains("DTS:X") { return "DTS:X" }
            return nil
        default: return nil
        }
    }
    public var audioLayout: String? {
        if let layout = Self.clean(audio?.channelLayout) { return layout }
        guard let channels = audio?.channels, channels > 0 else { return nil }
        return channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels"
    }
    public var thumbnailBadges: [String] {
        [resolution, dynamicRange == "SDR" ? nil : dynamicRange == "Dolby Vision" ? "DV" : dynamicRange].compactMap { $0 }
    }
    public var badges: [String] {
        [resolution, dynamicRange, container, Self.codec(video?.codec), spatialAudio,
         Self.codec(audio?.codec), audioLayout].compactMap { $0 }
    }
    public struct Fact: Identifiable, Sendable {
        public let title: String
        public let value: String
        public var id: String { title }
    }
    public var facts: [Fact] {
        var result: [Fact] = []
        func add(_ title: String, _ value: String?) {
            if let value { result.append(Fact(title: title, value: value)) }
        }
        add("File format", container)
        if let size { add("File size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let bitrate { add("File bitrate", String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
        if let w = video?.width, let h = video?.height, w > 0, h > 0 { add("Resolution", "\(w) × \(h)") }
        else { add("Resolution", resolution) }
        add("Video codec", Self.codec(video?.codec))
        add("Dynamic range", dynamicRange)
        if let depth = video?.bitDepth, depth > 0 { add("Bit depth", "\(depth)-bit") }
        if let rate = video?.averageFrameRate, rate.isFinite, rate > 0 { add("Frame rate", rate.formatted(.number.precision(.fractionLength(0...3))) + " fps") }
        add("Audio codec", Self.codec(audio?.codec))
        add("Spatial audio", spatialAudio)
        add("Audio channels", audioLayout)
        return result
    }
    private static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(48))
    }
    private static func codec(_ value: String?) -> String? {
        guard let value = clean(value) else { return nil }
        switch value.lowercased() {
        case "h264", "avc": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "eac3": return "Dolby Digital Plus"
        case "ac3": return "Dolby Digital"
        case "truehd": return "TrueHD"
        default: return value.uppercased()
        }
    }
}

extension MediaItem {
    public func quality(audioIndex: Int? = nil) -> MediaQuality {
        let source = mediaSources?.first
        // A series/season does not have one uniform file format.
        let streams = isSeries || type == "Season" ? [] : source?.mediaStreams ?? mediaStreams ?? []
        return MediaQuality(source: isSeries || type == "Season" ? nil : source,
                            streams: streams, container: isSeries || type == "Season" ? nil : container, audioIndex: audioIndex)
    }
    public var fileQualities: [MediaQuality] {
        guard !isSeries && type != "Season" else { return [] }
        guard let sources = mediaSources, !sources.isEmpty else { return [quality()] }
        return sources.enumerated().map { index, source in
            MediaQuality(source: source, streams: source.mediaStreams ?? (index == 0 ? mediaStreams ?? [] : []), container: nil)
        }
    }
    /// Preserve the first version's safe, typed quality metadata on disk, while
    /// removing playback URLs, opening tokens and unknown source fields.
    mutating func removePlaybackSources() {
        if let source = mediaSources?.first {
            mediaStreams = source.mediaStreams ?? mediaStreams
            container = source.container ?? container
        }
        mediaSources = nil
    }
}
