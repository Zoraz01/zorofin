import Foundation

/// Absolute media seconds. Invalid/empty ranges never become seekable UI.
public struct PlayerTimeRange: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        self.start = start; self.end = end
    }
    public func contains(_ time: Double) -> Bool { time >= start && time <= end }
    public func clamped(_ time: Double) -> Double { min(end, max(start, time)) }
}

public enum PlayerSeek: Sendable, Equatable {
    case local(seconds: Double)
    case restart(absoluteSeconds: Double)
    case unavailable
}

/// Transcoded HLS may start at local time zero after a nonzero media resume point.
/// Keep display/report time absolute and map only at the AVFoundation boundary.
public struct PlayerTimeline: Sendable, Equatable {
    public let position: Double
    public let duration: Double?
    public let offset: Double
    public let isLive: Bool
    public let liveEdgeOffset: Double
    public let seekable: [PlayerTimeRange]
    public let buffered: [PlayerTimeRange]
    public init(localPosition: Double, duration: Double?, offset: Double = 0, isLive: Bool = false,
                seekable: [PlayerTimeRange] = [], buffered: [PlayerTimeRange] = [], liveEdgeOffset: Double = 2) {
        self.offset = offset.isFinite ? max(0, offset) : 0
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.isLive = isLive
        self.liveEdgeOffset = liveEdgeOffset.isFinite && liveEdgeOffset > 0 ? liveEdgeOffset : 2
        let rawPosition = (localPosition.isFinite ? max(0, localPosition) : 0) + self.offset
        self.position = rawPosition.isFinite ? max(0, isLive ? rawPosition : min(self.duration ?? rawPosition, rawPosition)) : 0
        self.seekable = Self.absoluteRanges(seekable, offset: self.offset, limit: isLive ? nil : self.duration)
        self.buffered = Self.absoluteRanges(buffered, offset: self.offset, limit: isLive ? nil : self.duration)
    }
    public var bounds: PlayerTimeRange? {
        if !isLive, let duration { return .init(start: 0, end: duration) }
        guard let first = seekable.first, let last = seekable.last else { return nil }
        return .init(start: first.start, end: last.end)
    }
    public var canSeek: Bool { !seekable.isEmpty }
    public var remaining: Double? { isLive ? nil : duration.map { max(0, $0 - position) } }
    /// A useful rewind window, not just a few HLS segments or a guide duration.
    public var canTimeShiftLive: Bool { isLive && seekable.reduce(0) { $0 + $1.end - $1.start } >= 30 }
    public var liveEdgeTarget: Double? {
        guard isLive, let last = seekable.last else { return nil }
        return last.end - min(liveEdgeOffset, (last.end - last.start) / 2)
    }
    public var behindLive: Double? { liveEdgeTarget.map { max(0, $0 - position) } }
    public var isAtLiveEdge: Bool {
        guard let behindLive, let last = seekable.last else { return false }
        return behindLive <= 3 && last.contains(position)
    }
    public func fraction(at time: Double) -> Double {
        guard time.isFinite, let bounds else { return 0 }
        return min(1, max(0, (time - bounds.start) / (bounds.end - bounds.start)))
    }
    public func time(at fraction: Double) -> Double? {
        guard fraction.isFinite, let bounds else { return nil }
        return bounds.start + min(1, max(0, fraction)) * (bounds.end - bounds.start)
    }
    public func seek(to absolute: Double, allowRestart: Bool = false) -> PlayerSeek {
        guard absolute.isFinite, let bounds, canSeek else { return .unavailable }
        let target = min(bounds.clamped(absolute), liveEdgeTarget ?? bounds.end)
        if seekable.contains(where: { $0.contains(target) }) { return .local(seconds: max(0, target - offset)) }
        if !isLive, allowRestart, duration != nil { return .restart(absoluteSeconds: target) }
        // Live windows move and may contain gaps. Never pretend a gap is seekable.
        guard isLive, let nearest = seekable.map({ $0.clamped(target) }).min(by: { abs($0 - target) < abs($1 - target) }) else { return .unavailable }
        return .local(seconds: max(0, nearest - offset))
    }
    private static func absoluteRanges(_ ranges: [PlayerTimeRange], offset: Double, limit: Double?) -> [PlayerTimeRange] {
        let values = ranges.compactMap { value -> PlayerTimeRange? in
            let start = value.start + offset, end = value.end + offset
            return .init(start: start, end: min(limit ?? end, end))
        }.sorted { $0.start < $1.start }
        var merged: [PlayerTimeRange] = []
        for value in values {
            if let last = merged.last, value.start <= last.end,
               let combined = PlayerTimeRange(start: last.start, end: max(last.end, value.end)) {
                merged[merged.count - 1] = combined
            } else { merged.append(value) }
        }
        return merged
    }
    public static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "--:--" }
        let whole = Int(seconds), hours = whole / 3600, minutes = (whole / 60) % 60, remainder = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, remainder) : String(format: "%d:%02d", minutes, remainder)
    }
}

