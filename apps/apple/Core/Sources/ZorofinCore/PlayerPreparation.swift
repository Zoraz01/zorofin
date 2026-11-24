import Foundation

/// Safe diagnostics only. Never retain AVFoundation descriptions or authenticated URLs.
public enum PlayerPreparationFailure: Error, Equatable, Sendable {
    case failed(code: Int, underlying: Int, media: [Int])
    case timedOut
    case interrupted

    var canRetryPausedHLS: Bool {
        switch self {
        case .timedOut: true
        case let .failed(code, underlying, media):
            code == -12889 || underlying == -12889 || media.contains(-12889)
        case .interrupted: false
        }
    }
}

@MainActor public protocol PlayerPreparationDriver: AnyObject {
    var isActive: Bool { get }
    var isReady: Bool { get }
    var canReload: Bool { get }
    var failure: PlayerPreparationFailure? { get }
    func load()
    func seek(to seconds: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func preroll(completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func cancelPendingOperations()
}

/// Prepare without ever playing: readiness, exact seek, then a decoded paused frame.
/// The caller publishes readiness and restores playback intent only after this returns.
@MainActor public enum PlayerPreparation {
    private final class Completion { var value: Bool? }

    /// A transcoded resume runs two server encodes back to back: AVPlayer loads
    /// the HLS stream from its first segment, then the resume seek makes the
    /// server restart ffmpeg at the saved position. A 4K source can spend more
    /// than 30 seconds on that, which surfaced as "Playback is unavailable"
    /// even though the server never failed. Direct play and fresh starts keep
    /// the shorter limit so a dead stream still fails promptly.
    nonisolated public static func timeout(method: String, isLive: Bool, startSeconds: Double) -> Duration {
        !isLive && method == "Transcode" && startSeconds.isFinite && startSeconds > 0 ? .seconds(75) : .seconds(30)
    }

    public static func run(_ driver: any PlayerPreparationDriver, startSeconds: Double,
                           primePausedFrame: Bool, recoverPausedHLS: Bool,
                           timeout: Duration = .seconds(30)) async throws {
        for attempt in 0...1 {
            try Task.checkCancellation()
            guard driver.isActive else { throw CancellationError() }
            driver.load()
            let deadline = ContinuousClock.now.advanced(by: timeout)
            do {
                try await wait(driver, until: deadline) { driver.isReady }
                if startSeconds.isFinite && startSeconds > 0 {
                    let result = Completion()
                    driver.seek(to: startSeconds) { result.value = $0 }
                    try await wait(driver, until: deadline) { result.value != nil }
                    guard result.value == true else { throw PlayerPreparationFailure.interrupted }
                }
                if primePausedFrame {
                    let result = Completion()
                    driver.preroll { result.value = $0 }
                    try await wait(driver, until: deadline) { result.value != nil }
                    guard result.value == true else { throw PlayerPreparationFailure.interrupted }
                }
                return
            } catch {
                driver.cancelPendingOperations()
                try Task.checkCancellation()
                guard driver.isActive else { throw CancellationError() }
                guard attempt == 0, recoverPausedHLS, driver.canReload,
                      (error as? PlayerPreparationFailure)?.canRetryPausedHLS == true else { throw error }
                // Recreate only the AVPlayer item on the same negotiated stream. Do
                // not change subtitles, position, bitrate, auth or server settings.
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func wait(_ driver: any PlayerPreparationDriver, until deadline: ContinuousClock.Instant,
                             condition: () -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            guard driver.isActive else { throw CancellationError() }
            if let failure = driver.failure { throw failure }
            if condition() { return }
            guard ContinuousClock.now < deadline else { throw PlayerPreparationFailure.timedOut }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

#if canImport(AVFoundation)
import AVFoundation

@MainActor public final class AVPlayerPreparationDriver: PlayerPreparationDriver {
    private let player: AVPlayer
    private let url: URL
    private let active: @MainActor () -> Bool
    private let allowsLiveResourcesWhilePaused: Bool
    private let subtitleAppearance: SubtitleAppearance?
    public private(set) var item: AVPlayerItem?

    public init(player: AVPlayer, url: URL, allowsLiveResourcesWhilePaused: Bool,
                subtitleAppearance: SubtitleAppearance? = nil,
                isActive: @escaping @MainActor () -> Bool) {
        self.player = player; self.url = url; self.active = isActive
        self.allowsLiveResourcesWhilePaused = allowsLiveResourcesWhilePaused
        self.subtitleAppearance = subtitleAppearance
    }
    public var isActive: Bool { active() && (item == nil || player.currentItem === item) }
    public var isReady: Bool { player.status == .readyToPlay && item?.status == .readyToPlay }
    // AVPlayer.Status.failed requires a new player, not just a new item.
    public var canReload: Bool { player.status != .failed }
    public var failure: PlayerPreparationFailure? {
        guard item?.status == .failed || player.status == .failed else { return nil }
        let error = (item?.error ?? player.error) as NSError?
        let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
        return .failed(code: error?.code ?? 0, underlying: underlying?.code ?? 0,
                       media: item?.errorLog()?.events.map(\.errorStatusCode) ?? [])
    }
    public func load() {
        cancelPendingOperations()
        player.pause()
        let next = AVPlayerItem(url: url)
        next.textStyleRules = subtitleAppearance?.textStyleRules()
        next.canUseNetworkResourcesForLiveStreamingWhilePaused = allowsLiveResourcesWhilePaused
        item = next
        player.replaceCurrentItem(with: next)
    }
    public func seek(to seconds: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion(finished) }
        }
    }
    public func preroll(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        // AVPlayer requires readyToPlay and rate == 0 before preroll.
        guard isReady else { completion(false); return }
        player.pause()
        player.preroll(atRate: 1) { finished in
            Task { @MainActor in completion(finished) }
        }
    }
    public func cancelPendingOperations() {
        player.cancelPendingPrerolls()
        item?.cancelPendingSeeks()
    }
}
#endif
