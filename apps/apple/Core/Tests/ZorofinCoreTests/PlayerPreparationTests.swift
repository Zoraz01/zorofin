import Foundation
import Testing
@testable import ZorofinCore

@MainActor private final class PreparationStub: PlayerPreparationDriver {
    var isActive = true
    var isReady = false
    var canReload = true
    var failure: PlayerPreparationFailure?
    var automaticReadiness = true
    var automaticCompletion = true
    var seekSucceeds = true
    var failures: [PlayerPreparationFailure?] = []
    var events: [String] = []
    var positions: [Double] = []
    var pendingSeek: (@MainActor @Sendable (Bool) -> Void)?
    var pendingPreroll: (@MainActor @Sendable (Bool) -> Void)?
    func load() {
        events.append("load"); isReady = automaticReadiness
        failure = failures.isEmpty ? nil : failures.removeFirst()
    }
    func seek(to seconds: Double, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        events.append("seek"); positions.append(seconds)
        if automaticCompletion { completion(seekSucceeds) } else { pendingSeek = completion }
    }
    func preroll(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        events.append("preroll")
        if automaticCompletion { completion(true) } else { pendingPreroll = completion }
    }
    func cancelPendingOperations() { events.append("cancel") }
}

@MainActor @Suite("Playback preparation") struct PlayerPreparationTests {
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
    @Test func pausedReplacementWaitsForReadinessSeekAndPrerollInOrder() async throws {
        let driver = PreparationStub()
        driver.automaticReadiness = false; driver.automaticCompletion = false
        let task = Task { try await PlayerPreparation.run(driver, startSeconds: 15.125, primePausedFrame: true, recoverPausedHLS: true) }
        try await waitFor { driver.events == ["load"] }
        try await Task.sleep(for: .milliseconds(80))
        #expect(driver.events == ["load"])
        driver.isReady = true
        try await waitFor { driver.pendingSeek != nil }
        #expect(driver.events == ["load", "seek"])
        #expect(driver.positions == [15.125])
        driver.pendingSeek?(true)
        try await waitFor { driver.pendingPreroll != nil }
        #expect(driver.events == ["load", "seek", "preroll"])
        driver.pendingPreroll?(true)
        try await task.value
    }
    @Test func playingAndZeroStartDoNotAddUnneededOperations() async throws {
        let playing = PreparationStub()
        try await PlayerPreparation.run(playing, startSeconds: 42, primePausedFrame: false, recoverPausedHLS: false)
        #expect(playing.events == ["load", "seek"])
        let pausedAtZero = PreparationStub()
        try await PlayerPreparation.run(pausedAtZero, startSeconds: 0, primePausedFrame: true, recoverPausedHLS: false)
        #expect(pausedAtZero.events == ["load", "preroll"])
    }
    @Test func mediaTimeoutRecoversOnceWithoutChangingThePosition() async throws {
        let driver = PreparationStub()
        driver.failures = [.failed(code: -12889, underlying: 0, media: [-12889]), nil]
        try await PlayerPreparation.run(driver, startSeconds: 15.125, primePausedFrame: true, recoverPausedHLS: true)
        #expect(driver.events == ["load", "cancel", "load", "seek", "preroll"])
        #expect(driver.positions == [15.125])
    }
    @Test func persistentMediaTimeoutExhaustsExactlyOneRecovery() async {
        let driver = PreparationStub()
        let error = PlayerPreparationFailure.failed(code: -12889, underlying: 0, media: [-12889])
        driver.failures = [error, error]
        await #expect(throws: error) {
            try await PlayerPreparation.run(driver, startSeconds: 15, primePausedFrame: true, recoverPausedHLS: true)
        }
        #expect(driver.events == ["load", "cancel", "load", "cancel"])
    }
    @Test func failedPlayerDoesNotRetryAnUnusableInstance() async {
        let driver = PreparationStub(); driver.canReload = false
        let error = PlayerPreparationFailure.failed(code: -12889, underlying: 0, media: [])
        driver.failures = [error]
        await #expect(throws: error) {
            try await PlayerPreparation.run(driver, startSeconds: 15, primePausedFrame: true, recoverPausedHLS: true)
        }
        #expect(driver.events == ["load", "cancel"])
    }
    @Test func authenticationOrCodecFailuresAreNotRetried() async {
        let driver = PreparationStub()
        let error = PlayerPreparationFailure.failed(code: -11828, underlying: 0, media: [401])
        driver.failures = [error]
        await #expect(throws: error) {
            try await PlayerPreparation.run(driver, startSeconds: 15, primePausedFrame: true, recoverPausedHLS: true)
        }
        #expect(driver.events == ["load", "cancel"])
    }
    @Test func liveOrPlayingStartupDoesNotUsePausedRecovery() async {
        let driver = PreparationStub()
        let error = PlayerPreparationFailure.failed(code: -12889, underlying: 0, media: [])
        driver.failures = [error]
        await #expect(throws: error) {
            try await PlayerPreparation.run(driver, startSeconds: 0, primePausedFrame: false, recoverPausedHLS: false)
        }
        #expect(driver.events == ["load", "cancel"])
    }
    @Test func failedSeekCannotPublishReadinessOrPreroll() async {
        let driver = PreparationStub(); driver.seekSucceeds = false
        await #expect(throws: PlayerPreparationFailure.interrupted) {
            try await PlayerPreparation.run(driver, startSeconds: 15, primePausedFrame: true, recoverPausedHLS: true)
        }
        #expect(driver.events == ["load", "seek", "cancel"])
    }
    @Test func missingSeekCallbackHasABoundedDeadline() async {
        let driver = PreparationStub(); driver.automaticCompletion = false
        await #expect(throws: PlayerPreparationFailure.timedOut) {
            try await PlayerPreparation.run(driver, startSeconds: 15, primePausedFrame: true,
                                            recoverPausedHLS: false, timeout: .milliseconds(80))
        }
        #expect(driver.events == ["load", "seek", "cancel"])
    }
    @Test func closingDuringSeekCancelsPreparationAndIgnoresLateCallback() async throws {
        let driver = PreparationStub(); driver.automaticCompletion = false
        let task = Task { try await PlayerPreparation.run(driver, startSeconds: 15, primePausedFrame: true, recoverPausedHLS: true) }
        try await waitFor { driver.pendingSeek != nil }
        driver.isActive = false
        driver.pendingSeek?(true)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.events == ["load", "seek", "cancel"])
    }
    @Test func taskCancellationDuringPrerollCancelsPendingWork() async throws {
        let driver = PreparationStub(); driver.automaticCompletion = false
        let task = Task { try await PlayerPreparation.run(driver, startSeconds: 0, primePausedFrame: true, recoverPausedHLS: false) }
        try await waitFor { driver.pendingPreroll != nil }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        driver.pendingPreroll?(true)
        #expect(driver.events == ["load", "preroll", "cancel"])
    }
}

#if os(macOS)
import AVFoundation

@MainActor @Suite("Offline AVPlayer preparation") struct OfflinePlayerPreparationTests {
    @Test func pausedSeekPrerollsAndResumesSyntheticVideo() async throws {
        let url = try #require(Bundle.module.url(forResource: "player-preparation", withExtension: "mp4", subdirectory: "Fixtures"))
        let player = AVPlayer(); player.isMuted = true
        let driver = AVPlayerPreparationDriver(player: player, url: url,
            allowsLiveResourcesWhilePaused: false, isActive: { true })
        defer { driver.cancelPendingOperations(); player.pause(); player.replaceCurrentItem(with: nil) }
        try await PlayerPreparation.run(driver, startSeconds: 1.25, primePausedFrame: true, recoverPausedHLS: false)
        #expect(driver.isReady)
        #expect(player.rate == 0)
        #expect(abs(player.currentTime().seconds - 1.25) < 0.03)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        try #require(driver.item).add(output)
        player.play()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var decoded = false
        while ContinuousClock.now < deadline {
            let time = player.currentTime()
            if time.seconds > 1.4, output.hasNewPixelBuffer(forItemTime: time),
               output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                decoded = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(decoded)
    }
}
#endif
