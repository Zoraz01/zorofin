import SwiftUI
import AVKit
import Combine
import ZorofinCore

struct PlaybackPresentation: Identifiable {
    let id = UUID()
    let item: MediaItem
    let options: PlaybackOptions
}

@MainActor @Observable final class PlaybackController {
    /// The app's own AVPlayer, or the on-device player's once it opened the file.
    private(set) var player: AVPlayer = {
        let player = AVPlayer()
        #if DEBUG
        // UI tests on the Mac play silently.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-muted") { player.isMuted = true }
        #endif
        return player
    }()
    @ObservationIgnored weak var watchTogether: WatchTogetherModel?
    /// Set while the original file plays on the device (`OnDevicePlayback`).
    private(set) var onDevice: OnDevicePlayer?
    @ObservationIgnored private var engineSubscriptions: [AnyCancellable] = []
    @ObservationIgnored private var client: JellyfinClient?
    /// Playback problems go to the viewer's server only while it collects
    /// them and the viewer left reporting on; the caller decides both.
    @ObservationIgnored private var problemReports = false
    @ObservationIgnored private var problemItem: MediaItem?
    static var problemPlatform: String {
        #if os(tvOS)
        return "Apple TV"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
    func reportProblem(_ kind: PlaybackProblem, reason: String = "", startMs: Int? = nil) {
        guard problemReports, let client, let item = problemItem else { return }
        let report = PlaybackProblemReport(kind: kind, item: item, platform: Self.problemPlatform, identity: client.identity,
            method: PlaybackProblemReport.method(plan?.method, isLive: live, onDevice: onDevice != nil), reason: reason,
            startMs: startMs, positionSeconds: live || !ready ? nil : Int(currentSeconds.isFinite ? currentSeconds : 0))
        Task { await PlaybackProblemLog.shared.send(report, client: client) }
    }
    private(set) var syncItemID: String?
    /// Positive: subtitles appear later. The on-device player's overlay reads
    /// it directly; for AVPlayer's own text subtitles `shiftedSubtitles` takes
    /// over the drawing while it is not zero.
    var subtitleOffset: Double = 0 { didSet { applySubtitleShift() } }
    @ObservationIgnored let shiftedSubtitles = ShiftedSubtitles()
    private func applySubtitleShift() {
        shiftedSubtitles.apply(offset: ready && !stopped && onDevice == nil && !live ? subtitleOffset : 0, to: player.currentItem)
    }
    /// Positive: sound plays later. Only the on-device player can move it.
    private(set) var audioOffset: Double = 0
    @ObservationIgnored private var audioOffsetTask: Task<Void, Never>?
    /// Each change re-anchors playback, so wait until the viewer stops stepping.
    func setAudioOffset(_ seconds: Double, immediately: Bool = false) {
        audioOffset = seconds
        audioOffsetTask?.cancel()
        if immediately { onDevice?.setAudioDelay(seconds); return }
        audioOffsetTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !self.stopped else { return }
            self.onDevice?.setAudioDelay(self.audioOffset)
        }
    }
    private var groupFeedbackSuppressedUntil = Date.distantPast
    private var soloPlaybackRate: Float = 1
    private var bufferingTask: Task<Void, Never>?
    private(set) var groupPlaybackSuspended = false
    var syncPositionTicks: Int64 { position }
    var loading = true
    var error: String?
    var finished = false
    var inPictureInPicture = false
    var pausedForEpisodeBrowser = false
    var startsPaused = false
    var customControls = false
    var keepsLiveWindowFresh = true
    var timeline = PlayerTimeline(localPosition: 0, duration: nil)
    var phase: PlayerPhase = .preparing
    private var uiObserver: Any?
    private var mediaDuration: Double?
    private(set) var resolvedSource: MediaSource?
    private var live = false
    var resolvedOptions: PlaybackOptions? { plan?.options }
    var playbackMethod: String? { plan?.method }
    var conversionReasons: [String] { plan?.conversionReasons ?? [] }
    var deliveryDescription: String {
        onDevice != nil ? "Original file, played on this device" : plan?.deliveryDescription ?? "Preparing"
    }
    /// Set when this stream was negotiated with a text subtitle, so its HLS
    /// manifest carries every text track and switching needs no new stream.
    private var manifestCarriesSubtitles = false
    private var reporter: PlaybackReporter?
    private var plan: PlaybackPlan?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stopped = false
    private var stopTask: Task<Void, Never>?
    private var ready = false
    private(set) var isPreparing = false
    private var unreleasedStream: (JellyfinClient, String)?

