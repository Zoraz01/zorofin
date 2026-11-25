import Foundation

// Trailer previews on Apple TV Home (handoff: docs/handoffs/TRAILER_PREVIEWS_APPS_HANDOFF.md).
// Rest on a movie or show in an eligible Home row and its local trailer plays muted
// inside the widened card. Standard Jellyfin local-trailer extras only; previews
// never report playback, touch resume points, SyncPlay or Continue Watching.

public enum TrailerPreviewTiming {
    /// Unchanged focus before a preview starts (try 1.5 and 2.5 on devices).
    public static let previewDwell: TimeInterval = 2.0
    /// When the trailer lookup runs after focus settles.
    public static let trailerLookupAt: TimeInterval = 0.6
    /// Give up and keep artwork if no frame by then.
    public static let firstFrameTimeout: TimeInterval = 3.0
    /// Seconds of actual playback before the preview returns to artwork.
    public static let previewCap: TimeInterval = 30
    public static let fadeIn: TimeInterval = 0.2
}

/// A direct-play trailer stream. The URL carries the viewer's token for AVPlayer
/// only; never log or share it.
public struct TrailerSource: Sendable, Equatable {
    public var trailerID: String
    public var url: URL
    public var subtitleURL: URL?
}

public enum TrailerPreview {
    /// Movies and shows only.
    public static func eligible(_ item: MediaItem) -> Bool {
        (item.type == "Movie" || item.type == "Series") && item.localTrailerCount != 0
    }

    /// Direct play only: mp4/mov, H.264 (HEVC when allowed), ≤1080p, AAC/AC-3/E-AC-3. Never transcode for a preview.
    public static func compatible(_ source: MediaSource, allowHEVC: Bool = true) -> Bool {
        let containers = (source.container ?? "").lowercased().split(separator: ",").map(String.init)
        guard containers.contains(where: { ["mp4", "mov", "m4v"].contains($0) }) else { return false }
        let streams = source.mediaStreams ?? []
        guard let video = streams.first(where: { $0.type == "Video" }),
              let codec = video.codec?.lowercased(),
              codec == "h264" || (allowHEVC && (codec == "hevc" || codec == "h265")),
              (video.height ?? 0) <= 1080 else { return false }
        let audio = streams.filter { $0.type == "Audio" }
        return audio.isEmpty || audio.contains { ["aac", "ac3", "eac3"].contains(($0.codec ?? "").lowercased()) }
    }
}

public extension JellyfinClient {
    /// The first playable local trailer, or nil (none, incompatible, or a transcode would be needed).
    func previewTrailer(for item: MediaItem, allowHEVC: Bool = true) async throws -> TrailerSource? {
        guard TrailerPreview.eligible(item), let session else { return nil }
        let trailers = try await request([MediaItem].self, path: ["Items", item.id, "LocalTrailers"],
                                         query: [URLQueryItem(name: "userId", value: session.viewer.id)])
        guard var trailer = trailers.first else { return nil }
        if trailer.mediaSources?.first == nil {
            trailer = try await request(MediaItem.self, path: ["Items", trailer.id], query: [
                URLQueryItem(name: "userId", value: session.viewer.id), URLQueryItem(name: "fields", value: "MediaSources")])
        }
        guard let source = trailer.mediaSources?.first, TrailerPreview.compatible(source, allowHEVC: allowHEVC) else { return nil }
        let sourceID = source.id ?? trailer.id
        let encodedID = trailer.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trailer.id
        let encodedSource = sourceID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? sourceID
        let url = try server.mediaURL("Videos/\(encodedID)/stream.mp4?static=true&mediaSourceId=\(encodedSource)", token: session.token)
        var subtitle: URL?
        if let text = (source.mediaStreams ?? []).first(where: {
            $0.type == "Subtitle" && ["srt", "subrip", "vtt", "webvtt"].contains(($0.codec ?? "").lowercased())
        }) {
            subtitle = try? server.mediaURL("Videos/\(encodedID)/\(encodedSource)/Subtitles/\(text.index)/0/Stream.vtt", token: session.token)
        }
        return TrailerSource(trailerID: trailer.id, url: url, subtitleURL: subtitle)
    }
}