public enum PlayerPhase: String, Sendable, Equatable { case preparing, playing, paused, buffering, ended, failed }
public enum PlayerPanel: String, Sendable, Equatable { case episodes, channels, tracks, quality, information, routes }
public enum PlayerBackAction: Sendable, Equatable { case closePanel, cancelScrub, unlock, hideControls, closePlayer }

/// Conservative video-background gestures; recognition never starts a seek draft.
public enum PlayerSurfaceGestureIntent: Sendable, Equatable {
    case dismiss, backward, forward

    public static func swipe(horizontal: Double, vertical: Double, width: Double, height: Double,
                             startX: Double, startY: Double) -> Self? {
        guard [horizontal, vertical, width, height, startX, startY].allSatisfy(\.isFinite),
              width > 0, height > 0 else { return nil }
        let edge = min(24, min(width, height) * 0.06)
        guard startX >= edge, startX <= width - edge, startY >= edge, startY <= height - edge else { return nil }
        let x = abs(horizontal), y = abs(vertical)
        if x >= max(40, min(width * 0.12, 88)), x > y * 1.5 {
            return horizontal < 0 ? .backward : .forward
        }
        if vertical >= max(72, min(height * 0.2, 120)), y > x * 1.5 { return .dismiss }
        return nil
    }

    public static func doubleTap(x: Double, width: Double) -> Self? {
        guard x.isFinite, width.isFinite, width > 0, x >= 0, x <= width else { return nil }
        if x < width * 0.35 { return .backward }
        if x > width * 0.65 { return .forward }
        return nil
    }
}

/// Fit preserves the complete frame; Fill enlarges it without stretching its aspect ratio.
public enum PlayerVideoSizing: String, Sendable, Equatable {
    case fit, fill

    /// A pinch chooses a mode rather than repeatedly toggling while fingers move.
    public func afterPinch(magnification: Double) -> Self {
        guard magnification.isFinite, magnification > 0 else { return self }
        if magnification >= 1.1 { return .fill }
        if magnification <= 0.9 { return .fit }
        return self
    }
}

/// Time is injected so auto-hide and interruption behavior can be tested without timers.
public struct PlayerInteraction: Sendable, Equatable {
    public private(set) var isClosed = false
    public private(set) var controlPressed = false
    public private(set) var phase: PlayerPhase = .preparing
    public private(set) var controlsVisible = true
    public private(set) var panel: PlayerPanel?
    public private(set) var locked = false
    public private(set) var scrubPosition: Double?
    public private(set) var hideDeadline: Double?
    public private(set) var panelResumeIntent = false
    public private(set) var scrubResumeIntent = false
    public private(set) var videoSizing: PlayerVideoSizing = .fit
    public var persistentControls = false
    public init() {}

    public var acceptsSurfaceGestures: Bool {
        !isClosed && !locked && panel == nil && scrubPosition == nil && !controlPressed
    }

    /// Resizing is presentation-only and cannot change transport or a pending seek.
    @discardableResult public mutating func setVideoSizing(_ sizing: PlayerVideoSizing, now: Double) -> Bool {
        guard !isClosed, !locked, panel == nil, scrubPosition == nil, sizing != videoSizing else { return false }
        videoSizing = sizing; reveal(now: now)
        return true
    }