    func prepare(client: JellyfinClient, presentation: PlaybackPresentation, preferences: NativePreferences, liveTVCapacityEnabled: Bool = false,
                 problemReports: Bool = false) async {
        guard !stopped else { return }
        self.problemReports = problemReports; problemItem = presentation.item
        let began = ContinuousClock.now
        isPreparing = true
        defer { isPreparing = false }
        var options = presentation.options
        syncItemID = presentation.item.id
        if presentation.item.isLive { options.startTicks = 0 }
        // Text subtitles ride in the HLS manifest for movies and episodes, so
        // choosing one remuxes instead of re-encoding the video.
        else { options.manifestSubtitles = true }
        var ownedStream: String?
        mediaDuration = presentation.item.runTimeTicks.map(MediaTime.seconds)
        live = presentation.item.isLive
        self.client = client
        do {
            #if os(tvOS)
            if live { try await client.checkLiveTVCapacity(channelID: presentation.item.id, enabled: liveTVCapacityEnabled) }
            try ensureActive()
            #endif
            let info = try await client.playbackInfo(for: presentation.item, options: options)
            try ensureActive()
            var source = info.mediaSources?.first
            if let initial = source, initial.requiresOpening == true {
                source = try await client.openLive(source: initial, info: info, itemID: presentation.item.id, options: options)
                if source?.requiresClosing == true { ownedStream = source?.liveStreamId }
            }
            try ensureActive()
            let serverPlan = try PlaybackPlan.make(info: info, source: source, itemID: presentation.item.id, client: client, options: options)
            var plan = serverPlan
            // MKV with DTS/TrueHD, PGS or styled subtitles: open the original
            // file on the device instead of having the server convert it.
            var onDeviceRequest: OnDevicePlayback.Request?
            if let source, OnDevicePlayer.shared != nil,
               OnDevicePlayback.shouldUse(plan: plan, source: source, isLive: live,
                   hardwareHEVC: PlaybackProfile.hardwareHEVC, maxBitrate: options.bitrate),
               let request = try? OnDevicePlayback.request(plan: plan, source: source, client: client) {
                onDeviceRequest = request
                plan = plan.playedOnDevice(url: request.url)
            }
            self.plan = plan
            resolvedSource = source
            manifestCarriesSubtitles = !live && plan.method == "Transcode" && options.manifestSubtitles && options.subtitleIndex >= 0
            reporter = PlaybackReporter(client: client, plan: plan)
            ownedStream = nil // The reporter now owns final cleanup, even if setup fails.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let startSeconds = live ? 0 : MediaTime.seconds(ticks: options.startTicks)
            if let onDeviceRequest, let device = OnDevicePlayer.shared {
                do {
                    player = try await device.load(onDeviceRequest, client: client, owner: self)
                    onDevice = device
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The engine couldn't open it: use the server's stream instead.
                    // Nothing was reported yet, so the session simply changes plan.
                    device.stop(owner: self)
                    self.plan = serverPlan
                    plan = serverPlan
                    reporter = PlaybackReporter(client: client, plan: serverPlan)
                    manifestCarriesSubtitles = !live && serverPlan.method == "Transcode" && options.manifestSubtitles && options.subtitleIndex >= 0
                }
                try ensureActive()
            }
            let item: AVPlayerItem
            if onDevice == nil {
                let preparation = AVPlayerPreparationDriver(player: player, url: plan.url,
                    allowsLiveResourcesWhilePaused: live && customControls && keepsLiveWindowFresh,
                    subtitleAppearance: preferences.subtitleAppearance, startSeconds: startSeconds,
                    isActive: { [weak self] in self?.stopped == false })
                try await PlayerPreparation.run(preparation,
                    startSeconds: startSeconds,
                    primePausedFrame: !live && startsPaused,
                    recoverPausedHLS: !live && startsPaused && options.startTicks > 0 && plan.method == "Transcode",
                    timeout: PlayerPreparation.timeout(method: plan.method, isLive: live, startSeconds: startSeconds))
                try ensureActive()
                guard let prepared = preparation.item else { throw ClientError.unsupportedPlayback }
                if !live, plan.method != "DirectPlay" { await ManifestSubtitles.applyServerSelection(to: prepared) }
                item = prepared
            } else {
                guard let current = player.currentItem else { throw ClientError.unsupportedPlayback }
                item = current
            }
            // Item readiness alone does not mean the resume seek/preroll is done.
            ready = true; loading = false
            applySubtitleShift()
            let took = PlaybackProblemReport.milliseconds(began.duration(to: .now))
            if took >= 10_000 { reportProblem(.slowStart, startMs: took) }
            if let onDevice {
                observeEngine(onDevice)
            } else {
                itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped else { return }
                        if status == .failed {
                            #if DEBUG
                            // Numeric diagnostics only: AVFoundation error descriptions and
                            // log URIs can contain authenticated media URLs.
                            let failure = item.error as NSError?
                            let underlying = failure?.userInfo[NSUnderlyingErrorKey] as? NSError
                            let mediaCodes = item.errorLog()?.events.map(\.errorStatusCode) ?? []
                            print("ZorofinPlayerDiagnostic failure=\(failure?.code ?? 0) underlying=\(underlying?.code ?? 0) media=\(mediaCodes)")
                            #endif
                            // Numeric codes only, as above: descriptions can carry media URLs.
                            let stopError = item.error as NSError?
                            self.reportProblem(.stopped, reason: "Playback could not continue (AVFoundation \(stopError?.domain ?? "") \(stopError?.code ?? 0))")
                            self.error = "Playback could not continue. Try again or choose a lower quality."
                            self.loading = false
                            await self.stop(failed: true)
                        }
                        self.refreshPresentation()
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in await self?.playedToEnd() }
                }
            }
            attachPlayerObservers()
            try ensureActive()
            soloPlaybackRate = live ? 1 : Float(preferences.playbackSpeed)
            player.defaultRate = watchTogether?.isJoined == true ? 1 : soloPlaybackRate
            if watchTogether?.isJoined == true {
                await watchTogether?.playerReady(self, itemID: presentation.item.id)
            } else if !pausedForEpisodeBrowser && !startsPaused { resume() }
            refreshPresentation()
        } catch {
            #if DEBUG
            if case let PlayerPreparationFailure.failed(code, underlying, media) = error {
                print("ZorofinPlayerDiagnostic failure=\(code) underlying=\(underlying) media=\(media)")
            } else if case PlayerPreparationFailure.timedOut = error {
                print("ZorofinPlayerDiagnostic preparation=timedOut")
            } else if case PlayerPreparationFailure.interrupted = error {
                print("ZorofinPlayerDiagnostic preparation=interrupted")
            }
            #endif
            if let ownedStream {
                do { try await client.closeLive(ownedStream) }
                catch { unreleasedStream = (client, ownedStream) }
            }
            if !(error is CancellationError) {
                let why: String
                if case let PlayerPreparationFailure.failed(code, underlying, _) = error { why = "The player failed to open the stream (\(code), \(underlying))" }
                else if case PlayerPreparationFailure.timedOut = error { why = "The stream did not open in time" }
                else if case PlayerPreparationFailure.interrupted = error { why = "Opening the stream was interrupted" }
                else { why = (error as? ClientError)?.localizedDescription ?? (error as? LiveTVCapacityError)?.localizedDescription ?? "Playback is unavailable" }
                reportProblem(.startFailed, reason: why, startMs: PlaybackProblemReport.milliseconds(began.duration(to: .now)))
            }
            await stop(failed: !(error is CancellationError))
            loading = false
            if !(error is CancellationError) { self.error = (error as? LiveTVCapacityError)?.localizedDescription ?? (error as? ClientError)?.localizedDescription ?? "Playback is unavailable. Please try again." }
            refreshPresentation()
        }
    }
    /// Time observers live on the AVPlayer, which the on-device player can swap.
    private func attachPlayerObservers() {
        observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in await self?.stateChanged(status) }
        }
        if customControls && !live {
            uiObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshPresentation() }
            }
        }
        periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.progress() }
        }
    }
    private func detachPlayerObservers() {
        if let periodicObserver { player.removeTimeObserver(periodicObserver); self.periodicObserver = nil }
        if let uiObserver { player.removeTimeObserver(uiObserver); self.uiObserver = nil }
        observation?.invalidate(); observation = nil
    }
    /// The engine reports the end, a failure, and a new AVPlayer after it
    /// rebuilds a session; the original file has no AVPlayerItem of our own.
    private func observeEngine(_ device: OnDevicePlayer) {
        engineSubscriptions = device.observe(ended: { [weak self] in
            guard let self, !self.stopped, self.onDevice != nil else { return }
            Task { await self.playedToEnd() }
        }, failed: { [weak self] in
            guard let self, !self.stopped, self.onDevice != nil else { return }
            self.error = "Playback could not continue. Try again or choose a lower quality."
            self.loading = false
            Task { await self.stop(failed: true); self.refreshPresentation() }
        }, changed: { [weak self] in
            guard let self, !self.stopped else { return }
            self.refreshPresentation()
        }, playerReplaced: { [weak self] next in
            guard let self, !self.stopped, self.onDevice != nil, next !== self.player else { return }
            self.detachPlayerObservers()
            next.defaultRate = self.player.defaultRate
            self.player = next
            self.attachPlayerObservers()
        })
    }
    private func playedToEnd() async {
        let grouped = watchTogether?.isJoined == true
        if grouped { await watchTogether?.nextItem() }
        await stop(keepingGroupPlayback: grouped); finished = true
    }
    private func resume() {
        if let onDevice { onDevice.play() } else { player.play() }
    }
    private func pausePlayback() {
        if let onDevice { onDevice.pause() } else { player.pause() }
    }
    /// The playback position in the file's seconds, on either route.
    private var currentSeconds: Double { onDevice?.position ?? player.currentTime().seconds }
    private func seekPlayer(to seconds: Double) async -> Bool {
        if let onDevice { await onDevice.seek(to: seconds); return true }
        return await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    /// Switch between text subtitles (or off) inside the current HLS stream.
    /// Returns false when the change needs a new stream from the server.
    func switchManifestSubtitle(to index: Int) async -> Bool {
        if let onDevice, ready, !stopped, let plan, let client {
            // The on-device player draws every subtitle format it was chosen for.
            if index >= 0 {
                guard let format = resolvedSource?.mediaStreams?.first(where: { $0.index == index && $0.type == "Subtitle" })?
                    .codec?.lowercased(), OnDevicePlayback.drawnSubtitles.contains(format) else { return false }
            }
            guard let subtitle = try? OnDevicePlayback.subtitle(index, plan: plan, source: resolvedSource, server: client.server)
            else { return false }
            onDevice.selectSubtitle(subtitle, client: client)
            self.plan = plan.selectingSubtitle(index)
            await reporter?.selectSubtitle(index)
            return true
        }
        guard manifestCarriesSubtitles, ready, !stopped, let plan, let item = player.currentItem,
              let streams = resolvedSource?.mediaStreams else { return false }
        guard await ManifestSubtitles.select(streamIndex: index, streams: streams, in: item),
              !stopped, player.currentItem === item else { return false }
        self.plan = plan.selectingSubtitle(index)
        await reporter?.selectSubtitle(index)
        return true
    }
    func skip(seconds: Int) {
        if let onDevice, ready, !stopped {
            let target = max(0, min(onDevice.duration ?? .infinity, currentSeconds + Double(seconds)))
            guard target.isFinite else { return }
            if let group = watchTogether, group.isJoined { Task { await group.requestSeek(seconds: target) }; return }
            Task { await onDevice.seek(to: target); refreshPresentation() }
            return
        }
        guard ready, !stopped, let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue else { return }
        let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
        guard start.isFinite, end.isFinite, player.currentTime().seconds.isFinite else { return }
        let target = min(end, max(start, player.currentTime().seconds + Double(seconds)))
        if let group = watchTogether, group.isJoined { Task { await group.requestSeek(seconds: target) }; return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }
    func refreshPresentation() {
        guard customControls else { return }
        if stopped { phase = error != nil ? .failed : finished ? .ended : .paused; return }
        func ranges(_ values: [NSValue]) -> [PlayerTimeRange] {
            values.compactMap { value in
                let range = value.timeRangeValue
                return PlayerTimeRange(start: range.start.seconds, end: CMTimeRangeGetEnd(range).seconds)
            }
        }
        let item = player.currentItem
        let duration = mediaDuration ?? onDevice?.duration ?? item?.duration.seconds
        // Retain the intended position through startup failure/retry. An empty
        // replacement item reports zero before its initial seek has completed.
        let localPosition = !ready && !live ? MediaTime.seconds(ticks: plan?.options.startTicks ?? 0) : currentSeconds
        if let onDevice {
            // The engine's AVPlayer runs its own local timeline; the engine maps it to the file's.
            let end = onDevice.duration ?? duration ?? 0
            timeline = PlayerTimeline(localPosition: localPosition, duration: duration, isLive: false,
                                      seekable: [PlayerTimeRange(start: 0, end: end)].compactMap { $0 },
                                      buffered: [PlayerTimeRange(start: localPosition, end: onDevice.buffered)].compactMap { $0 },
                                      liveEdgeOffset: 2)
        } else {
            timeline = PlayerTimeline(localPosition: localPosition, duration: live ? nil : duration,
                                      isLive: live, seekable: ranges(item?.seekableTimeRanges ?? []),
                                      buffered: ranges(item?.loadedTimeRanges ?? []), liveEdgeOffset: item?.recommendedTimeOffsetFromLive.seconds ?? 2)
        }
        if error != nil { phase = .failed }
        else if finished { phase = .ended }
        else if stopped { phase = .paused }
        else if !ready { phase = .preparing }
        else {
            switch player.timeControlStatus {
            case .playing: phase = .playing
            case .waitingToPlayAtSpecifiedRate: phase = .buffering
            case .paused: phase = .paused
            @unknown default: phase = .paused
            }
        }
    }
    func togglePlayback() {
        guard !stopped, ready else { return }
        if let group = watchTogether, group.isJoined {
            allowGroupCommands()
            let paused = player.timeControlStatus != .paused
            Task { await group.requestPause(paused) }; return
        }
        if player.timeControlStatus == .paused { resume() } else { pausePlayback() }
        refreshPresentation()
    }
    func seekLocal(seconds: Double, resume: Bool) async {
        guard !stopped, ready, seconds.isFinite else { return }
        if let group = watchTogether, group.isJoined { await group.requestSeek(seconds: seconds); return }
        pausePlayback()
        let completed = await seekPlayer(to: seconds)
        guard completed, !stopped, !Task.isCancelled else { return }
        if resume { self.resume() }
        refreshPresentation()
    }
    private func ensureActive() throws {
        try Task.checkCancellation()
        if stopped { throw CancellationError() }
    }
    private var position: Int64 {
        // AVPlayer reports the absolute VOD playlist position, including HLS.
        MediaTime.ticks(seconds: currentSeconds)
    }
    private var canSeek: Bool { onDevice != nil || player.currentItem?.seekableTimeRanges.isEmpty == false }
    private func stateChanged(_ status: AVPlayer.TimeControlStatus) async {
        refreshPresentation()
        guard !stopped, let reporter else { return }
        if status == .playing {
            loading = false
            await reporter.start(positionTicks: position, canSeek: canSeek)
        }
        if ready { await reporter.progress(positionTicks: position, paused: status != .playing, canSeek: canSeek) }
        guard ready, !groupPlaybackSuspended, let group = watchTogether, group.isJoined else { return }
        bufferingTask?.cancel()
        if status == .waitingToPlayAtSpecifiedRate {
            bufferingTask = Task { [weak self, weak group] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard self?.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                await group?.reportReadiness(buffering: true)
            }
        } else if status == .playing, group.group?.state == "Waiting" {
            await group.reportReadiness(buffering: false)
        } else if Date() > groupFeedbackSuppressedUntil {
            // AVKit/system controls can change playback without invoking the
            // custom buttons. Do not echo commands received from the server.
            if status == .paused, group.group?.state == "Playing" { await group.requestPause(true) }
            else if status == .playing, group.group?.state == "Paused" { await group.requestPause(false) }
        }
    }
    func pauseForInterface() {
        groupPlaybackSuspended = true
        groupFeedbackSuppressedUntil = .distantFuture
        pausePlayback()
        if let group = watchTogether, group.isJoined { Task { await group.pauseForInterface(self) } }
    }
    func allowGroupCommands() {
        groupPlaybackSuspended = false
        groupFeedbackSuppressedUntil = Date().addingTimeInterval(1)
    }
    func resumeAfterInterface() {
        allowGroupCommands()
        if let group = watchTogether, group.isJoined, let syncItemID {
            Task { await group.playerReady(self, itemID: syncItemID) }
        } else { resume() }
    }
    func leaveSyncPlay() {
        watchTogether = nil; bufferingTask?.cancel()
        groupPlaybackSuspended = false
        player.defaultRate = soloPlaybackRate
        if player.timeControlStatus == .playing { player.rate = soloPlaybackRate }
    }
    func applyGroupStop() { pauseForInterface(); finished = true; refreshPresentation() }
    func applyGroupCommand(_ command: String, ticks: Int64) async {
        guard !stopped, ready else { return }
        groupFeedbackSuppressedUntil = .distantFuture
        defer { groupFeedbackSuppressedUntil = Date().addingTimeInterval(1) }
        if command == "Stop" { pausePlayback(); refreshPresentation(); return }
        guard ["Pause", "Unpause", "Seek"].contains(command) else { return }
        let seconds = MediaTime.seconds(ticks: ticks)
        let shouldPlay = command == "Unpause" || command == "Seek" && watchTogether?.group?.state == "Playing"
        pausePlayback()
        if seconds.isFinite, abs(currentSeconds - seconds) > 0.15 { _ = await seekPlayer(to: seconds) }
        guard !stopped, !Task.isCancelled else { return }
        if shouldPlay {
            if onDevice != nil { player.defaultRate = 1; resume() } else { player.playImmediately(atRate: 1) }
        }
        refreshPresentation()
        if command == "Seek" { await watchTogether?.reportReadiness(buffering: false) }
    }
    private func progress() async {
        guard !stopped, let reporter else { return }
        await reporter.progress(positionTicks: position, paused: player.timeControlStatus != .playing, canSeek: canSeek)
        await watchTogether?.correctDrift(self)
    }
    func releaseForReplacement() async -> Bool {
        guard !isPreparing else { return false }
        await stop(keepingGroupPlayback: true)
        if let (client, stream) = unreleasedStream {
            do { try await client.closeLive(stream); unreleasedStream = nil }
            catch { return false }
        }
        return await reporter?.retryLiveCleanup() ?? true
    }
    func stop(failed: Bool = false, keepingGroupPlayback: Bool = false) async {
        if let stopTask { await stopTask.value; return }
        refreshPresentation()
        stopped = true
        shiftedSubtitles.detach()
        bufferingTask?.cancel()
        let finalPosition = position
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        pausePlayback()
        engineSubscriptions.removeAll()
        detachPlayerObservers()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        itemObservation?.invalidate()
        let cleanup = Task { @MainActor in
            if !keepingGroupPlayback { await watchTogether?.playerClosed(self) }
            await reporter?.stop(positionTicks: finalPosition, failed: failed)
            if let onDevice { onDevice.stop(owner: self) } else { player.replaceCurrentItem(with: nil) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        stopTask = cleanup
        await cleanup.value
        refreshPresentation()
    }
}

private struct IntroSegmentPage: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let type: String
        let startTicks: Int64
        let endTicks: Int64
    }
    let items: [Segment]
}

struct NativePlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    let presentation: PlaybackPresentation
    let onClose: () -> Void
    @State private var controller = PlaybackController()
    @State private var active: PlaybackPresentation?
    @State private var introItemID: String?
    @State private var intros: [IntroSegmentPage.Segment] = []
    @State private var nextEpisode: MediaItem?
    @State private var countdown = 5
    @State private var nextTask: Task<Void, Never>?
    @State private var switchTask: Task<Void, Never>?
    @State private var switchingEpisode = false
    @State private var showEpisodes = false
    @State private var resumeAfterBrowser = false
    @State private var queuedEpisode: MediaItem?
    @State private var resolvedItem: MediaItem?
    @State private var chrome = PlayerInteraction()
    @State private var customPanel: PlayerPanel?
    @State private var extras = PlayerExtrasModel()
    @State private var trackMemory = TrackMemory()
    @State private var queuedChapter: Double?
    @State private var queuedSettings: PlaybackOptions?
    @State private var queuedSettingsResume = false
    @State private var customBitrate: Int?
    @State private var automaticQuality = true
    @State private var adaptive: AdaptiveQuality?
    @State private var adaptiveItemID: String?
    @State private var videoFeatures = CustomVideoFeatures()
    @State private var seekTask: Task<Void, Never>?
    @State private var pendingSeek = PlayerPendingSeek()
    @State private var closingPlayer = false
    #if os(iOS)
    @State private var reviewPlaybackSeconds: TimeInterval = 0
    @State private var reviewPlaybackRecorded = false
    #endif
    @State private var liveClock = Date.now
    @State private var liveItemFetchedAt: Date?
    @State private var liveChannelsFetchedAt: Date?
    @State private var liveGuide: LivePlayerGuide?
    @State private var liveChannels: [MediaItem] = []
    @State private var channelQuery = ""
    @State private var channelLoadID = UUID()
    @State private var channelRetry = 0
    @State private var channelLoading = false
    @State private var channelError: String?
    @State private var queuedChannel: MediaItem?
    #if os(tvOS)
    @State private var liveTVConflict: String?
    @State private var tvTrackCategory = "Audio"
    @State private var tvControlsClearance: CGFloat = 0.22
    #endif
    #if DEBUG
    @AppStorage("custom-player-preview-enabled") private var customPreviewEnabled = true
    #endif
    private var usesCustomPlayer: Bool {
        #if os(tvOS)
        // Retain the managed engine/panel lifecycle; TV presentation uses AVKit.
        true
        #elseif DEBUG
        ProcessInfo.processInfo.arguments.contains("--custom-player") || customPreviewEnabled
        #else
        // The approved custom player ships in Release; the comparison switch is Debug-only.
        true
        #endif
    }
    private var episodeContext: MediaItem { resolvedItem?.id == current.item.id ? resolvedItem! : current.item }
    private var current: PlaybackPresentation { active ?? presentation }
    private var trackStore: TrackMemoryStore? {
        guard !model.isDemo, let session = model.session else { return nil }
        return TrackMemoryStore(scope: "\(session.server.storageKey).\(session.viewer.id)")
    }
    private func saveTrackMemory() { trackStore?.save(trackMemory, for: TrackMemory.key(for: episodeContext)) }
    private var playerSettingsItem: MediaItem {
        var item = episodeContext
        if let source = controller.resolvedSource { item.mediaSources = [source] }
        return item
    }

    private var liveProgram: LiveProgram? {
        guard current.item.isLive else { return nil }
        if liveGuide?.channelID == current.item.id, let program = liveGuide?.current(at: liveClock) { return program }
        guard let liveItemFetchedAt, (0..<120).contains(liveClock.timeIntervalSince(liveItemFetchedAt)) else { return nil }
        let fallback = resolvedItem?.id == current.item.id ? resolvedItem?.currentProgram : nil
        return fallback?.isAiring(at: liveClock) == true ? fallback : nil
    }
    private var playerTitle: String { current.item.isLive ? liveProgram?.name ?? current.item.name : episodeContext.displayTitle }
    private var playerSubtitle: String {
        if current.item.isLive { return liveProgram == nil ? "Live TV" : [current.item.channelNumber, current.item.name].compactMap { $0 }.joined(separator: " · ") }
        return episodeContext.isEpisode ? episodeContext.episodeLabel : ""
    }
    private var introEnd: Double? {
        guard introItemID == current.item.id, !model.watchTogether.isJoined, !controller.loading,
              let duration = controller.timeline.duration, controller.error == nil, !switchingEpisode, !showEpisodes, customPanel == nil else { return nil }
        let at = controller.timeline.position
        return intros.first {
            $0.type == "Intro" && $0.startTicks >= 0 && $0.endTicks > $0.startTicks &&
            MediaTime.seconds(ticks: $0.startTicks) <= at && at < MediaTime.seconds(ticks: $0.endTicks) &&
            MediaTime.seconds(ticks: $0.endTicks) < duration
        }.map { MediaTime.seconds(ticks: $0.endTicks) }
    }
    private var playbackCanvas: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if os(tvOS)
            SystemTVPlayerSurface(player: controller.player, engineSwitchesDisplay: controller.onDevice != nil,
                title: playerTitle, subtitle: playerSubtitle,
                overview: episodeContext.overview ?? "", allowsPiP: model.preferences.pictureInPicture,
                menuState: .init(episodes: episodeContext.isEpisode && episodeContext.seriesId != nil,
                                 chapters: !current.item.isLive && extras.hasChapters,
                                 live: current.item.isLive, canSeek: controller.timeline.canSeek && (!current.item.isLive || controller.timeline.canTimeShiftLive),
                                 canGoLive: controller.timeline.liveEdgeTarget != nil && (!controller.timeline.isAtLiveEdge || controller.phase == .paused),
                                 enabled: !controller.loading && !switchingEpisode && !controller.finished,
                                 grouped: model.watchTogether.isJoined),
                blocked: showEpisodes || customPanel != nil || switchingEpisode || controller.error != nil || controller.finished,
                action: customAction, close: closePlayer, onPiPChange: customPiPChanged,
                navigate: systemTVNavigate, contentClearance: { fraction in
                    // Keep the last visible transport measurement while AVKit hides it.
                    if fraction > 0.01 { tvControlsClearance = fraction }
                })
                .id(current.id)
                .ignoresSafeArea()
            #else
            if usesCustomPlayer {
                // The surface covers the whole cover and places the picture
                // from its UIKit window at layout time (see PlayerSurfaceHostView),
                // so a stale SwiftUI frame during rotation cannot shift or crop it.
                CustomVideoSurface(player: controller.player, features: videoFeatures, allowsPiP: model.preferences.pictureInPicture,
                                   sizing: chrome.videoSizing, onPiPChange: customPiPChanged)
                    .ignoresSafeArea()
                CustomPlayerControls(title: playerTitle, subtitle: playerSubtitle,
                    phase: switchingEpisode ? .preparing : pendingSeek.current?.resume == true ? .buffering : controller.phase, timeline: controller.timeline, skipBack: model.preferences.skipBack,
                    skipForward: model.preferences.skipForward,
                    hasEpisodes: episodeContext.isEpisode && episodeContext.seriesId != nil,
                    hasTracks: !(playerSettingsItem.mediaSources?.first?.mediaStreams ?? []).isEmpty,
                    showsRoutes: true, pipAvailable: videoFeatures.possible, isLive: current.item.isLive,
                    extras: current.item.isLive ? nil : extras,
                    interaction: $chrome, action: customAction)
                    .disabled(showEpisodes || customPanel != nil)
                    .allowsHitTesting(!showEpisodes && customPanel == nil)
                    .accessibilityHidden(showEpisodes || customPanel != nil)
            } else {
                PlayerSurface(player: controller.player, allowsPiP: model.preferences.pictureInPicture,
                              onPiPChange: { controller.inPictureInPicture = $0 }).ignoresSafeArea()
            }
            #endif
            if let device = controller.onDevice {
                #if os(tvOS)
                OnDeviceSubtitleOverlay(player: device, offset: controller.subtitleOffset).ignoresSafeArea()
                #else
                // The custom surface fits the picture inside the safe area.
                let fill = usesCustomPlayer && chrome.videoSizing == .fill
                OnDeviceSubtitleOverlay(player: device, fill: fill, offset: controller.subtitleOffset).ignoresSafeArea(edges: usesCustomPlayer && !fill ? [] : .all)
                #endif
            } else {
                // Empty unless a subtitle timing is set on a stream AVPlayer plays.
                ShiftedSubtitleOverlay(subtitles: controller.shiftedSubtitles).ignoresSafeArea()
            }
            if switchingEpisode { ProgressView("Preparing video…").padding(24).background(Theme.panel, in: RoundedRectangle(cornerRadius: 12)) }
            else if controller.loading && !usesCustomPlayer { ProgressView("Preparing \(current.item.name)…").padding(24).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12)) }
            if let error = controller.error {
                VStack(spacing: 16) {
                    StatusView(title: "Unable to play", detail: error, icon: "play.slash")
                    if usesCustomPlayer {
                        Button("Try again") { restartCustomPlayback(fromStart: false) }
                            .buttonStyle(ZoroButtonStyle(primary: true)).disabled(switchingEpisode)
                    }
                }.padding(24).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            }
            #if os(tvOS)
            if controller.finished && controller.error == nil && !switchingEpisode {
                VStack(spacing: 20) {
                    Text("Playback finished").font(Theme.font(32, weight: .semibold))
                    Button(current.item.isLive ? "Reconnect" : "Watch again") { customAction(.replay) }
                        .buttonStyle(ZoroButtonStyle(primary: true))
                    Button("Close player", action: closePlayer).buttonStyle(ZoroButtonStyle())
                }.padding(32).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
            }
            #endif
        }
    }
    var body: some View {
        Group {
            #if os(iOS)
            GeometryReader { viewport in
                playbackCanvas.frame(width: viewport.size.width, height: viewport.size.height)
            }
            #else
            playbackCanvas
            #endif
        }
        .overlay(alignment: .top) {
            if !usesCustomPlayer {
            HStack(spacing: 12) {
                Button { closePlayer() } label: { Image(systemName: "chevron.left").font(.system(size: 20, weight: .regular)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .buttonStyle(PlayerIconStyle()).accessibilityLabel("Close player")
                Spacer()
                if episodeContext.isEpisode, episodeContext.seriesId != nil {
                    Button { openEpisodes() } label: {
                        if textSize.isAccessibilitySize {
                            Image(systemName: "rectangle.stack").frame(minHeight: Theme.target)
                        } else { Label("Episodes", systemImage: "rectangle.stack") }
                    }.buttonStyle(ZoroButtonStyle()).disabled(switchingEpisode)
                        .accessibilityLabel("Choose season or episode").accessibilityIdentifier("player-episodes")
                }
                Menu {
                    Button("Back \(model.preferences.skipBack) seconds", systemImage: "gobackward") { controller.skip(seconds: -model.preferences.skipBack) }
                    Button("Forward \(model.preferences.skipForward) seconds", systemImage: "goforward") { controller.skip(seconds: model.preferences.skipForward) }
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: Theme.target, height: Theme.target)
                }.buttonStyle(PlayerIconStyle()).accessibilityLabel("Player controls").disabled(controller.loading || controller.finished)
            }.padding(Theme.isTV ? 48 : 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let end = introEnd, nextEpisode == nil {
                Button("Skip intro") { seekCustom(to: end, resume: controller.phase != .paused) }
                    .buttonStyle(ZoroButtonStyle()).padding(.trailing, Theme.isTV ? 48 : 16)
                    .padding(.bottom, Theme.isTV ? 160 : 100)
            }
            if let nextEpisode {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Up next in \(countdown)").font(.headline)
                    Text(nextEpisode.displayTitle).font(.title3.bold())
                    Text(nextEpisode.episodeLabel).foregroundStyle(Theme.muted)
                    HStack {
                        Button("Play now") { startNext() }.buttonStyle(ZoroButtonStyle(primary: true))
                        Button("Cancel") { nextTask?.cancel(); self.nextEpisode = nil }.buttonStyle(ZoroButtonStyle())
                    }
                }.padding(24).background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
                    .frame(maxWidth: Theme.isTV ? 660 : 380).padding(Theme.isTV ? 48 : 16)
            }
        }
        .overlay {
            if usesCustomPlayer && showEpisodes { episodeOptionsPanel }
            else if customPanel != nil { customSettingsPanel }
        }
        .sheet(isPresented: Binding(get: { showEpisodes && !usesCustomPlayer }, set: { showEpisodes = $0 }), onDismiss: closeEpisodes) {
            episodeOptionsPanel
        }
        .onChange(of: showEpisodes) { previous, visible in
            if usesCustomPlayer, previous && !visible { closeEpisodes() }
        }
        .onChange(of: customPanel) { previous, panel in
            if previous != nil && panel == nil { closeCustomPanel() }
        }
        .task(id: "adaptive-\(current.id)-\(scenePhase == .active)") {
            if adaptive == nil || adaptiveItemID != current.item.id {
                adaptiveItemID = current.item.id
                adaptive = AdaptiveQuality(ceiling: current.options.bitrate)
            }
            while !Task.isCancelled && !closingPlayer {
                await adaptQuality()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: "live-clock-\(current.id)-\(scenePhase == .active)") {
            guard usesCustomPlayer, current.item.isLive, scenePhase == .active else { return }
            // AVPlayer's time observer stops while paused; the live window does not.
            while !Task.isCancelled && !closingPlayer {
                liveClock = .now; controller.refreshPresentation()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        .task(id: "live-guide-\(current.id)-\(scenePhase == .active)") {
            guard usesCustomPlayer, current.item.isLive, scenePhase == .active, let client = model.client else { return }
            let generation = model.generation, selected = current
            while !Task.isCancelled {
                let guide = try? await client.livePlayerGuide(channelID: selected.item.id)
                guard !Task.isCancelled, !closingPlayer, generation == model.generation, current.id == selected.id else { return }
                if let guide { liveGuide = guide }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: "extras-\(current.id)-\(controller.resolvedSource?.id ?? "")") {
            let item = current.item
            extras.showChapters = model.preferences.showChapters == true
            guard !item.isLive, let client = model.client, let source = controller.resolvedSource else { extras.reset(); return }
            if extras.itemID != item.id { await extras.load(client: client, itemID: item.id, mediaSourceID: source.id) }
        }
        .task(id: "intro-\(current.id)") {
            intros = []
            introItemID = nil
            let item = current.item
            guard item.isEpisode, let client = model.client else { return }
            let page = try? await client.request(IntroSegmentPage.self, path: ["MediaSegments", item.id],
                query: [URLQueryItem(name: "includeSegmentTypes", value: "Intro")])
            guard !Task.isCancelled, current.item.id == item.id else { return }
            intros = page?.items ?? []
            introItemID = item.id
        }
        .task(id: current.id) {
            guard let client = model.client else { return }
            let generation = model.generation, selected = current, preparing = controller
            await model.waitForSettings()
            var item = selected.item
            var metadataFetchedAt: Date?
            // Per-viewer stream defaults may have changed since browsing this title.
            if let details = try? await client.item(item.id, fresh: true) { item = details; metadataFetchedAt = .now }
            guard !Task.isCancelled, !closingPlayer, generation == model.generation, current.id == selected.id else { return }
            resolvedItem = item; liveItemFetchedAt = metadataFetchedAt
            // What the viewer last picked for this show wins over the account
            // defaults, unless this playback asked for specific tracks.
            var requested = selected.options
            let memory = item.isLive ? TrackMemory() : trackStore?.memory(for: TrackMemory.key(for: item)) ?? TrackMemory()
            if !item.isLive, requested.audioIndex == nil, requested.subtitleIndex == -2 {
                let streams = item.mediaSources?.first?.mediaStreams ?? []
                let audio = streams.filter { $0.type == "Audio" }
                let picked = memory.pick(streams)
                // Leave the file's default implicit to preserve direct playback.
                if let index = picked.audio, index != (audio.first { $0.isDefault == true } ?? audio.first)?.index { requested.audioIndex = index }
                if let index = picked.subtitle { requested.subtitleIndex = index }
            }
            trackMemory = memory
            preparing.subtitleOffset = memory.subtitleOffset
            var options = (model.viewerSettings ?? ViewerSettings(name: model.viewerName)).playbackOptions(requested, item: item)
            if options.subtitleIndex == -2 { options.subtitleIndex = -1 }
            preparing.customControls = usesCustomPlayer
            preparing.watchTogether = model.watchTogether.isJoined ? model.watchTogether : nil
            preparing.keepsLiveWindowFresh = scenePhase == .active || preparing.inPictureInPicture || preparing.player.isExternalPlaybackActive
            var preferences = model.preferences
            preferences.playbackSpeed = selected.item.isLive ? 1 : preferences.playbackSpeed
            await preparing.prepare(client: client, presentation: .init(item: item, options: options), preferences: preferences,
                                    liveTVCapacityEnabled: model.features.liveTVAvailability,
                                    problemReports: model.features.playbackReports && model.preferences.sendPlaybackReports != false)
            preparing.setAudioOffset(memory.audioOffset, immediately: true)
            if showEpisodes || scenePhase == .background && model.preferences.pauseInBackground && !preparing.inPictureInPicture && !(usesCustomPlayer && preparing.player.isExternalPlaybackActive) {
                preparing.pauseForInterface()
            }
        }
        .onChange(of: controller.finished) { _, finished in
            if finished { controller.refreshPresentation(); nextTask = Task { await prepareNext() } }
        }
        .task(id: model.watchTogether.playbackRequest?.id) {
            guard let request = model.watchTogether.playbackRequest, !closingPlayer else { return }
            while controller.isPreparing || switchingEpisode {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, !closingPlayer else { return }
            if request.item.id != current.item.id {
                await replacePlayback(item: request.item, options: request.options, resume: true)
            }
            if model.watchTogether.playbackRequest?.id == request.id { model.watchTogether.playbackRequest = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if usesCustomPlayer && current.item.isLive {
                controller.keepsLiveWindowFresh = phase == .active || controller.inPictureInPicture || controller.player.isExternalPlaybackActive
                controller.player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = controller.keepsLiveWindowFresh
            }
            if phase == .background {
                chrome.interrupt(now: ProcessInfo.processInfo.systemUptime)
                // An open options/browser overlay may survive backgrounding.
                queuedSettingsResume = false; resumeAfterBrowser = false
                cancelCustomSeek()
                nextTask?.cancel(); nextEpisode = nil
                if model.preferences.pauseInBackground && !controller.inPictureInPicture && !(usesCustomPlayer && controller.player.isExternalPlaybackActive) {
                    // A pending prepare must not auto-start after the app has backgrounded.
                    if usesCustomPlayer { controller.startsPaused = true }
                    controller.pauseForInterface()
                }
            } else if phase == .active && usesCustomPlayer {
                controller.refreshPresentation()
                // PiP/AirPlay may keep playing while the UI's interruption state is paused.
                chrome.update(phase: controller.phase, now: ProcessInfo.processInfo.systemUptime)
            }
        }
        #if os(iOS)
        .background(PhonePlaybackOrientation().allowsHitTesting(false))
        .task(id: "review-\(controller.phase)-\(scenePhase)-\(current.id)") {
            guard !model.isDemo, scenePhase == .active, controller.phase == .playing else { return }
            while !Task.isCancelled && reviewPlaybackSeconds < 300 {
                let started = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard !Task.isCancelled, !closingPlayer, controller.player.timeControlStatus == .playing else { return }
                // Count foreground wall time, never media position or seek jumps.
                reviewPlaybackSeconds += min(10, max(0, ProcessInfo.processInfo.systemUptime - started))
            }
        }
        #endif
        .onDisappear {
            #if os(iOS)
            if !model.isDemo && !reviewPlaybackRecorded {
                reviewPlaybackRecorded = true
                model.reviewPrompts.recordPlayback(activeSeconds: reviewPlaybackSeconds, failed: controller.error != nil)
            }
            #endif
            closingPlayer = true; chrome.close()
            nextTask?.cancel(); switchTask?.cancel(); cancelCustomSeek()
            let client = model.client, generation = model.generation, closing = controller
            Task {
                await closing.stop()
                await client?.responseCache?.invalidateMetadata()
                guard generation == model.generation else { return }
                model.libraryRevision += 1; model.homeRevision += 1
            }
        }
        #if os(tvOS)
        .onChange(of: controller.phase, initial: true) { _, phase in
            chrome.update(phase: phase, now: ProcessInfo.processInfo.systemUptime)
        }
        // AVKit owns Back while playing, scrubbing and navigating its menus.
        // Only Zorofin overlays intercept it; nil leaves the native responder alone.
        .onExitCommand(perform: systemTVOverlayBack)
        .alert("Live TV is in use", isPresented: Binding(get: { liveTVConflict != nil }, set: { if !$0 { liveTVConflict = nil } })) {
            Button("OK", role: .cancel) { liveTVConflict = nil }
        } message: { Text(liveTVConflict ?? "") }
        #endif
    }
    #if os(tvOS)
    private var systemTVOverlayBack: (() -> Void)? {
        if showEpisodes { return { showEpisodes = false } }
        if customPanel != nil { return { customPanel = nil } }
        if controller.error != nil || controller.finished { return closePlayer }
        return nil
    }
    /// AVKit seeks locally. Keep server-required restarts and SyncPlay routing
    /// at the existing engine boundary; nil suppresses the local seek.
    private func systemTVNavigate(_ target: Double) -> Double? {
        guard target.isFinite, !closingPlayer, !switchingEpisode, scenePhase == .active else { return nil }
        controller.refreshPresentation()
        if model.watchTogether.isJoined {
            controller.allowGroupCommands()
            Task { await model.watchTogether.requestSeek(seconds: target); await model.watchTogether.requestPause(false) }
            return nil
        }
        switch controller.timeline.seek(to: target, allowRestart: true) {
        case .local(let seconds): return seconds
        case .restart(let seconds): customAction(.seek(seconds, resume: true)); return nil
        case .unavailable: return nil
        }
    }
    #endif
    private func prepareNext() async {
        guard !model.watchTogether.isJoined, !closingPlayer, model.viewerSettings?.bool("EnableNextEpisodeAutoPlay") == true,
              episodeContext.isEpisode, scenePhase == .active, !showEpisodes, customPanel == nil, !switchingEpisode, let client = model.client else { return }
        let generation = model.generation, itemID = current.item.id
        do {
            guard let next = try await client.followingEpisode(episodeContext) else { return }
            guard !Task.isCancelled, generation == model.generation, current.item.id == itemID, scenePhase == .active, !showEpisodes else { return }
            nextEpisode = next; countdown = 5
            for remaining in (1...5).reversed() {
                countdown = remaining
                try await Task.sleep(for: .seconds(1))
                guard generation == model.generation, scenePhase == .active, !showEpisodes else { return }
            }
            try Task.checkCancellation()
            startNext()
        } catch { /* Reaching the end never starts playback without a verified next episode. */ }
    }
    private func openEpisodes() {
        guard !closingPlayer else { return }
        let pendingResume = pendingSeek.current?.resume
        if usesCustomPlayer {
            cancelCustomSeek()
            if let pendingResume { chrome.update(phase: pendingResume ? .playing : .paused, now: ProcessInfo.processInfo.systemUptime) }
            chrome.open(.episodes)
        }
        nextTask?.cancel(); nextEpisode = nil
        resumeAfterBrowser = pendingResume ?? (controller.player.rate > 0 || controller.loading)
        controller.pausedForEpisodeBrowser = true
        controller.pauseForInterface()
        showEpisodes = true
    }
    private func closeEpisodes() {
        guard !closingPlayer else { queuedEpisode = nil; resumeAfterBrowser = false; return }
        if usesCustomPlayer { _ = chrome.closePanel(now: ProcessInfo.processInfo.systemUptime, active: scenePhase == .active, replacing: queuedEpisode != nil) }
        controller.pausedForEpisodeBrowser = false
        if let episode = queuedEpisode {
            queuedEpisode = nil; resumeAfterBrowser = false
            switchTask = Task { await switchEpisode(to: episode) }
        } else {
            if resumeAfterBrowser && scenePhase == .active && !controller.finished && controller.error == nil { controller.resumeAfterInterface() }
            resumeAfterBrowser = false
        }
    }
    private func startNext() {
        guard !closingPlayer, let nextEpisode else { return }
        nextTask?.cancel(); self.nextEpisode = nil
        switchTask = Task { await switchEpisode(to: nextEpisode) }
    }
    private func switchEpisode(to episode: MediaItem) async {
        guard !switchingEpisode, episode.isEpisode, let series = episodeContext.seriesId,
              episode.seriesId == series, episode.id != current.item.id, scenePhase == .active else { return }
        let options = PlaybackOptions(startTicks: episode.resumeTicks, bitrate: customBitrate ?? model.bitrate, subtitleIndex: -2)
        if model.watchTogether.isJoined { await model.watchTogether.selectForPlayback(episode, options: options) }
        else { await replacePlayback(item: episode, options: options, resume: true) }
    }
    private func replacePlayback(item: MediaItem, options: PlaybackOptions, resume: Bool) async {
        guard !closingPlayer, !switchingEpisode, !controller.isPreparing, scenePhase == .active else { return }
        switchingEpisode = true
        cancelCustomSeek()
        defer { switchingEpisode = false }
        let generation = model.generation, previousID = current.id, closing = controller
        let previousClient = model.client, changingItem = item.id != current.item.id
        #if os(tvOS)
        if item.isLive, let client = previousClient {
            do { try await client.checkLiveTVCapacity(channelID: item.id, features: model.features) }
            catch let conflict as LiveTVStreamsConflict {
                if generation == model.generation, current.id == previousID, !closingPlayer, !Task.isCancelled {
                    liveTVConflict = conflict.localizedDescription
                }
                return
            } catch let conflict as LiveTVCapacityError {
                if generation == model.generation, current.id == previousID, !closingPlayer, !Task.isCancelled {
                    liveTVConflict = conflict.localizedDescription
                }
                return
            } catch { return }
            guard !Task.isCancelled, !closingPlayer, generation == model.generation, current.id == previousID,
                  scenePhase == .active else { return }
        }
        #endif
        nextTask?.cancel(); nextEpisode = nil
        // Finish reporting and audio cleanup before preparing the replacement player.
        guard await closing.releaseForReplacement() else {
            closing.error = "The previous live stream could not be released. Try again before opening another channel."
            closing.refreshPresentation(); return
        }
        // Live channel and track/quality/seek changes keep the cached catalog.
        // Capture the old client before awaiting so an account switch cannot clear the new account's cache.
        if changingItem && !current.item.isLive { await previousClient?.responseCache?.invalidateMetadata() }
        guard !closingPlayer, !Task.isCancelled, generation == model.generation, current.id == previousID else { return }
        guard scenePhase == .active else {
            closing.error = "Playback was interrupted while changing the video. Return to the player and try again."
            closing.refreshPresentation(); return
        }
        let sizing = changingItem ? PlayerVideoSizing.fit : chrome.videoSizing
        controller = PlaybackController(); controller.startsPaused = !resume
        resolvedItem = nil; liveItemFetchedAt = nil; liveGuide = nil; chrome = PlayerInteraction()
        chrome.setVideoSizing(sizing, now: ProcessInfo.processInfo.systemUptime)
        active = .init(item: item, options: options)
    }

    private func customPiPChanged(_ active: Bool) {
        controller.inPictureInPicture = active
        if current.item.isLive {
            controller.keepsLiveWindowFresh = scenePhase == .active || active || controller.player.isExternalPlaybackActive
            controller.player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = controller.keepsLiveWindowFresh
        }
        if !active, scenePhase == .background, model.preferences.pauseInBackground,
           !controller.player.isExternalPlaybackActive {
            controller.pauseForInterface(); controller.refreshPresentation()
        }
    }
    /// Dismiss through the full-screen cover's owning binding, without waiting
    /// for the server. onDisappear retains responsibility for stop/report cleanup.
    private func closePlayer() {
        guard !closingPlayer else { return }
        closingPlayer = true; chrome.close()
        nextTask?.cancel(); nextEpisode = nil
        switchTask?.cancel(); cancelCustomSeek()
        queuedEpisode = nil; queuedChannel = nil; queuedSettings = nil
        queuedSettingsResume = false; resumeAfterBrowser = false
        controller.startsPaused = true; controller.pausedForEpisodeBrowser = true
        controller.pauseForInterface()
        onClose()
    }
    private func customAction(_ action: CustomPlayerAction) {
        if case .close = action { closePlayer(); return }
        if case .routePicker(let visible) = action {
            if visible && scenePhase == .active && !closingPlayer { chrome.open(.routes) }
            else { _ = chrome.closePanel(now: ProcessInfo.processInfo.systemUptime, active: scenePhase == .active && !closingPlayer) }
            return
        }
        guard !closingPlayer, !switchingEpisode, scenePhase == .active else { return }
        switch action {
        case .close: closePlayer()
        case .togglePlayback:
            let seeking = pendingSeek.current
            cancelCustomSeek()
            if let seeking {
                if seeking.resume { controller.pauseForInterface() } else { controller.resumeAfterInterface() }
                controller.refreshPresentation()
            } else if current.item.isLive && controller.phase == .paused {
                controller.refreshPresentation()
                // Pausing may outlast the stream's sliding window.
                if controller.timeline.canSeek {
                    seekCustom(to: controller.timeline.position, resume: true)
                } else { controller.togglePlayback() }
            } else { controller.togglePlayback() }
        case .replay:
            if model.watchTogether.isJoined {
                controller.allowGroupCommands()
                Task { await model.watchTogether.requestSeek(seconds: 0); await model.watchTogether.requestPause(false) }
            } else { restartCustomPlayback(fromStart: true) }
        case .goLive:
            controller.refreshPresentation()
            if let target = controller.timeline.liveEdgeTarget { seekCustom(to: target, resume: true) }
        case .pause:
            cancelCustomSeek()
            if model.watchTogether.isJoined { Task { await model.watchTogether.requestPause(true) } }
            else { controller.pauseForInterface(); controller.refreshPresentation() }
        case .pauseForScrub: cancelCustomSeek(); controller.pauseForInterface(); controller.refreshPresentation()
        case .resumeAfterScrub:
            cancelCustomSeek(); controller.resumeAfterInterface(); controller.refreshPresentation()
        case .videoSizing(let sizing): chrome.setVideoSizing(sizing, now: ProcessInfo.processInfo.systemUptime)
        case .pictureInPicture: videoFeatures.toggle()
        case .routePicker: break
        case .skip(let amount):
            seekCustom(to: (pendingSeek.current?.position ?? controller.timeline.position) + Double(amount),
                       resume: pendingSeek.current?.resume ?? (controller.phase == .playing || controller.phase == .buffering))
        case .seek(let target, let resume): seekCustom(to: target, resume: resume)
        case .panel(.episodes): openEpisodes()
        case .panel(let panel):
            guard chrome.scrubPosition == nil,
                  panel != .channels || current.item.isLive && !controller.loading else { return }
            let pendingResume = pendingSeek.current?.resume
            cancelCustomSeek()
            if let pendingResume { chrome.update(phase: pendingResume ? .playing : .paused, now: ProcessInfo.processInfo.systemUptime) }
            _ = chrome.open(panel)
            nextTask?.cancel(); nextEpisode = nil
            // Keep the broadcast moving while browsing channels or options.
            if !current.item.isLive && panel != .information { controller.pausedForEpisodeBrowser = true; controller.pauseForInterface() }
            customPanel = panel
        }
    }
    private func restartCustomPlayback(fromStart: Bool) {
        guard !switchingEpisode, scenePhase == .active else { return }
        var options = controller.resolvedOptions ?? current.options
        options.startTicks = fromStart || current.item.isLive ? 0 : MediaTime.ticks(seconds: controller.timeline.position)
        let item = episodeContext
        switchTask = Task { await replacePlayback(item: item, options: options, resume: true) }
    }
    private func cancelCustomSeek() {
        seekTask?.cancel(); seekTask = nil; pendingSeek.cancel()
        controller.player.currentItem?.cancelPendingSeeks()
    }
    private func seekCustom(to target: Double, resume: Bool) {
        guard !switchingEpisode, scenePhase == .active else { return }
        if model.watchTogether.isJoined {
            controller.allowGroupCommands()
            cancelCustomSeek()
            Task { await model.watchTogether.requestSeek(seconds: target) }
            return
        }
        controller.refreshPresentation()
        cancelCustomSeek()
        let selected = controller, generation = model.generation, presentationID = current.id
        switch selected.timeline.seek(to: target, allowRestart: true) {
        case .local(let seconds):
            guard let request = pendingSeek.begin(position: seconds + selected.timeline.offset, resume: resume) else { return }
            seekTask = Task {
                defer { pendingSeek.finish(request.id) }
                guard generation == model.generation, presentationID == current.id else { return }
                await selected.seekLocal(seconds: seconds, resume: resume)
            }
        case .restart(let absolute):
            var options = selected.resolvedOptions ?? current.options
            options.startTicks = MediaTime.ticks(seconds: absolute)
            let item = episodeContext
            guard let request = pendingSeek.begin(position: absolute, resume: resume) else { return }
            seekTask = Task {
                defer { pendingSeek.finish(request.id) }
                await replacePlayback(item: item, options: options, resume: resume)
            }
        case .unavailable:
            if resume && scenePhase == .active { selected.resumeAfterInterface() }
        }
    }
    private func closeCustomPanel() {
        guard !closingPlayer else { queuedSettings = nil; queuedChannel = nil; queuedChapter = nil; return }
        let pausedForPanel = controller.pausedForEpisodeBrowser
        controller.pausedForEpisodeBrowser = false
        if let chapter = queuedChapter {
            queuedChapter = nil; queuedSettings = nil; queuedSettingsResume = false
            _ = chrome.closePanel(now: ProcessInfo.processInfo.systemUptime, active: scenePhase == .active)
            seekCustom(to: chapter, resume: true)
        } else if let channel = queuedChannel {
            queuedChannel = nil
            _ = chrome.closePanel(now: ProcessInfo.processInfo.systemUptime, active: scenePhase == .active, replacing: true)
            switchTask = Task {
                await replacePlayback(item: channel, options: .init(bitrate: customBitrate ?? model.bitrate, subtitleIndex: -2), resume: true)
            }
        } else if let options = queuedSettings {
            queuedSettings = nil
            let resume = queuedSettingsResume && chrome.panelResumeIntent && scenePhase == .active
            queuedSettingsResume = false
            let original = controller.resolvedOptions ?? current.options
            let item = episodeContext
            if options.bitrate == original.bitrate, options.audioIndex == original.audioIndex,
               options.subtitleIndex != original.subtitleIndex {
                // Text subtitles already in the stream switch in place; anything
                // else (first subtitle, image subtitles) falls back to a new stream.
                _ = chrome.closePanel(now: ProcessInfo.processInfo.systemUptime, active: scenePhase == .active)
                let selected = controller
                switchTask = Task {
                    if await selected.switchManifestSubtitle(to: options.subtitleIndex) {
                        guard selected === controller, !closingPlayer else { return }
                        selected.refreshPresentation()
                        if resume && scenePhase == .active && !selected.finished && selected.error == nil { selected.resumeAfterInterface() }
                    } else {
                        await replacePlayback(item: item, options: options, resume: resume)
                    }
                }
            } else {
                _ = chrome.closePanel(now: ProcessInfo.processInfo.systemUptime, active: scenePhase == .active, replacing: true)
                switchTask = Task { await replacePlayback(item: item, options: options, resume: resume) }
            }
        } else if chrome.closePanel(now: ProcessInfo.processInfo.systemUptime, active: scenePhase == .active), pausedForPanel, !controller.finished, controller.error == nil {
            controller.resumeAfterInterface()
        }
        if controller.finished && !current.item.isLive { nextTask = Task { await prepareNext() } }
    }
    private func adaptQuality() async {
        let playerItem = controller.player.currentItem
        let localPosition = controller.player.currentTime().seconds
        let ahead = playerItem?.loadedTimeRanges.map { value in
            let range = value.timeRangeValue, start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            return start <= localPosition && end >= localPosition ? end-localPosition : 0
        }.max() ?? 0
        let options = controller.resolvedOptions ?? current.options
        let next = adaptive?.sample(now: ProcessInfo.processInfo.systemUptime,
            position: controller.timeline.position, bitrate: options.bitrate,
            enabled: automaticQuality && !model.watchTogether.isJoined && scenePhase == .active,
            ready: playerItem?.status == .readyToPlay && !controller.loading && !controller.finished && controller.error == nil && !switchingEpisode,
            paused: controller.phase == .paused || customPanel != nil || showEpisodes,
            seeking: pendingSeek.current != nil || chrome.scrubPosition != nil,
            buffering: controller.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            bufferedAhead: ahead, sourceBitrate: controller.resolvedSource?.bitrate)
        guard let next, !closingPlayer, !Task.isCancelled else { return }
        if next < options.bitrate {
            controller.reportProblem(.qualityLowered, reason: "\(options.bitrate / 1_000_000) to \(next / 1_000_000) Mbps after buffering")
        }
        var replacement = options
        replacement.bitrate = next
        replacement.startTicks = current.item.isLive ? 0 : MediaTime.ticks(seconds: controller.timeline.position)
        await replacePlayback(item: current.item, options: replacement, resume: true)
    }

    private func changePlayerSetting(_ change: PlayerSettingChange) {
        guard !closingPlayer, !switchingEpisode, scenePhase == .active, controller.phase != .preparing else { return }
        do {
            controller.refreshPresentation()
            let previous = queuedSettings ?? controller.resolvedOptions ?? current.options
            let next = try previous.changing(change, item: playerSettingsItem, position: controller.timeline.position)
            let original = controller.resolvedOptions ?? current.options
            if next.bitrate != original.bitrate || next.audioIndex != original.audioIndex || next.subtitleIndex != original.subtitleIndex {
                queuedSettings = next; queuedSettingsResume = chrome.panelResumeIntent
            } else {
                queuedSettings = nil; queuedSettingsResume = false
            }
            if case .bitrate(let value) = change { customBitrate = value; automaticQuality = false }
            if !current.item.isLive {
                let streams = playerSettingsItem.mediaSources?.first?.mediaStreams ?? []
                switch change {
                case .audio(let index?):
                    trackMemory = trackMemory.choosing(audio: streams.first { $0.type == "Audio" && $0.index == index }); saveTrackMemory()
                case .subtitles(let index) where index == -1:
                    trackMemory = trackMemory.choosing(off: true); saveTrackMemory()
                case .subtitles(let index) where index >= 0:
                    trackMemory = trackMemory.choosing(subtitle: streams.first { $0.type == "Subtitle" && $0.index == index }); saveTrackMemory()
                default: break
                }
            }
        } catch { model.message = "That option is no longer available for this video. Reopen the player options and try again." }
    }
    private var customPanelTitle: String {
        switch customPanel {
        case .channels: "Channels & guide"
        case .tracks: "Audio & subtitles"
        case .chapters: "Chapters"
        case .quality: "Quality"
        case .information: "Playback info"
        default: "Player options"
        }
    }
    private var episodeOptionsPanel: some View {
        ScrollViewReader { proxy in
            PlayerOptionsSurface(title: "Seasons & episodes", context: episodeContext.seriesName ?? episodeContext.displayTitle,
                                 wide: true, fullWidth: Theme.isTV, controlsClearance: controlsClearance, close: { showEpisodes = false }) { _ in
                SeasonEpisodeBrowser(context: episodeContext,
                    scrollToEpisode: { id in proxy.scrollTo(id, anchor: .center) }, playSelection: { episode in
                        queuedEpisode = episode.id == current.item.id ? nil : episode
                        showEpisodes = false
                    }).id(model.generation)
            }
        }
    }
    private var customSettingsPanel: some View {
        PlayerOptionsSurface(title: customPanelTitle, context: playerTitle, wide: customPanel == .channels || customPanel == .chapters && Theme.isTV,
                             fullWidth: customPanel == .chapters && Theme.isTV, liveSchedule: customPanel == .channels,
                             controlsClearance: controlsClearance, close: { customPanel = nil }) { width in
            VStack(alignment: .leading, spacing: Theme.isTV ? 12 : 20) {
                if customPanel == .channels {
                    liveChannelFields
                } else if customPanel == .tracks {
                    if current.item.isLive {
                        Text(Theme.isTV ? "Changes restart at live." : "Changing a track reconnects at live and clears the rewind buffer.")
                            .font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(Theme.muted)
                    }
                    #if os(tvOS)
                    Picker("Tracks", selection: $tvTrackCategory) {
                        Text("Audio").tag("Audio")
                        Text("Subtitles").tag("Subtitles")
                    }.pickerStyle(.segmented).accessibilityIdentifier("player-track-category")
                    if tvTrackCategory == "Audio" { audioChoices } else { subtitleChoices }
                    #else
                    let layout = width >= 620 && !textSize.isAccessibilitySize
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.isTV ? 80 : 36))
                        : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
                    layout { audioChoices; subtitleChoices }
                    #endif
                } else if customPanel == .chapters {
                    ChapterChoices(extras: extras, position: controller.timeline.position) { chapter in
                        queuedChapter = chapter.start; customPanel = nil
                    }.playerFocusSection()
                } else if customPanel == .quality {
                    Text(Theme.isTV ? (current.item.isLive ? "Changes restart at live." : "Maximum streaming bitrate") : (current.item.isLive ? "Changing quality reconnects at live and clears the rewind buffer." : "Maximum streaming bitrate. Original quality plays when it fits this limit and your device."))
                        .font(Theme.font(Theme.isTV ? 21 : 14)).foregroundStyle(Theme.muted)
                    VStack(spacing: 2) {
                        playerChoice("Auto · up to \((adaptive?.ceiling ?? model.bitrate) / 1_000_000) Mbps", selected: automaticQuality,
                                     preferred: automaticQuality) {
                            changePlayerSetting(.bitrate(adaptive?.ceiling ?? model.bitrate)); automaticQuality = true
                        }
                        let bitrateChoices = [120, 80, 60, 40, 20, 12, 8, 4, 2]
                        ForEach(bitrateChoices, id: \.self) { mbps in
                            playerChoice("\(mbps) Mbps", selected: !automaticQuality && selectedPlayerOptions.bitrate == mbps * 1_000_000,
                                         preferred: !automaticQuality && (selectedPlayerOptions.bitrate == mbps * 1_000_000 ||
                                            (mbps == 40 && !bitrateChoices.contains(where: { selectedPlayerOptions.bitrate == $0 * 1_000_000 })))) {
                                changePlayerSetting(.bitrate(mbps * 1_000_000))
                            }
                        }
                    }.frame(maxWidth: Theme.isTV ? 680 : 480, alignment: .leading)
                        .playerFocusSection()
                } else if customPanel == .information {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in playbackInformation }
                }
                if queuedSettings != nil {
                    Text("Changes apply when you return to playback.")
                        .font(Theme.font(Theme.isTV ? 19 : 13)).foregroundStyle(Theme.jade)
                        .accessibilityIdentifier("player-options-pending")
                }
            }
        }.task(id: "\(customPanel?.rawValue ?? "")-\(channelRetry)") {
            if customPanel == .channels { await loadLiveChannels() }
        }
    }
    private var selectedPlayerOptions: PlaybackOptions { queuedSettings ?? controller.resolvedOptions ?? current.options }
    private var controlsClearance: CGFloat {
        #if os(tvOS)
        tvControlsClearance
        #else
        0
        #endif
    }
    private var audioChoices: some View {
        let streams = (playerSettingsItem.mediaSources?.first?.mediaStreams ?? []).filter { $0.type == "Audio" && $0.index >= 0 }
        return VStack(alignment: .leading, spacing: 10) {
            #if !os(tvOS)
            Text("Audio").font(Theme.font(21, weight: .semibold)).padding(.bottom, 4)
            #endif
            playerChoice("Automatic", selected: selectedPlayerOptions.audioIndex == nil,
                         preferred: !streams.contains(where: { $0.index == selectedPlayerOptions.audioIndex })) { changePlayerSetting(.audio(nil)) }
            ForEach(streams, id: \.index) { stream in
                playerChoice(trackLanguage(stream), detail: trackDetail(stream, among: streams), selected: selectedPlayerOptions.audioIndex == stream.index) {
                    changePlayerSetting(.audio(stream.index))
                }
            }
            // Only the on-device player owns the sound, so only it can move it.
            if controller.onDevice != nil {
                Divider().overlay(Theme.border).padding(.vertical, 6)
                TimingRow(title: "Audio timing", value: controller.audioOffset) { value in
                    controller.setAudioOffset(value)
                    trackMemory.audioOffset = value; saveTrackMemory()
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).playerFocusSection()
    }
    private var subtitleChoices: some View {
        let streams = (playerSettingsItem.mediaSources?.first?.mediaStreams ?? []).filter { $0.type == "Subtitle" && $0.index >= 0 }
        return VStack(alignment: .leading, spacing: 10) {
            #if !os(tvOS)
            Text("Subtitles").font(Theme.font(21, weight: .semibold)).padding(.bottom, 4)
            #endif
            playerChoice("Off", selected: selectedPlayerOptions.subtitleIndex == -1,
                         preferred: !streams.contains(where: { $0.index == selectedPlayerOptions.subtitleIndex })) { changePlayerSetting(.subtitles(-1)) }
            ForEach(streams, id: \.index) { stream in
                playerChoice(trackLanguage(stream), detail: trackDetail(stream, among: streams), selected: selectedPlayerOptions.subtitleIndex == stream.index) {
                    changePlayerSetting(.subtitles(stream.index))
                }
            }
            // The app draws these subtitles itself, so it can shift them: always
            // on the on-device player, and for text subtitles in other streams
            // by taking the cues over from AVPlayer.
            if selectedPlayerOptions.subtitleIndex >= 0, controller.onDevice != nil || streamTextSubtitle(streams) {
                Divider().overlay(Theme.border).padding(.vertical, 6)
                TimingRow(title: "Subtitle timing", value: controller.subtitleOffset) { value in
                    controller.subtitleOffset = value
                    trackMemory.subtitleOffset = value; saveTrackMemory()
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).playerFocusSection()
    }
    /// Whether the chosen subtitle reaches AVPlayer as text (not burned into
    /// the picture), so its timing can be moved.
    private func streamTextSubtitle(_ streams: [MediaStream]) -> Bool {
        guard !current.item.isLive, controller.playbackMethod == "DirectPlay" || PlaybackProfile.hardwareHEVC,
              let codec = streams.first(where: { $0.index == selectedPlayerOptions.subtitleIndex })?.codec?.lowercased()
        else { return false }
        return PlaybackProfile.manifestSubtitleFormats.contains(codec)
    }
    private func trackDetail(_ stream: MediaStream, among streams: [MediaStream]) -> String? {
        // Keep single tracks clean, but retain enough information to distinguish
        // commentary, codec or accessibility variants in the same language.
        guard streams.filter({ trackLanguage($0) == trackLanguage(stream) }).count > 1 else { return nil }
        return stream.displayTitle ?? [stream.codec?.uppercased(), stream.channels.map { "\($0) channels" }].compactMap { $0 }.joined(separator: " · ")
    }
    private var playbackInformation: some View {
        VStack(alignment: .leading, spacing: 16) {
            let method = controller.playbackMethod
            playbackFact("Playback", controller.deliveryDescription)
            if let bitrate = controller.resolvedSource?.bitrate, bitrate > 0 {
                playbackFact("Source bitrate", String(format: "%.1f Mbps", Double(bitrate) / 1_000_000))
            }
            if method == "Transcode" {
                playbackFact("Conversion reason", controller.conversionReasons.isEmpty ? "Not reported by server" : controller.conversionReasons.joined(separator: "; "))
            }
            playbackFact("Quality mode", automaticQuality ? "Auto" + (adaptive?.reason.map { " · " + $0 } ?? "") : "Fixed")
            playbackFact("Quality limit", "\((controller.resolvedOptions ?? current.options).bitrate / 1_000_000) Mbps")
            if let size = controller.player.currentItem?.presentationSize, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                playbackFact("Playing resolution", "\(Int(size.width)) × \(Int(size.height))")
            }
            if let event = controller.player.currentItem?.accessLog()?.events.last {
                if event.indicatedBitrate.isFinite, event.indicatedBitrate > 0 {
                    playbackFact("Stream bitrate", String(format: "%.1f Mbps", event.indicatedBitrate / 1_000_000))
                }
                if event.observedBitrate.isFinite, event.observedBitrate > 0 {
                    playbackFact("Network delivery", String(format: "%.1f Mbps", event.observedBitrate / 1_000_000))
                }
                if event.numberOfDroppedVideoFrames >= 0 { playbackFact("Dropped frames", String(event.numberOfDroppedVideoFrames)) }
            }
            let source = playerSettingsItem.quality(audioIndex: controller.resolvedOptions?.audioIndex)
            if !source.badges.isEmpty {
                Text("Source file").font(Theme.font(Theme.isTV ? 22 : 16, weight: .semibold)).padding(.top, 8)
                Text(source.badges.joined(separator: " · ")).foregroundStyle(Theme.muted)
                Text("Source formats can differ from playback output.")
                    .font(Theme.font(Theme.isTV ? 18 : 12)).foregroundStyle(Theme.muted)
            }
        }.font(Theme.font(Theme.isTV ? 22 : 15)).padding(.vertical, 12)
            .accessibilityIdentifier("player-playback-information")
            #if os(tvOS)
            .focusable()
            .playerOptionsDefaultFocus()
            #endif
    }
    private func playbackFact(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(title).foregroundStyle(Theme.muted).fixedSize()
                Spacer(minLength: 12)
                Text(value).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(Theme.muted)
                Text(value)
            }
        }.accessibilityElement(children: .combine)
    }
    private func channelProgramTitle(_ channel: MediaItem) -> String? {
        guard let liveChannelsFetchedAt, (0..<120).contains(liveClock.timeIntervalSince(liveChannelsFetchedAt)),
              channel.currentProgram?.isAiring(at: liveClock) == true else { return nil }
        return channel.currentProgram?.name
    }
    private var filteredLiveChannels: [MediaItem] {
        let query = channelQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return liveChannels.filter { channel in
            let program = channelProgramTitle(channel) ?? ""
            return query.isEmpty || (channel.name + " " + (channel.channelNumber ?? "") + " " + program).localizedCaseInsensitiveContains(query)
        }
    }
    private var liveChannelFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let program = liveProgram {
                Text("Now · " + program.name).font(Theme.font(Theme.isTV ? 23 : 17, weight: .semibold))
                if let schedule = program.schedule {
                    Text("\(schedule.start.formatted(date: .omitted, time: .shortened)) – \(schedule.end.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(Theme.muted)
                }
            }
            if let guide = liveGuide, guide.channelID == current.item.id,
               (0..<120).contains(liveClock.timeIntervalSince(guide.fetchedAt)) {
                let upcoming = guide.programs.filter { ($0.schedule?.start ?? .distantPast) > liveClock }
                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Coming up on this channel").font(Theme.font(Theme.isTV ? 24 : 17, weight: .semibold))
                        ForEach(Array(upcoming.prefix(4).enumerated()), id: \.offset) { _, program in
                            if let schedule = program.schedule {
                                HStack(alignment: .top, spacing: 14) {
                                    Text(schedule.start, style: .time).foregroundStyle(Theme.muted)
                                    Text(program.name).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(Theme.font(Theme.isTV ? 22 : 14)).accessibilityElement(children: .combine)
                            }
                        }
                    }.padding(.vertical, 8).accessibilityIdentifier("live-channel-schedule")
                }
            }
            TextField("Find a channel", text: $channelQuery).modifier(ServerFieldInput())
                .accessibilityLabel("Find a channel")
                .playerOptionsDefaultFocus()
            if channelLoading { ProgressView("Loading channels…") }
            if let channelError {
                Text(channelError).foregroundStyle(Theme.muted)
                Button("Try again") { channelRetry += 1 }.buttonStyle(ZoroButtonStyle())
            }
            LazyVStack(spacing: 8) {
                ForEach(filteredLiveChannels) { channel in
                    playerChoice([channel.channelNumber, channel.name].compactMap { $0 }.joined(separator: " · "),
                                 detail: channelProgramTitle(channel),
                                 selected: channel.id == current.item.id) {
                        guard !switchingEpisode, !controller.loading, !controller.isPreparing else { return }
                        queuedChannel = channel.id == current.item.id ? nil : channel
                        customPanel = nil
                    }.disabled(queuedChannel != nil)
                }
            }
            if !channelLoading && channelError == nil && liveChannels.isEmpty {
                Text("No channels are available for this account.").foregroundStyle(Theme.muted)
            } else if !channelLoading && !liveChannels.isEmpty && filteredLiveChannels.isEmpty {
                Text("No matching channels.").foregroundStyle(Theme.muted)
            }
        }
    }
    private func loadLiveChannels() async {
        guard let client = model.client else { return }
        let loadID = UUID(), generation = model.generation
        channelLoadID = loadID; channelLoading = true; channelError = nil
        defer { if channelLoadID == loadID { channelLoading = false } }
        do {
            let snapshot = try await client.liveTVSnapshot()
            guard !Task.isCancelled, !closingPlayer, generation == model.generation,
                  channelLoadID == loadID, customPanel == .channels else { return }
            var seen = Set<String>()
            liveChannels = snapshot.channels.filter { $0.isLive && !$0.id.isEmpty && seen.insert($0.id).inserted }
            liveChannelsFetchedAt = snapshot.fetchedAt
        } catch {
            guard !Task.isCancelled, generation == model.generation, channelLoadID == loadID else { return }
            channelError = "Channels could not load. Your current broadcast can keep playing."
        }
    }
    private func trackLanguage(_ stream: MediaStream) -> String {
        let language = stream.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? stream.language ?? "Track \(stream.index)"
        return language + (stream.isHearingImpaired == true ? " · CC" : stream.isForced == true ? " · Forced" : "")
    }
    private func playerChoice(_ title: String, detail: String? = nil, selected: Bool = false, symbol: String? = nil, preferred: Bool? = nil,
                              action: @escaping () -> Void) -> some View {
        PlayerOptionRow(title: title, detail: detail, selected: selected, symbol: symbol, preferred: preferred, action: action)
    }

}

#if os(tvOS)
private struct PlayerOptionsFocusClaimKey: EnvironmentKey {
    static let defaultValue: Binding<Bool>? = nil
}
private extension EnvironmentValues {
    var playerOptionsFocusClaim: Binding<Bool>? {
        get { self[PlayerOptionsFocusClaimKey.self] }
        set { self[PlayerOptionsFocusClaimKey.self] = newValue }
    }
}
private struct PlayerOptionsDefaultFocus: ViewModifier {
    @Environment(\.playerOptionsFocusClaim) private var claim
    @FocusState private var focused: Bool
    let preferred: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if let claim {
            content.focused($focused).task(id: preferred) {
                guard preferred, !claim.wrappedValue else { return }
                claim.wrappedValue = true
                // Move focus out of AVKit only after this option is mounted.
                // A shared claim prevents later selections from stealing focus.
                await Task.yield()
                guard !Task.isCancelled else { return }
                focused = true
            }
        } else { content }
    }
}
#endif

extension View {
    /// Only active inside a TV player panel. Request initial focus once a useful
    /// control is ready, including asynchronously loaded season choices.
    @ViewBuilder func playerOptionsDefaultFocus(_ preferred: Bool = true) -> some View {
        #if os(tvOS)
        modifier(PlayerOptionsDefaultFocus(preferred: preferred))
        #else
        self
        #endif
    }
}

/// Contextual TV panels stay above AVKit's transport; iOS keeps its own surface.
private struct PlayerOptionsSurface<Content: View>: View {
    let title: String
    let context: String
    var wide = false
    var fullWidth = false
    var liveSchedule = false
    var controlsClearance: CGFloat = 0.22
    let close: () -> Void
    @ViewBuilder let content: (CGFloat) -> Content
    @FocusState private var closeFocused: Bool
    #if os(tvOS)
    @State private var contentHeight: CGFloat = 100
    @State private var requestedContentFocus = false
    #endif
    var body: some View {
        GeometryReader { geometry in
            #if os(tvOS)
            let bottom = geometry.size.height * min(0.55, max(0, controlsClearance)) + 8
            let width = min(fullWidth ? geometry.size.width - 96 : liveSchedule ? 680.0 : wide ? 1180.0 : 560.0, geometry.size.width - 96)
            let height = min(fullWidth ? 460.0 : liveSchedule ? geometry.size.height - bottom - 48 : wide ? 560.0 : 600.0, max(180, geometry.size.height - bottom - 48))
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture(perform: close)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Text(title).font(Theme.font(26, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        Button(action: close) {
                            Image(systemName: "xmark").font(.system(size: 20))
                                .frame(width: 44, height: 44)
                        }.buttonStyle(FlatOptionStyle()).focused($closeFocused)
                            .accessibilityLabel("Return to playback")
                            .accessibilityIdentifier("player-options-close")
                    }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                        .focusSection()
                    Divider().overlay(.white.opacity(0.12))
                    ScrollView {
                        content(width - 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
                    }.frame(height: min(max(1, contentHeight), height - 65))
                        .frame(maxWidth: .infinity).focusSection()
                // A maxHeight frame expands the short panel to the full cap,
                // centering the header and leaving blank space above and below.
                }.frame(width: width)
                    .environment(\.playerOptionsFocusClaim, $requestedContentFocus)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.16), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .padding(.trailing, fullWidth ? 48 : 64).padding(.bottom, bottom)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(Theme.font(Theme.isTV ? 36 : 24, weight: .semibold, relativeTo: .title2))
                        if !context.isEmpty { Text(context).font(Theme.font(Theme.isTV ? 22 : 13)).foregroundStyle(Theme.muted).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: Theme.isTV ? 26 : 20, weight: .regular))
                            .frame(width: Theme.target, height: Theme.target)
                    }.buttonStyle(FlatOptionStyle()).focused($closeFocused)
                        .accessibilityLabel("Return to playback").accessibilityIdentifier("player-options-close")
                }.padding(.horizontal, Theme.isTV ? 48 : 20).padding(.top, Theme.isTV ? 32 : 12).padding(.bottom, Theme.isTV ? 28 : 16)
                    .playerFocusSection()
                ScrollView {
                    content(max(0, geometry.size.width - (Theme.isTV ? 96 : 40)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.isTV ? 48 : 20).padding(.bottom, Theme.isTV ? 40 : 24)
                }
                // Options may occupy only the left column, while Close is at
                // the far right. Extend the focus target across the body so
                // Down from Close reaches quality, tracks, episodes or channels.
                .frame(maxWidth: .infinity)
                .playerFocusSection()
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.background.ignoresSafeArea())
            #endif
        }.foregroundStyle(Theme.text).tint(Theme.jade).preferredColorScheme(.dark)
            .accessibilityIdentifier("player-options-surface")
            #if os(tvOS)
            .ignoresSafeArea(.container)
            .onExitCommand(perform: close)
            #endif
    }
}