/// The preview rules as a pure state machine. The view feeds it focus, clock
/// ticks, lookup answers and player events, and performs the commands it returns.
public struct PreviewCoordinator: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Card widened, waiting for the dwell.
        case waiting
        /// The player was asked to start; artwork stays until the first frame.
        case starting(since: Date)
        case playing
        case paused
        /// Finished, failed, held or autoplay off: artwork until Play/Pause.
        case resting
    }
    public enum Command: Sendable, Equatable {
        case lookup(itemID: String)
        case start(TrailerSource)
        case pause, resume, stop
    }
    /// Remote hints under the synopsis.
    public enum Hints: Sendable, Equatable {
        case details, playing, paused, replay, playPreview
    }

    public private(set) var itemID: String?
    public private(set) var phase: Phase = .idle
    public private(set) var muted = true
    private var focusedAt = Date.distantPast
    private var lookupRequested = false
    /// Answers for this Home visit; `nil` value means no playable trailer.
    private var answers: [String: TrailerSource?] = [:]
    /// Titles paused or finished during this Home visit stay on artwork.
    private var held: Set<String> = []
    public var autoplay: Bool

    public init(autoplay: Bool = true) { self.autoplay = autoplay }

    public var source: TrailerSource? { itemID.flatMap { answers[$0] ?? nil } }
    public var showsVideo: Bool { phase == .playing || phase == .paused }

    public var hints: Hints {
        guard let itemID else { return .details }
        let known = answers[itemID]
        if case .some(.none) = known { return .details }
        switch phase {
        case .playing: return .playing
        case .paused: return .paused
        case .resting: return held.contains(itemID) ? .replay : autoplay ? (known == nil ? .details : .replay) : .playPreview
        case .idle, .waiting, .starting: return .details
        }
    }

    /// Focus lands on an eligible title (or moves away with nil). Stops any preview at once.
    public mutating func focus(_ item: MediaItem?, at now: Date) -> [Command] {
        let stopping = phase != .idle && phase != .waiting && phase != .resting
        guard item?.id != itemID || phase == .idle else { return [] }
        itemID = nil; phase = .idle; muted = true; lookupRequested = false
        let commands: [Command] = stopping ? [.stop] : []
        guard let item, TrailerPreview.eligible(item) else {
            if let item, item.localTrailerCount == 0 { answers[item.id] = .some(nil) }
            return commands
        }
        itemID = item.id; focusedAt = now
        phase = held.contains(item.id) || !autoplay ? .resting : .waiting
        return commands
    }

    /// A key press or scroll on the same title restarts the dwell.
    public mutating func interaction(at now: Date) {
        if phase == .waiting { focusedAt = now }
    }

    /// Clock tick: the lookup at 0.6 s, the start at 2.0 s, the first-frame timeout.
    public mutating func tick(at now: Date) -> [Command] {
        guard let itemID else { return [] }
        let elapsed = now.timeIntervalSince(focusedAt)
        switch phase {
        case .waiting:
            if answers[itemID] == nil {
                if elapsed >= TrailerPreviewTiming.trailerLookupAt && !lookupRequested {
                    lookupRequested = true; return [.lookup(itemID: itemID)]
                }
                return []
            }
            guard elapsed >= TrailerPreviewTiming.previewDwell else { return [] }
            guard let source = answers[itemID] ?? nil else { phase = .resting; return [] }
            phase = .starting(since: now)
            return [.start(source)]
        case .starting(let since):
            if now.timeIntervalSince(since) >= TrailerPreviewTiming.firstFrameTimeout {
                phase = .resting; answers[itemID] = .some(nil)
                return [.stop]
            }
            return []
        default:
            return []
        }
    }

    /// The lookup answered. Stale answers (another title) are only cached.
    public mutating func lookedUp(_ itemID: String, source: TrailerSource?, at now: Date) -> [Command] {
        answers[itemID] = .some(source)
        guard itemID == self.itemID else { return [] }
        if source == nil, phase == .waiting { phase = .resting; return [] }
        return tick(at: now)
    }

    /// The first frame rendered: fade the video in.
    public mutating func firstFrame() {
        if case .starting = phase { phase = .playing }
    }

    /// Played time (buffering and pause excluded) or the end of the file.
    public mutating func progress(played seconds: TimeInterval, ended: Bool = false) -> [Command] {
        guard showsVideo, let itemID, ended || seconds >= TrailerPreviewTiming.previewCap else { return [] }
        held.insert(itemID); phase = .resting; muted = true
        return [.stop]
    }

    /// The incompatible file or network failed: keep artwork, no retry loop.
    public mutating func failed() -> [Command] {
        guard let itemID, phase != .idle else { return [] }
        answers[itemID] = .some(nil); phase = .resting
        return [.stop]
    }

    /// Play/Pause never starts the movie: it pauses, resumes or (re)starts the preview.
    public mutating func playPause(at now: Date) -> [Command] {
        guard let itemID else { return [] }
        switch phase {
        case .playing:
            held.insert(itemID); phase = .paused; return [.pause]
        case .paused:
            phase = .playing; return [.resume]
        case .starting:
            return []
        case .waiting, .resting, .idle:
            guard let answer = answers[itemID] else {
                // Not looked up yet: look up now and start as soon as it answers.
                phase = .waiting; focusedAt = now.addingTimeInterval(-TrailerPreviewTiming.previewDwell)
                lookupRequested = true
                return [.lookup(itemID: itemID)]
            }
            guard let source = answer else { return [] }
            muted = true; phase = .starting(since: now)
            return [.stop, .start(source)]
        }
    }

    /// Sound lasts only for the current preview.
    public mutating func toggleSound() -> Bool {
        guard showsVideo else { return muted }
        muted.toggle(); return muted
    }

    /// Home lost the viewer (details, another tab, background, a dialog, a player,
    /// a profile or server change). Held titles reset with the visit when `endVisit`.
    public mutating func stopAll(endVisit: Bool) -> [Command] {
        let active = phase != .idle && phase != .waiting && phase != .resting
        itemID = nil; phase = .idle; muted = true; lookupRequested = false
        if endVisit { held = []; answers = [:] }
        return active ? [.stop] : []
    }
}