    /// Remote Back unwinds the nearest interaction before leaving playback.
    public var backAction: PlayerBackAction {
        if isClosed { return .closePlayer }
        if panel != nil { return .closePanel }
        if scrubPosition != nil { return .cancelScrub }
        if locked { return .unlock }
        if controlsVisible && phase == .playing && !persistentControls { return .hideControls }
        return .closePlayer
    }

    public mutating func update(phase next: PlayerPhase, now: Double) {
        guard !isClosed else { return }
        let changed = phase != next
        phase = next
        if next != .playing { controlsVisible = true; hideDeadline = nil }
        else if changed { reveal(now: now) }
        if next == .ended || next == .failed { panelResumeIntent = false; scrubResumeIntent = false; scrubPosition = nil }
    }
    public mutating func reveal(now: Double) {
        guard !isClosed else { return }
        controlsVisible = true
        hideDeadline = mayAutoHide && now.isFinite ? now + 4 : nil
    }
    public mutating func toggleControls(now: Double) {
        guard !isClosed, !locked, panel == nil, scrubPosition == nil else { return }
        if controlsVisible && phase == .playing && !persistentControls { controlsVisible = false; hideDeadline = nil }
        else { reveal(now: now) }
    }
    /// Center/Select on the hidden TV surface pauses once, then exposes controls.
    /// Visible buttons, panels and scrub drafts retain their own Select actions.
    @discardableResult public mutating func pauseFromHiddenSurface(now: Double) -> Bool {
        guard !isClosed, !controlsVisible, !locked, panel == nil,
              scrubPosition == nil, phase == .playing else { return false }
        reveal(now: now)
        return true
    }
    public mutating func tick(now: Double) {
        guard mayAutoHide, let deadline = hideDeadline, now.isFinite, now >= deadline else { return }
        controlsVisible = false; hideDeadline = nil
    }
    /// Returns whether the adapter should pause. Switching panels preserves original intent.
    @discardableResult public mutating func open(_ value: PlayerPanel) -> Bool {
        guard !isClosed, !locked, scrubPosition == nil else { return false }
        if panel == nil { panelResumeIntent = phase == .playing || phase == .buffering || phase == .preparing }
        panel = value; controlsVisible = true; hideDeadline = nil
        return panelResumeIntent
    }
    /// Never resumes after backgrounding, completion, failure or selecting a replacement.
    public mutating func closePanel(now: Double, active: Bool = true, replacing: Bool = false) -> Bool {
        let resume = panel != nil && panelResumeIntent && active && !replacing && phase != .ended && phase != .failed
        panel = nil; panelResumeIntent = false; reveal(now: now)
        return resume
    }
    @discardableResult public mutating func beginScrub(at position: Double) -> Bool {
        guard !isClosed, !locked, panel == nil, position.isFinite, position >= 0,
              phase == .playing || phase == .paused || phase == .buffering else { return false }
        if scrubPosition == nil { scrubResumeIntent = phase != .paused }
        scrubPosition = position; controlsVisible = true; hideDeadline = nil
        return true
    }
    public mutating func moveScrub(to position: Double) {
        guard scrubPosition != nil, position.isFinite, position >= 0 else { return }
        scrubPosition = position
    }
    /// TV Select/Play explicitly resumes; touch scrubbing preserves its original intent.
    public mutating func finishScrub(now: Double, active: Bool = true, play: Bool = false) -> (position: Double, resume: Bool)? {
        guard let position = scrubPosition else { return nil }
        let resume = (play || scrubResumeIntent) && active && phase != .ended && phase != .failed
        scrubPosition = nil; scrubResumeIntent = false; reveal(now: now)
        return (position, resume)
    }
    /// Only a focused timeline may consume horizontal input. Merely navigating
    /// between transport/options buttons cannot pause playback or draft a seek.
    @discardableResult public mutating func previewRemoteSeek(by seconds: Double, timeline: PlayerTimeline,
                                                              timelineFocused: Bool) -> Bool {
        guard timelineFocused, seconds.isFinite, seconds != 0, timeline.canSeek,
              !timeline.isLive || timeline.canTimeShiftLive, let bounds = timeline.bounds else { return false }
        let target = min(bounds.clamped((scrubPosition ?? timeline.position) + seconds), timeline.liveEdgeTarget ?? bounds.end)
        return beginScrub(at: target)
    }
    /// Remote Back or moving focus away discards the draft, never commits a seek.
    public mutating func cancelScrub(now: Double, active: Bool = true) -> Bool {
        guard scrubPosition != nil else { return false }
        let resume = scrubResumeIntent && active && phase != .ended && phase != .failed
        scrubPosition = nil; scrubResumeIntent = false; reveal(now: now)
        return resume
    }
    public mutating func setLocked(_ value: Bool, now: Double) {
        guard !isClosed, panel == nil, scrubPosition == nil else { return }
        locked = value; controlsVisible = !value
        hideDeadline = nil
        if !value { reveal(now: now) }
    }
    public mutating func interrupt(now: Double) {
        controlPressed = false
        panelResumeIntent = false; scrubResumeIntent = false; scrubPosition = nil
        update(phase: .paused, now: now)
    }
    /// A touch that starts just before the deadline must still finish on its button.
    public mutating func setControlPressed(_ pressed: Bool, now: Double) {
        guard !isClosed else { return }
        controlPressed = pressed
        reveal(now: now)
    }
    /// Terminal state: late timer, panel-dismiss and preparation callbacks cannot resume.
    public mutating func close() {
        isClosed = true; phase = .paused; controlsVisible = false; hideDeadline = nil
        panel = nil; panelResumeIntent = false; scrubPosition = nil; scrubResumeIntent = false
        controlPressed = false; locked = false
    }
    private var mayAutoHide: Bool { !isClosed && !controlPressed && phase == .playing && panel == nil && scrubPosition == nil && !locked && !persistentControls }
}