private struct PlayerOptionRow: View {
    let title: String
    var detail: String? = nil
    var selected = false
    var symbol: String? = nil
    var preferred: Bool? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.isTV ? 20 : 12) {
                Image(systemName: "checkmark").foregroundStyle(Theme.jade)
                    .frame(width: 24).opacity(selected ? 1 : 0)
                if let symbol { Image(systemName: symbol).frame(width: 24) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(Theme.font(Theme.isTV ? 24 : 18, weight: selected ? .semibold : .regular))
                    if let detail, !detail.isEmpty, detail != title {
                        Text(detail).font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }.padding(.horizontal, 8).padding(.vertical, Theme.isTV ? 6 : 8)
                .frame(maxWidth: .infinity, minHeight: Theme.isTV ? 56 : 52, alignment: .leading)
                .foregroundStyle(selected ? Theme.text : Theme.muted)
        }.buttonStyle(FlatOptionStyle()).accessibilityAddTraits(selected ? .isSelected : [])
            .playerOptionsDefaultFocus(preferred ?? selected)
    }
}

private extension View {
    @ViewBuilder func playerFocusSection() -> some View {
        #if os(tvOS)
        self.focusSection()
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct SystemTVPlayerMenuState: Equatable {
    let episodes: Bool
    var chapters = false
    let live: Bool
    let canSeek: Bool
    let canGoLive: Bool
    let enabled: Bool
    let grouped: Bool
}

/// Apple's real transport UI owns remote input. Zorofin keeps its existing
/// negotiated stream, session reporting and server-only options behind it.
private struct SystemTVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    /// The on-device player sets the TV's picture mode before its item loads.
    let engineSwitchesDisplay: Bool
    let title: String
    let subtitle: String
    let overview: String
    let allowsPiP: Bool
    let menuState: SystemTVPlayerMenuState
    let blocked: Bool
    let action: (CustomPlayerAction) -> Void
    let close: () -> Void
    let onPiPChange: (Bool) -> Void
    let navigate: (Double) -> Double?
    let contentClearance: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = AVPlayerViewController()
        view.delegate = context.coordinator
        view.showsPlaybackControls = true
        // Info views and track controls are separate AVKit features. Suppress
        // native subtitle language choices without requiring captions. The
        // complete Jellyfin selector still provides every track and Off.
        view.playbackControlsIncludeInfoViews = false
        view.infoViewActions = []
        view.allowedSubtitleOptionLanguages = []
        view.requiresFullSubtitles = false
        view.speeds = []
        view.transportBarIncludesTitleView = true
        view.videoGravity = .resizeAspect
        context.coordinator.startDiagnostics(view)
        updateUIViewController(view, context: context)
        return view
    }
    func updateUIViewController(_ view: AVPlayerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.action = action; coordinator.close = close
        coordinator.onPiPChange = onPiPChange; coordinator.navigate = navigate
        coordinator.contentClearance = contentClearance
        view.appliesPreferredDisplayCriteriaAutomatically = !engineSwitchesDisplay
        if view.player !== player { view.player = player }
        view.allowsPictureInPicturePlayback = allowsPiP
        view.requiresLinearPlayback = !menuState.canSeek
        view.isSkipBackwardEnabled = menuState.canSeek
        view.isSkipForwardEnabled = menuState.canSeek
        if coordinator.menuState != menuState {
            coordinator.menuState = menuState
            view.transportBarCustomMenuItems = coordinator.makeMenus(menuState)
            view.speeds = []
        }
        coordinator.updateMetadata(on: player.currentItem, title: title, subtitle: subtitle, overview: overview)
        view.view.isUserInteractionEnabled = !blocked
        view.view.accessibilityElementsHidden = blocked
        if coordinator.blocked && !blocked {
            view.setNeedsFocusUpdate()
            view.updateFocusIfNeeded()
        }
        coordinator.blocked = blocked
        coordinator.traceControls("update")
        // Position panels just above the public native layout guide. The last
        // visible measurement stays available while transport is hidden.
        view.view.layoutIfNeeded()
        let frame = view.unobscuredContentGuide.layoutFrame
        let height = view.view.bounds.height
        if height > 0, frame.height > 0 {
            coordinator.reportClearance(max(0, (height - frame.maxY) / height))
        }
    }
    static func dismantleUIViewController(_ view: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.stopDiagnostics()
        view.delegate = nil
        view.transportBarCustomMenuItems = []
        view.player = nil
        coordinator.action = { _ in }; coordinator.close = {}
        coordinator.onPiPChange = { _ in }; coordinator.navigate = { _ in nil }
        coordinator.contentClearance = { _ in }
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        var action: (CustomPlayerAction) -> Void = { _ in }
        var close: () -> Void = {}
        var onPiPChange: (Bool) -> Void = { _ in }
        var navigate: (Double) -> Double? = { _ in nil }
        var contentClearance: (CGFloat) -> Void = { _ in }
        private var reportedClearance: CGFloat = -1
        var menuState: SystemTVPlayerMenuState?
        var blocked = false
        private var closing = false
        private weak var metadataItem: AVPlayerItem?
        private var metadataValues: [String] = []

        // Opt-in device investigation only. Public API state, without titles,
        // media IDs, URLs, account data or private UIKit implementation names.
        private weak var diagnosticView: AVPlayerViewController?
        private var diagnosticState = ""
        private var transportVisible: Bool?
        func startDiagnostics(_ view: AVPlayerViewController) {
            guard ProcessInfo.processInfo.arguments.contains("--diagnose-tv-controls") else { return }
            diagnosticView = view
            for name in [UIFocusSystem.didUpdateNotification, UIFocusSystem.movementDidFailNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(traceFocus(_:)), name: name, object: nil)
            }
            traceControls("created")
        }
        func stopDiagnostics() {
            guard diagnosticView != nil else { return }
            traceControls("removed")
            NotificationCenter.default.removeObserver(self, name: UIFocusSystem.didUpdateNotification, object: nil)
            NotificationCenter.default.removeObserver(self, name: UIFocusSystem.movementDidFailNotification, object: nil)
            diagnosticView = nil
        }
        @objc private func traceFocus(_ notification: Notification) {
            guard let view = diagnosticView, view.viewIfLoaded?.window != nil else { return }
            let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            let previous = context?.previouslyFocusedView?.isDescendant(of: view.view) ?? false
            let next = context?.nextFocusedView?.isDescendant(of: view.view) ?? false
            let failed = notification.name == UIFocusSystem.movementDidFailNotification
            traceControls("focus failed=\(failed) heading=\(context?.focusHeading.rawValue ?? 0) previousInPlayer=\(previous) nextInPlayer=\(next)")
        }
        func traceControls(_ event: String) {
            guard let view = diagnosticView else { return }
            let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView
            let state = "rate=\(view.player?.rate ?? -1) timeControl=\(view.player?.timeControlStatus.rawValue ?? -1) item=\(view.player?.currentItem?.status.rawValue ?? -1) blocked=\(blocked) interaction=\(view.view.isUserInteractionEnabled) attached=\(view.view.window != nil) hasFocus=\(focused != nil) focusInPlayer=\(focused?.isDescendant(of: view.view) ?? false) controls=\(view.showsPlaybackControls) transport=\(transportVisible.map(String.init) ?? "unknown") linear=\(view.requiresLinearPlayback) menus=\(menuState?.enabled ?? false)"
            guard event != "update" || state != diagnosticState else { return }
            diagnosticState = state
            let line = "ZorofinTVControls \(ProcessInfo.processInfo.systemUptime) \(event) \(state)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willTransitionToVisibilityOfTransportBar visible: Bool,
                                  with coordinator: any AVPlayerViewControllerAnimationCoordinator) {
            transportVisible = visible
            traceControls("transport")
        }

        func reportClearance(_ fraction: CGFloat) {
            guard fraction.isFinite, abs(fraction - reportedClearance) > 0.002 else { return }
            reportedClearance = fraction
            Task { @MainActor [weak self] in self?.contentClearance(fraction) }
        }

        func makeMenus(_ state: SystemTVPlayerMenuState) -> [UIMenuElement] {
            func control(_ title: String, _ symbol: String, _ command: CustomPlayerAction) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: symbol),
                         attributes: state.enabled ? [] : [.disabled]) { [weak self] _ in
                    guard let self, !self.blocked, !self.closing else { return }
                    self.action(command)
                }
            }
            var items: [UIMenuElement] = []
            if state.live { items.append(control("Channels & guide", "list.bullet.rectangle", .panel(.channels))) }
            else if state.episodes { items.append(control("Seasons & episodes", "rectangle.stack", .panel(.episodes))) }
            if state.live && state.canGoLive { items.append(control("Go live", "forward.end.fill", .goLive)) }
            if state.chapters { items.append(control("Chapters", "list.bullet.rectangle", .panel(.chapters))) }
            if !state.live { items.append(control("Audio & subtitles", "captions.bubble", .panel(.tracks))) }
            items.append(control("Quality", "slider.horizontal.3", .panel(.quality)))
            items.append(control("Playback info", "info.circle", .panel(.information)))
            return items
        }
        func updateMetadata(on item: AVPlayerItem?, title: String, subtitle: String, overview: String) {
            guard let item else { return }
            let values = [title, subtitle, overview]
            guard metadataItem !== item || metadataValues != values else { return }
            metadataItem = item; metadataValues = values
            let identifiers: [AVMetadataIdentifier] = [.commonIdentifierTitle, .iTunesMetadataTrackSubTitle, .commonIdentifierDescription]
            var metadata = item.externalMetadata.filter { entry in
                guard let identifier = entry.identifier else { return true }
                return !identifiers.contains(identifier)
            }
            for (identifier, value) in zip(identifiers, values) where !value.isEmpty {
                let entry = AVMutableMetadataItem()
                entry.identifier = identifier; entry.extendedLanguageTag = "und"; entry.value = value as NSString
                metadata.append(entry)
            }
            item.externalMetadata = metadata
        }
        func playerViewControllerShouldDismiss(_ playerViewController: AVPlayerViewController) -> Bool {
            guard !blocked, !closing else { return false }
            closing = true
            close() // The owning SwiftUI cover performs stop/report cleanup.
            return false
        }
        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  timeToSeekAfterUserNavigatedFrom oldTime: CMTime, to targetTime: CMTime) -> CMTime {
            guard targetTime.seconds.isFinite, !blocked, !closing,
                  let seconds = navigate(targetTime.seconds) else { return oldTime }
            return CMTime(seconds: seconds, preferredTimescale: 600)
        }
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { onPiPChange(true) }
        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) { onPiPChange(false) }
        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) { onPiPChange(true) }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) { onPiPChange(false) }
        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }
    }
}
#endif

private struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let allowsPiP: Bool
    let onPiPChange: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPiPChange: onPiPChange) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player; controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        #if os(iOS)
        controller.allowsPictureInPicturePlayback = allowsPiP
        #endif
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        context.coordinator.onPiPChange = onPiPChange
        #if os(iOS)
        controller.allowsPictureInPicturePlayback = allowsPiP
        #endif
    }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onPiPChange: (Bool) -> Void
        init(onPiPChange: @escaping (Bool) -> Void) { self.onPiPChange = onPiPChange }
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { onPiPChange(true) }
        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) { onPiPChange(false) }
        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) { onPiPChange(true) }
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) { onPiPChange(false) }
    }
}

/// Fixed-size targets leave room for the episode picker on narrow phones.
private struct PlayerIconStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Theme.text)
            .background(Theme.panel, in: Circle())
            .overlay(Circle().stroke(focused ? Color.white : Theme.border, lineWidth: focused ? 3 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Custom player candidate

enum CustomPlayerAction {
    case close, togglePlayback, pause, pauseForScrub, resumeAfterScrub, pictureInPicture, replay, goLive
    case videoSizing(PlayerVideoSizing)
    case routePicker(Bool)
    case skip(Int), seek(Double, resume: Bool), panel(PlayerPanel)
}

private enum PlayerControlFocus: Hashable { case play, surface, timeline, quality, tracks, information }

#if DEBUG
/// Read-only hosted-test evidence; omitted from Release. The probe observes the
/// real controls and never supplies a phase, timer or interaction override.
struct PlayerControlsSnapshot: Equatable, Sendable {
    let phase: PlayerPhase
    let visible: Bool
    let viewport: CGSize
}
private struct PlayerControlsObserverKey: EnvironmentKey {
    static var defaultValue: (@MainActor @Sendable (PlayerControlsSnapshot) -> Void)? { nil }
}
extension EnvironmentValues {
    var playerControlsObserver: (@MainActor @Sendable (PlayerControlsSnapshot) -> Void)? {
        get { self[PlayerControlsObserverKey.self] }
        set { self[PlayerControlsObserverKey.self] = newValue }
    }
}
#endif

#if os(tvOS)
/// Even the platform's plain style draws a focused TV background. The hidden
/// remote target must remain transparent while still receiving Select.
private struct HiddenPlayerSurfaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
#endif

/// Presentation-only controls. The engine receives intents, never drag updates.
private struct CustomPlayerControls: View {
    #if DEBUG
    @Environment(\.playerControlsObserver) private var controlsObserver
    #endif
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    #if os(iOS)
    private struct SkipFeedback: Identifiable {
        let id = UUID()
        let seconds: Int
    }
    @State private var skipFeedback: SkipFeedback?
    #endif
    #if os(tvOS)
    @FocusState private var focusedControl: PlayerControlFocus?
    @State private var preferredControlFocus: PlayerControlFocus?
    private var focusTarget: PlayerControlFocus? {
        guard !interaction.locked, interaction.panel == nil else { return nil }
        if !interaction.controlsVisible { return .surface }
        return phase == .preparing || phase == .failed ? nil : .play
    }
    #endif
    let title: String
    let subtitle: String
    let phase: PlayerPhase
    let timeline: PlayerTimeline
    let skipBack: Int
    let skipForward: Int
    let hasEpisodes: Bool
    var hasTracks = false
    var showsRoutes = false
    var pipAvailable = false
    var isLive = false
    /// Chapters and scrub thumbnails, when this title has them.
    var extras: PlayerExtrasModel?
    @Binding var interaction: PlayerInteraction
    let action: (CustomPlayerAction) -> Void
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    private var displayedTime: Double { interaction.scrubPosition ?? timeline.position }
    private var playing: Bool { phase == .playing || phase == .buffering }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 520
            let shallow = geometry.size.height < 420
            let inset: CGFloat = Theme.isTV ? 48 : compact ? 20 : 32
            let landscape = geometry.size.width > geometry.size.height
            // iOS already reserves the camera and home-indicator safe areas.
            // In landscape, fill only the gap to our minimum margins instead
            // of adding another full inset inside those reserved areas.
            let controlInsets = !Theme.isTV && landscape
                ? EdgeInsets(top: max(0, 12 - geometry.safeAreaInsets.top),
                             leading: max(0, 16 - geometry.safeAreaInsets.leading),
                             bottom: max(0, 12 - geometry.safeAreaInsets.bottom),
                             trailing: max(0, 16 - geometry.safeAreaInsets.trailing))
                : EdgeInsets(top: Theme.isTV ? 32 : 16, leading: inset,
                             bottom: Theme.isTV ? 32 : 16, trailing: inset)
            ZStack {
                #if os(tvOS)
                // Keep this target mounted across chrome transitions. Removing
                // the focused button during the fade can lose remote commands.
                Group {
                    // A real Button receives Select without a preceding swipe.
                    // No press/focus callback reveals chrome before activation.
                    Button {
                        if interaction.pauseFromHiddenSurface(now: now) { action(.pause) }
                    } label: {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HiddenPlayerSurfaceStyle()).focusEffectDisabled()
                    .disabled(interaction.controlsVisible || interaction.locked)
                    .accessibilityHidden(interaction.controlsVisible || interaction.locked)
                    .focused($focusedControl, equals: .surface)
                    .accessibilityLabel("Pause")
                    .accessibilityIdentifier("player-hidden-pause")
                }
                #else
                PlayerGestureSurface(enabled: !voiceOver && interaction.acceptsSurfaceGestures,
                    tap: { interaction.toggleControls(now: now) }, intent: performSurfaceGesture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement()
                    .accessibilityLabel("Show playback controls").accessibilityAddTraits(.isButton)
                    .accessibilityAction { interaction.reveal(now: now) }
                    .accessibilityHidden(interaction.controlsVisible || interaction.locked)
                #endif
                if interaction.locked {
                    VStack {
                        Spacer()
                        Button { interaction.setLocked(false, now: now) } label: { Label("Unlock", systemImage: "lock.open").frame(minWidth: 48, minHeight: 48) }
                            .buttonStyle(CinematicButtonStyle()).padding(24)
                    }
                } else if interaction.controlsVisible {
                    LinearGradient(stops: [.init(color: .black.opacity(0.72), location: 0), .init(color: .clear, location: 0.3),
                                           .init(color: .clear, location: 0.55), .init(color: .black.opacity(0.88), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(.container).allowsHitTesting(false)
                    transport
                        #if os(iOS)
                        .disabled(interaction.scrubPosition != nil)
                        #endif
                        .position(x: geometry.size.width / 2, y: geometry.size.height * (shallow ? 0.42 : 0.5))
                    VStack(spacing: shallow ? 4 : 12) {
                        HStack(alignment: .top, spacing: compact ? 8 : 14) {
                            icon("chevron.left", label: "Close player", size: 20, weight: .regular, compact: true) { action(.close) }
                                .accessibilityIdentifier("player-back")
                            VStack(alignment: .leading, spacing: 5) {
                                Text(title).font(Theme.font(Theme.isTV ? 28 : 17, weight: .semibold)).lineLimit(shallow ? 1 : 2)
                                if !subtitle.isEmpty && !(shallow && textSize.isAccessibilitySize) { Text(subtitle).font(Theme.font(Theme.isTV ? 20 : 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(2) }
                            }.padding(.top, 8)
                            Spacer(minLength: 0)
                            HStack(alignment: .center, spacing: Theme.isTV ? 16 : 10) {
                                if isLive {
                                    headerAction("list.bullet.rectangle", label: "Channels and guide") { open(.channels) }
                                        .disabled(phase == .preparing || interaction.scrubPosition != nil)
                                        .accessibilityIdentifier("player-channels")
                                } else if hasEpisodes {
                                    headerAction("rectangle.stack", label: "Seasons and episodes") { open(.episodes) }
                                        .disabled(interaction.scrubPosition != nil)
                                        .accessibilityIdentifier("player-episodes")
                                }
                                if showsRoutes {
                                    PlayerRoutePicker(onPresentation: { action(.routePicker($0)) })
                                        .frame(width: headerActionSize, height: headerActionSize)
                                        .background(.black.opacity(0.45), in: Circle())
                                        .accessibilityLabel("AirPlay").disabled(interaction.scrubPosition != nil)
                                }
                                if pipAvailable {
                                    headerAction("pip.enter", label: "Picture in Picture") { action(.pictureInPicture) }
                                        .disabled(interaction.scrubPosition != nil)
                                }
                            }.fixedSize(horizontal: true, vertical: false)
                        }
                        #if os(tvOS)
                        .focusSection()
                        #endif
                        Spacer(minLength: shallow ? 0 : 12)
                        VStack(spacing: Theme.isTV ? 18 : shallow ? 4 : 8) {
                            if phase == .preparing || phase == .buffering {
                                HStack(spacing: 10) { ProgressView().tint(.white); Text(phase == .preparing ? (isLive ? "Connecting to channel…" : "Preparing video…") : "Buffering…") }
                                    .font(Theme.font(Theme.isTV ? 20 : 13))
                            }
                            #if os(tvOS)
                            // A separate options row keeps horizontal timeline
                            // gestures away from audio/subtitle navigation.
                            if isLive {
                                if timeline.canTimeShiftLive { timelineControl.focusSection() }
                            } else { progressControls.focusSection() }
                            HStack(spacing: 24) {
                                if isLive { liveStatus }
                                Spacer(minLength: 0)
                                utilityControls
                            }.focusSection()
                            #else
                            if isLive {
                                if timeline.canTimeShiftLive { timelineControl }
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 16) { liveStatus; Spacer(minLength: 8); utilityControls }
                                    VStack(alignment: .trailing, spacing: 4) {
                                        liveStatus.frame(maxWidth: .infinity, alignment: .leading)
                                        utilityControls
                                    }
                                }
                            } else {
                                // Landscape is one inline strip. Narrow windows move
                                // the three icons together below the scrubber, never
                                // stacking icon/text labels or shrinking touch targets.
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: Theme.isTV ? 32 : 20) {
                                        progressControls
                                        utilityControls
                                    }
                                    VStack(alignment: .trailing, spacing: 4) {
                                        progressControls
                                        utilityControls
                                    }
                                }
                            }
                            #endif
                        }
                    }.padding(controlInsets)
                    .transition(.opacity)
                }
                #if os(iOS)
                if let skipFeedback {
                    Label("\(abs(skipFeedback.seconds))s", systemImage: skipFeedback.seconds < 0 ? "gobackward" : "goforward")
                        .font(Theme.font(17, weight: .semibold)).monospacedDigit()
                        .padding(16).background(.black.opacity(0.65), in: Capsule())
                        .position(x: geometry.size.width * (skipFeedback.seconds < 0 ? 0.22 : 0.78), y: geometry.size.height * 0.5)
                        .allowsHitTesting(false).accessibilityHidden(true).transition(.opacity)
                }
                #endif
            }.foregroundStyle(.white)
                #if os(iOS)
                .frame(width: geometry.size.width, height: geometry.size.height)
                #endif
                .animation(reduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.18), value: interaction.controlsVisible)
                #if DEBUG
                .onChange(of: PlayerControlsSnapshot(phase: phase, visible: interaction.controlsVisible, viewport: geometry.size), initial: true) { _, snapshot in
                    controlsObserver?(snapshot)
                }
                #endif
        }
        #if os(tvOS)
        // Own the TV margins once instead of adding them to system overscan.
        // Video sizing is independent; iOS controls still respect safe areas.
        .ignoresSafeArea(.container)
        .task(id: focusTarget) {
            guard let target = focusTarget else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            // Keep a focused surface when controls disappear so Play/Pause and
            // Back still arrive before the viewer makes a directional gesture.
            focusedControl = target == .play ? preferredControlFocus ?? target : target
            preferredControlFocus = nil
        }
        #endif
        #if os(iOS)
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            guard !voiceOver, interaction.acceptsSurfaceGestures else { return }
            let sizing = interaction.videoSizing.afterPinch(magnification: Double(value.magnification))
            if sizing != interaction.videoSizing { action(.videoSizing(sizing)) }
        }, including: voiceOver ? .none : .all)
        .task(id: skipFeedback?.id) {
            guard let id = skipFeedback?.id else { return }
            do {
                try await Task.sleep(for: .milliseconds(800)); try Task.checkCancellation()
                guard skipFeedback?.id == id else { return }
                withAnimation(reduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14)) { skipFeedback = nil }
            } catch { }
        }
        #endif
        .onChange(of: phase, initial: true) { _, value in
            interaction.persistentControls = voiceOver
            interaction.update(phase: value, now: now)
        }
        .onChange(of: voiceOver) { _, enabled in interaction.persistentControls = enabled; interaction.reveal(now: now) }
        .task(id: interaction.hideDeadline) {
            guard let deadline = interaction.hideDeadline else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, deadline - now)))
                try Task.checkCancellation()
                interaction.tick(now: now)
            } catch { }
        }
        #if os(tvOS)
        .onPlayPauseCommand {
            if !interaction.locked && interaction.panel == nil {
                activateTransport()
            }
        }
        .onMoveCommand { direction in
            guard !interaction.controlsVisible else { return }
            // Down opens options directly, without crossing the seek surface.
            preferredControlFocus = direction == .down ? .quality : .play
            interaction.reveal(now: now)
        }
        #endif
    }
    #if os(iOS)
    private func performSurfaceGesture(_ intent: PlayerSurfaceGestureIntent) {
        guard !voiceOver, interaction.acceptsSurfaceGestures else { return }
        if intent == .dismiss { action(.close); return }
        guard timeline.canSeek, phase != .preparing, phase != .failed, phase != .ended else { return }
        let seconds = intent == .backward ? -skipBack : skipForward
        action(.skip(seconds)); interaction.reveal(now: now)
        withAnimation(reduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14)) {
            skipFeedback = SkipFeedback(seconds: seconds)
        }
    }
    #endif
    private var transport: some View {
        HStack(spacing: Theme.isTV ? 36 : 38) {
            if !isLive || timeline.canTimeShiftLive {
                icon("gobackward.\(skipBack)", label: "Back \(skipBack) seconds", size: 30) { action(.skip(-skipBack)); interaction.reveal(now: now) }
                    .disabled(interaction.scrubPosition != nil || !timeline.canSeek || phase == .preparing || phase == .failed || phase == .ended)
            }
            Button { activateTransport() } label: {
                Image(systemName: phase == .ended ? "arrow.counterclockwise" : playing && interaction.scrubPosition == nil ? "pause.fill" : "play.fill")
                    .font(.system(size: Theme.isTV ? 38 : 34, weight: .semibold)).frame(width: Theme.isTV ? 84 : 72, height: Theme.isTV ? 84 : 72)
                    .contentShape(Rectangle())
            }.buttonStyle(CinematicButtonStyle(emphasis: true, onFocus: { interaction.reveal(now: now) }, onPress: controlPressed)).accessibilityLabel(phase == .ended ? (isLive ? "Reconnect" : "Watch again") : playing && interaction.scrubPosition == nil ? "Pause" : "Play")
                .disabled(phase == .preparing || phase == .failed)
                .accessibilityIdentifier("player-play-pause")
                #if os(tvOS)
                .focused($focusedControl, equals: .play)
                #endif
            if !isLive || timeline.canTimeShiftLive {
                icon("goforward.\(skipForward)", label: "Forward \(skipForward) seconds", size: 30) { action(.skip(skipForward)); interaction.reveal(now: now) }
                    .disabled(interaction.scrubPosition != nil || !timeline.canSeek || phase == .preparing || phase == .failed || phase == .ended)
            }
        }
        #if os(tvOS)
        // A full-width focus section lets Down reach transport from either
        // corner of the header, without changing the centered visual layout.
        .frame(maxWidth: .infinity).focusSection()
        #endif
    }
    private func activateTransport() {
        if interaction.scrubPosition != nil {
            if let result = interaction.finishScrub(now: now, play: Theme.isTV) {
                action(.seek(result.position, resume: result.resume))
            }
        } else { action(phase == .ended ? .replay : .togglePlayback) }
        interaction.reveal(now: now)
    }
    private var timelineControl: some View {
        let bar = CustomTimelineBar(timeline: timeline, position: displayedTime, active: interaction.scrubPosition != nil,
            begin: { target in if interaction.beginScrub(at: target) { action(.pauseForScrub) } },
            move: { interaction.moveScrub(to: $0) },
            commit: {
                if let result = interaction.finishScrub(now: now, play: Theme.isTV) { action(.seek(result.position, resume: result.resume)) }
            }, cancel: {
                if interaction.cancelScrub(now: now) { action(.resumeAfterScrub) }
            }, adjust: { target in action(.seek(target, resume: playing)); interaction.reveal(now: now) },
            focusChanged: { focused in if focused { interaction.reveal(now: now) } }, extras: extras)
        #if os(tvOS)
        var remoteBar = bar
        remoteBar.remoteFocus = $focusedControl
        remoteBar.preview = { seconds in
            let beginning = interaction.scrubPosition == nil
            if interaction.previewRemoteSeek(by: seconds, timeline: timeline, timelineFocused: focusedControl == .timeline), beginning {
                action(.pauseForScrub)
            }
        }
        return remoteBar.disabled(!timeline.canSeek || phase == .preparing || phase == .failed || phase == .ended)
        #else
        return bar.disabled(!timeline.canSeek || phase == .preparing || phase == .failed || phase == .ended)
        #endif
    }
    private var progressControls: some View {
        HStack(spacing: Theme.isTV ? 16 : 8) {
            Text(PlayerTimeline.timeLabel(displayedTime)).fixedSize()
            timelineControl.frame(minWidth: Theme.isTV ? 240 : 100)
            Text(timeline.duration.map { "−" + PlayerTimeline.timeLabel(max(0, $0 - displayedTime)) } ?? "--:--").fixedSize()
        }.font(Theme.font(Theme.isTV ? 18 : 12)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
    }
    private var liveStatus: some View {
        HStack(spacing: 10) {
            Label(phase == .paused ? "Paused" : timeline.isAtLiveEdge ? "Live" : "Live TV", systemImage: "circle.fill")
                .foregroundStyle(Theme.jade).fixedSize()
            if let delay = timeline.behindLive, delay > 3 {
                Text(PlayerTimeline.timeLabel(delay) + " behind").fixedSize()
            }
            if timeline.liveEdgeTarget != nil && (!timeline.isAtLiveEdge || phase == .paused) {
                icon("forward.end.fill", label: "Go live", size: 22, compact: true) { action(.goLive); interaction.reveal(now: now) }
                    .disabled(phase == .preparing || phase == .failed || phase == .ended)
            }
        }.font(Theme.font(Theme.isTV ? 18 : 12)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
    }
    private var utilityControls: some View {
        HStack(spacing: Theme.isTV ? 24 : 8) {
            icon("slider.horizontal.3", label: "Quality", size: 22, compact: true) { open(.quality) }
                .disabled(phase == .preparing).accessibilityIdentifier("player-quality")
                #if os(tvOS)
                .focused($focusedControl, equals: .quality)
                #endif
            if extras?.hasChapters == true {
                icon("list.bullet.rectangle", label: "Chapters", size: 22, compact: true) { open(.chapters) }
                    .disabled(phase == .preparing).accessibilityIdentifier("player-chapters")
            }
            icon("captions.bubble", label: "Subtitles and audio", size: 22, compact: true) { open(.tracks) }
                .disabled(!hasTracks || phase == .preparing).accessibilityIdentifier("player-subtitles")
                #if os(tvOS)
                .focused($focusedControl, equals: .tracks)
                #endif
            icon("info.circle", label: "Playback info", size: 22, compact: true) { open(.information) }
                .accessibilityIdentifier("player-info")
                #if os(tvOS)
                .focused($focusedControl, equals: .information)
                #endif
                #if os(iOS)
                .accessibilityAction(named: Text(interaction.videoSizing == .fit ? "Zoom to fill screen" : "Fit clear of camera cutout")) {
                    action(.videoSizing(interaction.videoSizing == .fit ? .fill : .fit))
                }
                #endif
        }.fixedSize(horizontal: true, vertical: false)
        #if os(iOS)
        .disabled(interaction.scrubPosition != nil)
        #endif
    }
    // tvOS gives AVRoutePickerView an 80-point native control; match its neighbors.
    private var headerActionSize: CGFloat { Theme.isTV ? 80 : 48 }
    private func headerAction(_ symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: Theme.isTV ? 36 : 23, weight: .regular))
                .frame(width: headerActionSize, height: headerActionSize)
                .contentShape(Circle())
        }.buttonStyle(CinematicButtonStyle(emphasis: true,
            onFocus: { interaction.reveal(now: now) }, onPress: controlPressed))
            .accessibilityLabel(label)
    }
    private func controlPressed(_ pressed: Bool) { interaction.setControlPressed(pressed, now: now) }
    private func open(_ panel: PlayerPanel) {
        #if os(tvOS)
        preferredControlFocus = focusedControl
        #endif
        action(.panel(panel)); interaction.reveal(now: now)
    }
    private func icon(_ symbol: String, label: String, size: CGFloat = 24, weight: Font.Weight = .medium,
                      compact: Bool = false, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: size, weight: weight))
                .frame(width: Theme.isTV ? 64 : compact ? 44 : 48, height: Theme.isTV ? 64 : compact ? 44 : 48)
                .background(size >= 30 ? .black.opacity(0.45) : .clear, in: Circle())
                .contentShape(Rectangle())
        }.buttonStyle(CinematicButtonStyle(onFocus: { interaction.reveal(now: now) }, onPress: controlPressed))
            .accessibilityLabel(label)
    }
}