public enum PlayerSettingChange: Sendable {
    case audio(Int?), subtitles(Int), bitrate(Int)
}

public extension PlaybackOptions {
    /// Validate selections against this title before restarting its stream.
    /// Live changes reconnect at the live edge after the old stream is released.
    func changing(_ change: PlayerSettingChange, item: MediaItem, position: Double) throws -> PlaybackOptions {
        guard position.isFinite, position >= 0 else { throw SettingsError.invalidInput }
        let streams = item.mediaSources?.first?.mediaStreams ?? []
        var result = self
        switch change {
        case .audio(let index):
            guard index == nil || streams.contains(where: { $0.type == "Audio" && $0.index == index }) else { throw SettingsError.invalidInput }
            result.audioIndex = index
        case .subtitles(let index):
            guard index == -2 || index == -1 || streams.contains(where: { $0.type == "Subtitle" && $0.index == index }) else { throw SettingsError.invalidInput }
            result.subtitleIndex = index
        case .bitrate(let value):
            guard [2,4,8,12,20,40].map({ $0 * 1_000_000 }).contains(value) else { throw SettingsError.invalidInput }
            result.bitrate = value
        }
        let duration = item.runTimeTicks.map(MediaTime.seconds)
        result.startTicks = item.isLive ? 0 : MediaTime.ticks(seconds: min(duration ?? position, position))
        return result
    }
}

/// Coalesce rapid seeks without losing play intent when AVPlayer pauses to seek.
/// Old asynchronous completions cannot clear a newer request.
public struct PlayerPendingSeek: Sendable, Equatable {
    public struct Request: Sendable, Equatable {
        public let id: UUID
        public let position: Double
        public let resume: Bool
    }
    public private(set) var current: Request?
    public init() {}
    @discardableResult public mutating func begin(position: Double, resume: Bool) -> Request? {
        guard position.isFinite, position >= 0 else { return nil }
        let request = Request(id: UUID(), position: position, resume: resume)
        current = request; return request
    }
    public mutating func finish(_ id: UUID) {
        if current?.id == id { current = nil }
    }
    public mutating func cancel() { current = nil }
}