private struct CustomTimelineBar: View {
    let timeline: PlayerTimeline
    let position: Double
    let active: Bool
    let begin: (Double) -> Void
    let move: (Double) -> Void
    let commit: () -> Void
    let cancel: () -> Void
    let adjust: (Double) -> Void
    let focusChanged: (Bool) -> Void
    var extras: PlayerExtrasModel?
    var remoteFocus: FocusState<PlayerControlFocus?>.Binding?
    var preview: ((Double) -> Void)?
    @FocusState private var fallbackFocus: PlayerControlFocus?
    private var focused: Bool { (remoteFocus ?? $fallbackFocus).wrappedValue == .timeline }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: active || focused ? 5 : 3)
                ForEach(Array(timeline.buffered.enumerated()), id: \.offset) { _, range in
                    Rectangle().fill(.white.opacity(0.25))
                        .frame(width: max(0, width * (timeline.fraction(at: range.end) - timeline.fraction(at: range.start))), height: 3)
                        .offset(x: width * timeline.fraction(at: range.start))
                }
                Capsule().fill(Theme.jade).frame(width: max(0, width * timeline.fraction(at: position)), height: active || focused ? 5 : 3)
                if let extras, extras.hasChapters { ChapterMarks(timeline: timeline, chapters: extras.chapters).frame(height: 48) }
                Circle().fill(Theme.jade).frame(width: active || focused ? 16 : 10, height: active || focused ? 16 : 10)
                    .offset(x: max(0, min(width - 16, width * timeline.fraction(at: position) - 8)))
            }.frame(height: 48).contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                // The frame, time and chapter under the thumb while scrubbing.
                if active, let extras, !timeline.isLive {
                    let half: CGFloat = Theme.isTV ? 168 : 96
                    ScrubPreviewCard(extras: extras, seconds: position)
                        .alignmentGuide(.leading) { $0.width / 2 }
                        .alignmentGuide(.top) { $0.height + (Theme.isTV ? 34 : 6) }
                        .offset(x: min(max(half, width * timeline.fraction(at: position)), max(half, width - half)))
                        .transition(.opacity)
                }
            }
            #if os(iOS)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard let target = timeline.time(at: value.location.x / width) else { return }
                if !active { begin(target) }
                move(target)
            }.onEnded { _ in commit() })
            #else
            .focusable().focused(remoteFocus ?? $fallbackFocus, equals: .timeline)
            .onMoveCommand { direction in
                switch direction {
                case .left, .right: preview?(direction == .left ? -10 : 10)
                case .up, .down:
                    if active { cancel() }
                    (remoteFocus ?? $fallbackFocus).wrappedValue = direction == .up ? .play : .quality
                default: break
                }
            }
            .onTapGesture { if active { commit() } else { begin(position) } }
            .overlay(alignment: .top) {
                if focused {
                    Text(active ? "Select to play · Back to cancel · Down for options" : "Left or right to seek · Down for options")
                        .font(Theme.font(18)).foregroundStyle(.white.opacity(0.85))
                        .fixedSize().offset(y: -24).allowsHitTesting(false)
                }
            }
            .accessibilityHint("Left or right previews a position. Select or Play/Pause plays it. Back cancels. Down opens the options row.")
            .onChange(of: focused) { _, value in
                focusChanged(value)
                if !value && active { cancel() }
            }
            #endif
            .accessibilityElement().accessibilityLabel(timeline.isLive ? "Live rewind position" : "Playback position")
            .accessibilityValue(timeline.isLive ? PlayerTimeline.timeLabel(max(0, (timeline.liveEdgeTarget ?? position) - position)) + " behind live" : PlayerTimeline.timeLabel(position))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(position + 10)
                case .decrement: adjust(position - 10)
                @unknown default: break
                }
            }
        }.frame(height: 48)
    }
}

private struct CinematicButtonStyle: ButtonStyle {
    var emphasis = false
    var onFocus: (() -> Void)?
    var onPress: ((Bool) -> Void)?
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .contentShape(Rectangle())
            .background((focused ? Color.white.opacity(0.2) : emphasis ? .black.opacity(0.45) : .clear), in: RoundedRectangle(cornerRadius: emphasis ? 40 : 10))
            .overlay(RoundedRectangle(cornerRadius: emphasis ? 40 : 10).stroke(focused ? Color.white : .clear, lineWidth: 2))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.4)
            .onChange(of: focused) { _, value in if value { onFocus?() } }
            .onChange(of: configuration.isPressed) { _, value in onPress?(value) }
    }
}

#if os(iOS)
/// Attached only to the video background, underneath buttons and the timeline.
/// One-finger pans cannot commit after a two-finger pinch takes over.
private struct PlayerGestureSurface: UIViewRepresentable {
    let enabled: Bool
    let tap: () -> Void
    let intent: (PlayerSurfaceGestureIntent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear
        let coordinator = context.coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2; doubleTap.numberOfTouchesRequired = 1
        let singleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        singleTap.numberOfTouchesRequired = 1
        singleTap.require(toFail: doubleTap); singleTap.require(toFail: pan); doubleTap.require(toFail: pan)
        coordinator.recognizers = [pan, doubleTap, singleTap]
        for recognizer in coordinator.recognizers {
            recognizer.delegate = coordinator; view.addGestureRecognizer(recognizer)
        }
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.enabled = enabled; coordinator.tap = tap; coordinator.intent = intent
        for recognizer in coordinator.recognizers where recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.enabled = false; coordinator.tap = {}; coordinator.intent = { _ in }
        for recognizer in coordinator.recognizers {
            recognizer.isEnabled = false; recognizer.delegate = nil; view.removeGestureRecognizer(recognizer)
        }
        coordinator.recognizers = []
    }
    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = false
        var tap: () -> Void = {}
        var intent: (PlayerSurfaceGestureIntent) -> Void = { _ in }
        var recognizers: [UIGestureRecognizer] = []
        private var panStart: CGPoint?

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard enabled, recognizer.state == .ended else { return }
            tap()
        }
        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard enabled, recognizer.state == .ended, let view = recognizer.view else { return }
            if let value = PlayerSurfaceGestureIntent.doubleTap(x: recognizer.location(in: view).x, width: view.bounds.width) { intent(value) }
            else { tap() }
        }
        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            guard enabled, let view = recognizer.view else { panStart = nil; return }
            let translation = recognizer.translation(in: view)
            if recognizer.state == .began {
                let point = recognizer.location(in: view)
                panStart = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
                return
            }
            if recognizer.state == .cancelled || recognizer.state == .failed { panStart = nil; return }
            guard recognizer.state == .ended, let start = panStart else { return }
            defer { panStart = nil }
            if let value = PlayerSurfaceGestureIntent.swipe(horizontal: translation.x, vertical: translation.y,
                width: view.bounds.width, height: view.bounds.height,
                startX: start.x, startY: start.y) { intent(value) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Our own tap/pan dependencies remain exclusive. Ancestor pinch
            // recognition stays available; the one-touch pan cancels on touch 2.
            !recognizers.contains(where: { $0 === otherGestureRecognizer })
        }
    }
}
#endif

private extension PlayerVideoSizing {
    var ignoredVideoSafeAreaEdges: Edge.Set {
        #if os(iOS)
        // Fit keeps the picture clear of Dynamic Island/notches; Fill uses the
        // entire display. Changing this modifier preserves the rendering view.
        self == .fill ? .all : []
        #else
        // Video must not inherit TV overscan padding in either sizing mode.
        .all
        #endif
    }
}

/// Rendering and controls are separate. No private AVKit view hierarchy is altered.
private struct CustomVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    let features: CustomVideoFeatures
    let allowsPiP: Bool
    let sizing: PlayerVideoSizing
    let onPiPChange: (Bool) -> Void
    func makeCoordinator() -> CustomVideoFeatures { features }
    func makeUIView(context: Context) -> PlayerSurfaceHostView {
        let host = PlayerSurfaceHostView()
        configure(host)
        return host
    }
    func updateUIView(_ host: PlayerSurfaceHostView, context: Context) { configure(host) }
    private func configure(_ host: PlayerSurfaceHostView) {
        let layer = host.video.playerLayer
        layer.videoGravity = sizing == .fill ? .resizeAspectFill : .resizeAspect
        if layer.player !== player { layer.player = player }
        host.fill = sizing == .fill
        features.connect(layer: layer, allowed: allowsPiP, onChange: onPiPChange)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerSurfaceHostView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(0, height))
    }
    static func dismantleUIView(_ host: PlayerSurfaceHostView, coordinator: CustomVideoFeatures) {
        coordinator.disconnect(); host.video.playerLayer.player = nil
    }
}

/// Owns where the picture sits. SwiftUI only has to place this host somewhere
/// over the player; the video view itself is laid out from the hosting
/// window's current bounds and safe area each time UIKit lays out, the scene
/// geometry changes, or the size classes change (iPhone Plus/Pro Max phones
/// switch to a regular width in landscape). Fit keeps the picture inside the
/// window's safe area; Fill covers the whole window.
private final class PlayerSurfaceHostView: UIView {
    let video = PlayerLayerView()
    var fill = false { didSet { if fill != oldValue { setNeedsLayout() } } }
    private var geometryObservation: NSKeyValueObservation?
    #if os(iOS)
    private var traitRegistration: (any UITraitChangeRegistration)?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        video.backgroundColor = .black
        video.clipsToBounds = true
        addSubview(video)
        #if os(iOS)
        traitRegistration = registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (view: PlayerSurfaceHostView, _) in
            view.relayout()
        }
        #endif
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        geometryObservation?.invalidate(); geometryObservation = nil
        #if os(iOS)
        if let scene = window?.windowScene {
            geometryObservation = scene.observe(\.effectiveGeometry, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.relayout() }
            }
        }
        #endif
        relayout()
    }
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let target = targetFrame()
        if video.frame != target { video.frame = target }
    }
    private func relayout() {
        setNeedsLayout()
        layoutIfNeeded()
    }
    /// The window's visible area in this view's coordinates. Before the view
    /// is in a window, its own bounds are the best available answer.
    private func targetFrame() -> CGRect {
        guard let window else { return bounds }
        #if os(iOS)
        let area = fill ? window.bounds : window.bounds.inset(by: window.safeAreaInsets)
        #else
        let area = window.bounds
        #endif
        let frame = convert(area, from: window)
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return bounds }
        return frame
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

#if DEBUG
/// Offline fixture: exercises the actual SwiftUI controls without account or media writes.
struct PlayerDesignPreview: View {
    @Environment(\.dismiss) private var dismiss
    var canDismiss = false
    var isLive = false
    @State private var livePreviewChannel = "Metro Sports"
    @State private var previewRewind = true
    @State private var previewModel: AppModel = {
        let model = AppModel(); model.showDemo(); return model
    }()
    @State private var interaction = PlayerInteraction()
    @State private var phase: PlayerPhase = .paused
    @State private var position = 784.0
    @State private var previewQuality = 40
    @State private var previewSubtitles = false
    @State private var previewAudio = "English"
    @State private var panel: PlayerPanel?
    @State private var episode = PreviewLibrary.episodes[2]
    @State private var showNotes = false
    private var timeline: PlayerTimeline {
        .init(localPosition: position, duration: isLive ? nil : 2700, isLive: isLive,
              seekable: isLive ? (previewRewind ? [.init(start: 600, end: 1000)!] : []) : [.init(start: 0, end: 2700)!],
              buffered: isLive ? [] : [.init(start: 0, end: min(2700, position + 180))!])
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewArtwork(title: isLive ? "Live event" : "Orbital", seed: isLive ? "live-player" : "orbital-player", showTitle: false)
                .aspectRatio(16 / 9, contentMode: interaction.videoSizing == .fill ? .fill : .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .ignoresSafeArea(.container, edges: interaction.videoSizing.ignoredVideoSafeAreaEdges)
            CustomPlayerControls(title: isLive ? (livePreviewChannel == "Metro Sports" ? "Harbor vs Summit" : "Evening headlines") : "Orbital",
                                 subtitle: isLive ? livePreviewChannel + " · Fictional broadcast" : episode.episodeLabel, phase: phase, timeline: timeline,
                                 skipBack: 10, skipForward: 30, hasEpisodes: !isLive, hasTracks: true, isLive: isLive,
                                 interaction: $interaction, action: act)
                .disabled(panel != nil).allowsHitTesting(panel == nil).accessibilityHidden(panel != nil)
        }.foregroundStyle(.white)
            .environment(previewModel)
            .overlay {
                if panel != nil {
                    PlayerOptionsSurface(title: previewPanelTitle, context: isLive ? livePreviewChannel : "Orbital", wide: panel == .episodes || panel == .channels, close: { panel = nil }) { width in
                        previewPanelFields(width: width)
                    }.environment(previewModel)
                }
            }
            .onChange(of: panel) { previous, selected in
                if previous != nil, selected == nil, interaction.closePanel(now: ProcessInfo.processInfo.systemUptime) { phase = .playing }
            }
            #if os(tvOS)
            .onExitCommand {
                switch interaction.backAction {
                case .closePanel: panel = nil
                case .cancelScrub:
                    if interaction.cancelScrub(now: ProcessInfo.processInfo.systemUptime) { phase = .playing }
                case .unlock: interaction.setLocked(false, now: ProcessInfo.processInfo.systemUptime)
                case .hideControls: interaction.toggleControls(now: ProcessInfo.processInfo.systemUptime)
                case .closePlayer: act(.close)
                }
            }
            #endif
            .alert("Player design preview", isPresented: $showNotes) {
                Button("Keep exploring", role: .cancel) { }
            } message: { Text("Launch normally to return to your library. This screen previews the custom controls with fictional media.") }
    }
    private var previewPanelTitle: String {
        switch panel {
        case .channels: "Channels & guide"
        case .episodes: "Seasons & episodes"
        case .tracks: "Audio & subtitles"
        case .quality: "Quality"
        default: "Playback info"
        }
    }
    @ViewBuilder private func previewPanelFields(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if panel == .channels {
                Text("Fictional channels · no tuner is opened").foregroundStyle(Theme.muted)
                ForEach(["Metro Sports", "World Events"], id: \.self) { name in
                    PlayerOptionRow(title: name, selected: livePreviewChannel == name) {
                        livePreviewChannel = name; position = 998
                        _ = interaction.closePanel(now: ProcessInfo.processInfo.systemUptime, replacing: true)
                        panel = nil; phase = .playing
                    }
                }
            } else if panel == .episodes {
                SeasonEpisodeBrowser(context: episode, playSelection: { selected in
                    episode = selected; position = selected.resumeTicks > 0 ? MediaTime.seconds(ticks: selected.resumeTicks) : 0
                    _ = interaction.closePanel(now: ProcessInfo.processInfo.systemUptime, replacing: true)
                    panel = nil; phase = .playing
                })
            } else if panel == .quality {
                ForEach([120, 80, 60, 40, 20, 12, 8, 4, 2], id: \.self) { value in
                    PlayerOptionRow(title: "\(value) Mbps", selected: previewQuality == value) { previewQuality = value }
                }
            } else if panel == .tracks {
                let layout = width >= 620 ? AnyLayout(HStackLayout(alignment: .top, spacing: 36)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
                layout {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Audio").font(Theme.font(Theme.isTV ? 28 : 21, weight: .semibold))
                        ForEach(["English", "Japanese"], id: \.self) { language in
                            PlayerOptionRow(title: language, selected: previewAudio == language) { previewAudio = language }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).playerFocusSection()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Subtitles").font(Theme.font(Theme.isTV ? 28 : 21, weight: .semibold))
                        ForEach([false, true], id: \.self) { enabled in
                            PlayerOptionRow(title: enabled ? "English (CC)" : "Off", selected: previewSubtitles == enabled) { previewSubtitles = enabled }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).playerFocusSection()
                }
            } else {
                Text("Offline player preview").font(.headline)
                Text("Fictional artwork and playback state. No server is contacted and no viewing history is changed.").foregroundStyle(Theme.muted)
                Text("Quality limit: \(previewQuality) Mbps")
                Text("Subtitles: " + (previewSubtitles ? "English (CC)" : "Off"))
            }
        }
    }

    private func act(_ action: CustomPlayerAction) {
        switch action {
        case .close: if canDismiss { dismiss() } else { showNotes = true }
        case .togglePlayback: phase = phase == .playing || phase == .buffering ? .paused : .playing
        case .replay: position = isLive ? 998 : 0; phase = .playing
        case .goLive: if let target = timeline.liveEdgeTarget { position = target; phase = .playing }
        case .pause, .pauseForScrub: phase = .paused
        case .resumeAfterScrub: phase = .playing
        case .videoSizing(let sizing): interaction.setVideoSizing(sizing, now: ProcessInfo.processInfo.systemUptime)
        case .pictureInPicture, .routePicker: break
        case .skip(let seconds):
            if case .local(let target) = timeline.seek(to: position + Double(seconds)) { position = target }
        case .seek(let target, let resume):
            if case .local(let target) = timeline.seek(to: target) { position = target }
            phase = resume ? .playing : .paused
        case .panel(let selected): _ = interaction.open(selected); if !isLive && selected != .information { phase = .paused }; panel = selected
        }
    }
}
#endif


@MainActor @Observable private final class CustomVideoFeatures: NSObject, AVPictureInPictureControllerDelegate {
    var possible = false
    @ObservationIgnored private var pip: AVPictureInPictureController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private weak var playerLayer: AVPlayerLayer?
    @ObservationIgnored private var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var revision = UUID()
    func connect(layer: AVPlayerLayer, allowed: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        guard allowed, AVPictureInPictureController.isPictureInPictureSupported() else { disconnect(); return }
        guard playerLayer !== layer || pip == nil else { return }
        disconnect(); self.onChange = onChange; playerLayer = layer
        let controller = AVPictureInPictureController(playerLayer: layer)
        pip = controller; controller?.delegate = self
        let expectedRevision = revision
        observation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] source, _ in
            let possible = source.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, revision == expectedRevision else { return }
                self.possible = possible
            }
        }
    }
    func toggle() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        else if pip.isPictureInPicturePossible { onChange?(true); pip.startPictureInPicture() }
    }
    func disconnect() {
        revision = UUID()
        observation?.invalidate(); observation = nil
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        pip?.delegate = nil; pip = nil; playerLayer = nil; possible = false
        onChange?(false); onChange = nil
    }
    private func updatePiP(_ active: Bool, identity: ObjectIdentifier) {
        guard let pip, ObjectIdentifier(pip) == identity else { return }
        onChange?(active)
    }
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let identity = ObjectIdentifier(controller)
        Task { @MainActor [weak self] in self?.updatePiP(true, identity: identity) }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let identity = ObjectIdentifier(controller)
        Task { @MainActor [weak self] in self?.updatePiP(false, identity: identity) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let identity = ObjectIdentifier(controller)
        Task { @MainActor [weak self] in self?.updatePiP(false, identity: identity) }
    }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        let identity = ObjectIdentifier(controller)
        Task { @MainActor [weak self] in
            // The player remains mounted during PiP; never claim a restore after dismantling.
            completionHandler(self?.pip.map { ObjectIdentifier($0) == identity } == true && self?.playerLayer?.player != nil)
        }
    }
}

private struct PlayerRoutePicker: UIViewRepresentable {
    let onPresentation: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPresentation) }
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(); view.tintColor = .white; view.activeTintColor = UIColor(Theme.jade)
        view.prioritizesVideoDevices = true; view.delegate = context.coordinator; return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        context.coordinator.onPresentation = onPresentation
        view.isUserInteractionEnabled = context.environment.isEnabled
    }
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var onPresentation: (Bool) -> Void
        init(_ callback: @escaping (Bool) -> Void) { onPresentation = callback }
        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) { onPresentation(true) }
        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) { onPresentation(false) }
    }
}
