import Foundation
import Testing
@testable import ZorofinCore

@Suite("Player background gestures") struct PlayerSurfaceGestureTests {
    private func swipe(_ x: Double, _ y: Double, startX: Double = 400, startY: Double = 200) -> PlayerSurfaceGestureIntent? {
        .swipe(horizontal: x, vertical: y, width: 800, height: 400, startX: startX, startY: startY)
    }
    @Test func deliberateDirectionsHaveDistinctIntents() {
        #expect(swipe(-120, 10) == .backward)
        #expect(swipe(120, -10) == .forward)
        #expect(swipe(10, 110) == .dismiss)
    }
    @Test func jitterDiagonalsAndUpwardMotionDoNothing() {
        for (x, y) in [(10.0, 0.0), (0, 35), (100, 80), (150, 160), (0, -130)] {
            #expect(swipe(x, y) == nil)
        }
    }
    @Test func systemEdgesAndInvalidGeometryDoNotDismissOrSeek() {
        #expect(swipe(120, 0, startX: 2) == nil)
        #expect(swipe(-120, 0, startX: 798) == nil)
        #expect(swipe(0, 110, startY: 2) == nil)
        #expect(swipe(0, 110, startY: 399) == nil)
        #expect(swipe(.nan, 0) == nil)
        #expect(swipe(0, .infinity) == nil)
        #expect(PlayerSurfaceGestureIntent.swipe(horizontal: 100, vertical: 0, width: 0, height: 400, startX: 0, startY: 200) == nil)
    }
    @Test func doubleTapsReserveTheCenterForControls() {
        #expect(PlayerSurfaceGestureIntent.doubleTap(x: 100, width: 800) == .backward)
        #expect(PlayerSurfaceGestureIntent.doubleTap(x: 700, width: 800) == .forward)
        #expect(PlayerSurfaceGestureIntent.doubleTap(x: 400, width: 800) == nil)
        #expect(PlayerSurfaceGestureIntent.doubleTap(x: -.infinity, width: 800) == nil)
        #expect(PlayerSurfaceGestureIntent.doubleTap(x: 10, width: .nan) == nil)
    }
    @Test func lockedPanelsScrubbingPressedButtonsAndClosedPlayersBlockSurfaceInput() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        #expect(state.acceptsSurfaceGestures)
        state.setLocked(true, now: 1); #expect(!state.acceptsSurfaceGestures)
        state.setLocked(false, now: 2); state.open(.quality); #expect(!state.acceptsSurfaceGestures)
        _ = state.closePanel(now: 3)
        let began = state.beginScrub(at: 100)
        #expect(began && !state.acceptsSurfaceGestures)
        _ = state.cancelScrub(now: 4)
        state.setControlPressed(true, now: 5); #expect(!state.acceptsSurfaceGestures)
        state.setControlPressed(false, now: 6); #expect(state.acceptsSurfaceGestures)
        state.close(); #expect(!state.acceptsSurfaceGestures)
    }
}

@Suite("Custom player timeline") struct PlayerTimelineTests {
    private func range(_ start: Double, _ end: Double) -> PlayerTimeRange { .init(start: start, end: end)! }
    @Test func resumedTranscodeUsesAbsoluteTime() {
        let t = PlayerTimeline(localPosition: 25, duration: 2400, offset: 1200,
                               seekable: [range(0, 600)], buffered: [range(20, 55)])
        #expect(t.position == 1225 && t.remaining == 1175)
        #expect(t.seek(to: 1300) == .local(seconds: 100))
        #expect(t.buffered == [range(1220, 1255)])
        #expect(t.seek(to: 300) == .unavailable)
        #expect(t.seek(to: 300, allowRestart: true) == .restart(absoluteSeconds: 300))
    }
    @Test func directPlaybackNeedsNoOffset() {
        let t = PlayerTimeline(localPosition: 10, duration: 3600, seekable: [range(0, 3600)])
        #expect(t.seek(to: 60) == .local(seconds: 60))
        #expect(t.seek(to: -10) == .local(seconds: 0))
        #expect(t.seek(to: 10000) == .local(seconds: 3600))
        #expect(t.time(at: 0.5) == 1800 && t.fraction(at: 1800) == 0.5)
    }
    @Test func invalidTimesNeverReachTheEngine() {
        #expect(PlayerTimeRange(start: .nan, end: 10) == nil)
        #expect(PlayerTimeRange(start: 0, end: .infinity) == nil)
        #expect(PlayerTimeRange(start: 10, end: 1) == nil)
        let t = PlayerTimeline(localPosition: .nan, duration: .infinity, offset: .nan)
        #expect(t.position == 0 && t.duration == nil && t.bounds == nil && !t.canSeek)
        #expect(t.time(at: .nan) == nil && t.fraction(at: .nan) == 0)
        #expect(t.seek(to: .infinity, allowRestart: true) == .unavailable)
    }
    @Test func rangesMergeOnlyWhenTheyTouchOrOverlap() {
        let t = PlayerTimeline(localPosition: 0, duration: 100,
                               seekable: [range(50, 60), range(0, 10), range(9, 20), range(20, 30)])
        #expect(t.seekable == [range(0, 30), range(50, 60)])
        #expect(t.seek(to: 40) == .unavailable)
        #expect(t.seek(to: 40, allowRestart: true) == .restart(absoluteSeconds: 40))
    }
    @Test func liveWithoutDVRNeverInventsASeekRange() {
        let t = PlayerTimeline(localPosition: 200, duration: nil, isLive: true)
        #expect(t.bounds == nil && t.remaining == nil && !t.canSeek && !t.isAtLiveEdge)
        #expect(t.seek(to: 100, allowRestart: true) == .unavailable)
    }
    @Test func liveDVRUsesMovingWindowAndDoesNotSeekIntoGaps() {
        let t = PlayerTimeline(localPosition: 298, duration: nil, isLive: true,
                               seekable: [range(100, 150), range(200, 300)])
        #expect(t.bounds == range(100, 300) && t.isAtLiveEdge)
        #expect(t.time(at: 0) == 100 && t.time(at: 1) == 300)
        #expect(t.seek(to: 5) == .local(seconds: 100))
        #expect(t.seek(to: 185) == .local(seconds: 200))
        #expect(t.seek(to: 900) == .local(seconds: 298))
    }
    @Test func staleLiveScrubReclampsToNewWindow() {
        let initial = PlayerTimeline(localPosition: 150, duration: nil, isLive: true, seekable: [range(100, 200)])
        let selected = initial.time(at: 0)!
        let moved = PlayerTimeline(localPosition: 210, duration: nil, isLive: true, seekable: [range(160, 260)])
        #expect(moved.seek(to: selected) == .local(seconds: 160))
    }
    @Test func rangesPastDurationAreClippedAndEmptyOnesDropped() {
        let t = PlayerTimeline(localPosition: 900, duration: 100, seekable: [range(80, 150), range(200, 220)])
        #expect(t.position == 100 && t.remaining == 0 && t.seekable == [range(80, 100)])
    }
    @Test func displayTimeSupportsLongFilmsAndUnknownValues() {
        #expect(PlayerTimeline.timeLabel(59.9) == "0:59")
        #expect(PlayerTimeline.timeLabel(3661) == "1:01:01")
        #expect(PlayerTimeline.timeLabel(.infinity) == "--:--")
        #expect(PlayerTimeline.timeLabel(-1) == "--:--")
    }
}

@Suite("Custom player interaction") struct PlayerInteractionTests {
    @Test func zoomChangesPresentationWithoutPausingOrStartingASeek() {
        var state = PlayerInteraction()
        state.update(phase: .playing, now: 0); state.tick(now: 4)
        #expect(state.videoSizing == .fit && !state.controlsVisible)
        let outward = state.videoSizing.afterPinch(magnification: 1.4)
        let enlarged = state.setVideoSizing(outward, now: 5)
        #expect(enlarged)
        #expect(state.videoSizing == .fill && state.controlsVisible)
        #expect(state.phase == .playing && state.scrubPosition == nil && state.panel == nil)
        #expect(state.hideDeadline == 9)
        // Repeated outward pinches must not flip back to Fit or extend the timer.
        let repeated = state.setVideoSizing(state.videoSizing.afterPinch(magnification: 1.5), now: 6)
        #expect(!repeated)
        #expect(state.videoSizing == .fill && state.hideDeadline == 9)
        let restored = state.setVideoSizing(state.videoSizing.afterPinch(magnification: 0.6), now: 7)
        #expect(restored)
        #expect(state.videoSizing == .fit && state.phase == .playing)
    }
    @Test func lockedPanelScrubAndClosedStatesRejectZoom() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        state.setLocked(true, now: 1)
        let locked = state.setVideoSizing(.fill, now: 2)
        #expect(!locked && state.locked)
        state.setLocked(false, now: 3); state.open(.tracks)
        let panel = state.setVideoSizing(.fill, now: 4)
        #expect(!panel && state.panel == .tracks && state.panelResumeIntent)
        _ = state.closePanel(now: 5)
        let beganScrub = state.beginScrub(at: 100)
        #expect(beganScrub)
        let scrub = state.setVideoSizing(.fill, now: 6)
        #expect(!scrub && state.scrubPosition == 100 && state.scrubResumeIntent)
        _ = state.cancelScrub(now: 7); state.close()
        let closed = state.setVideoSizing(.fill, now: 8)
        #expect(!closed && state.videoSizing == .fit && state.isClosed)
    }
    @Test func invalidOrIncidentalPinchesPreserveEitherVideoMode() {
        for sizing in [PlayerVideoSizing.fit, .fill] {
            for scale in [Double.nan, .infinity, -.infinity, -1, 0, 0.97, 1, 1.03] {
                #expect(sizing.afterPinch(magnification: scale) == sizing)
            }
        }
    }
    @Test func controlsHideOnlyAfterIdlePlayingDeadline() {
        var s = PlayerInteraction()
        s.update(phase: .playing, now: 10)
        s.tick(now: 13.9); #expect(s.controlsVisible)
        s.tick(now: 14); #expect(!s.controlsVisible)
        s.toggleControls(now: 15); #expect(s.controlsVisible && s.hideDeadline == 19)
    }
    @Test(arguments: [PlayerPhase.preparing, .paused, .buffering, .ended, .failed])
    func essentialControlsStayVisible(phase: PlayerPhase) {
        var s = PlayerInteraction()
        s.update(phase: phase, now: 0); s.tick(now: 100)
        #expect(s.controlsVisible && s.hideDeadline == nil)
    }
    @Test func centerPressPausesHiddenPlaybackOnceWithoutDirectionalInput() {
        var state = PlayerInteraction()
        state.update(phase: .playing, now: 0)
        state.tick(now: 4)
        #expect(!state.controlsVisible)
        let firstPress = state.pauseFromHiddenSurface(now: 5)
        #expect(firstPress)
        #expect(state.controlsVisible)
        let repeatedPress = state.pauseFromHiddenSurface(now: 5)
        #expect(!repeatedPress)
        state.update(phase: .paused, now: 5)
        state.tick(now: 100)
        #expect(state.controlsVisible && state.hideDeadline == nil)
    }
    @Test func hiddenCenterActionDoesNotStealPanelScrubLockOrVisibleSelect() {
        var state = PlayerInteraction()
        state.update(phase: .playing, now: 0)
        let visiblePress = state.pauseFromHiddenSurface(now: 1)
        #expect(!visiblePress)
        state.open(.quality)
        let panelPress = state.pauseFromHiddenSurface(now: 2)
        #expect(!panelPress)
        _ = state.closePanel(now: 3)
        let beganScrub = state.beginScrub(at: 120)
        #expect(beganScrub)
        let scrubPress = state.pauseFromHiddenSurface(now: 4)
        #expect(!scrubPress)
        #expect(state.scrubPosition == 120)
        _ = state.cancelScrub(now: 5)
        state.setLocked(true, now: 6)
        let lockedPress = state.pauseFromHiddenSurface(now: 7)
        #expect(!lockedPress)
        state.close()
        let closedPress = state.pauseFromHiddenSurface(now: 8)
        #expect(!closedPress)
    }
    @Test func interactionResetsTheHideDeadline() {
        var s = PlayerInteraction()
        s.update(phase: .playing, now: 0); s.reveal(now: 3); s.tick(now: 4)
        #expect(s.controlsVisible); s.tick(now: 7); #expect(!s.controlsVisible)
    }
    @Test func aPressedControlCannotDisappearAtTheIdleDeadline() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        state.setControlPressed(true, now: 3.9)
        state.tick(now: 4); state.tick(now: 20)
        #expect(state.controlPressed && state.controlsVisible && state.hideDeadline == nil)
        state.setControlPressed(false, now: 21)
        #expect(state.hideDeadline == 25)
        state.tick(now: 25); #expect(!state.controlsVisible)
    }
    @Test(arguments: [PlayerPhase.preparing, .playing, .paused, .buffering, .ended, .failed])
    func closingIsTerminalEvenWhenPreparationOrTimersFinishLate(_ phase: PlayerPhase) {
        var state = PlayerInteraction(); state.update(phase: phase, now: 0)
        state.close(); state.close()
        state.update(phase: .playing, now: 1); state.reveal(now: 2)
        state.toggleControls(now: 3); state.tick(now: 100)
        state.setControlPressed(true, now: 101); state.setLocked(true, now: 102)
        #expect(state.isClosed && !state.controlsVisible && state.hideDeadline == nil)
        #expect(state.phase == .paused && !state.locked && !state.controlPressed)
        let opened = state.open(.information)
        #expect(!opened && state.panel == nil)
    }
    @Test func closingWhileAPanelIsOpenCannotResumeOnSheetDismiss() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        state.open(.quality); state.update(phase: .paused, now: 1)
        state.close()
        let resume = state.closePanel(now: 2)
        #expect(!resume && !state.panelResumeIntent && state.panel == nil && state.isClosed)
    }
    @Test func closingDiscardsAnUncommittedSeekWithoutResuming() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        _ = state.beginScrub(at: 90); state.moveScrub(to: 120)
        state.close()
        let result = state.finishScrub(now: 1)
        let resume = state.cancelScrub(now: 2)
        let restarted = state.beginScrub(at: 200)
        #expect(result == nil && !resume && !restarted && !state.scrubResumeIntent)
    }
    @Test func backgroundingCancelsAControlPressThatNeverReceivesTouchUp() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        state.setControlPressed(true, now: 1); state.interrupt(now: 2)
        #expect(!state.controlPressed)
        state.update(phase: .playing, now: 3)
        #expect(state.hideDeadline == 7)
        state.tick(now: 7); #expect(!state.controlsVisible)
    }
    @Test func voiceOverKeepsControlsAvailable() {
        var s = PlayerInteraction(); s.persistentControls = true
        s.update(phase: .playing, now: 0); s.toggleControls(now: 10); s.tick(now: 100)
        #expect(s.controlsVisible && s.hideDeadline == nil)
    }
    @Test func panelsPreservePlayingIntentAcrossChanges() {
        var s = PlayerInteraction(); s.update(phase: .playing, now: 0)
        let result1 = s.open(.episodes); #expect(result1); s.update(phase: .paused, now: 1)
        let result2 = s.open(.quality); #expect(result2); s.tick(now: 100)
        #expect(s.controlsVisible && s.panel == .quality)
        let result3 = s.closePanel(now: 101); #expect(result3)
        let result4 = !s.closePanel(now: 102); #expect(result4)
    }
    @Test func openingDuringStartupPreservesPlayIntent() {
        var s = PlayerInteraction()
        let pause = s.open(.episodes); #expect(pause)
        s.update(phase: .paused, now: 1)
        let resume = s.closePanel(now: 2); #expect(resume)
    }
    @Test func interruptedScrubCannotSeekOrResumeOnReturn() {
        var s = PlayerInteraction(); s.update(phase: .playing, now: 0)
        _ = s.beginScrub(at: 50); s.interrupt(now: 1)
        let result = s.finishScrub(now: 2)
        #expect(result == nil && s.phase == .paused)
    }
    @Test func openingPanelFromPauseDoesNotResume() {
        var s = PlayerInteraction(); s.update(phase: .paused, now: 0)
        let result5 = !s.open(.tracks); #expect(result5); let result6 = !s.closePanel(now: 10); #expect(result6)
    }
    @Test func backgroundOrReplacementCannotResumeOldPlayback() {
        var s = PlayerInteraction(); s.update(phase: .playing, now: 0); s.open(.episodes)
        let result7 = !s.closePanel(now: 1, replacing: true); #expect(result7)
        s.update(phase: .playing, now: 2); s.open(.quality); s.interrupt(now: 3)
        let result8 = !s.closePanel(now: 4); #expect(result8)
        s.update(phase: .playing, now: 5); s.open(.tracks)
        let result9 = !s.closePanel(now: 6, active: false); #expect(result9)
    }
    @Test func scrubbingPausesAndCommitsOnceWithOriginalIntent() {
        var s = PlayerInteraction(); s.update(phase: .playing, now: 0)
        let result10 = s.beginScrub(at: 100); #expect(result10); s.update(phase: .paused, now: 1)
        s.moveScrub(to: 200); s.moveScrub(to: .nan); s.tick(now: 100)
        #expect(s.controlsVisible && s.scrubPosition == 200)
        let result = s.finishScrub(now: 101)
        #expect(result?.position == 200 && result?.resume == true)
        let result11 = s.finishScrub(now: 102) == nil; #expect(result11)
    }
    @Test func scrubbingWhilePausedStaysPaused() {
        var s = PlayerInteraction(); s.update(phase: .paused, now: 0); _ = s.beginScrub(at: 10)
        let result12 = s.finishScrub(now: 1)?.resume == false; #expect(result12)
    }
    @Test func returningToAnExternallyPlayingVideoRefreshesPanelIntent() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        state.interrupt(now: 1)
        state.update(phase: .playing, now: 5)
        state.open(.tracks); state.update(phase: .paused, now: 6)
        let resume = state.closePanel(now: 7)
        #expect(resume && state.controlsVisible)
    }
    @Test func remoteScrubCancellationRestoresIntentWithoutASeek() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        _ = state.beginScrub(at: 50); state.update(phase: .paused, now: 1); state.moveScrub(to: 90)
        let resume = state.cancelScrub(now: 2)
        #expect(resume && state.scrubPosition == nil && !state.scrubResumeIntent)
        let duplicate = state.cancelScrub(now: 3); #expect(!duplicate)
        _ = state.beginScrub(at: 100)
        let paused = state.cancelScrub(now: 4); #expect(!paused)
    }
    @Test func lockSuppressesAccidentalInputAndCanAlwaysUnlock() {
        var s = PlayerInteraction(); s.update(phase: .playing, now: 0); s.setLocked(true, now: 1)
        s.toggleControls(now: 2); s.open(.episodes)
        let result13 = !s.beginScrub(at: 10) && s.panel == nil && s.locked && !s.controlsVisible; #expect(result13)
        s.setLocked(false, now: 3)
        #expect(!s.locked && s.controlsVisible)
    }
    @Test func failureOrEndClearsPendingResumeAndScrub() {
        var s = PlayerInteraction(); s.update(phase: .playing, now: 0); s.open(.tracks)
        s.update(phase: .failed, now: 1); let result14 = !s.closePanel(now: 2); #expect(result14)
        s.update(phase: .playing, now: 3); _ = s.beginScrub(at: 100)
        s.update(phase: .ended, now: 4); let result15 = s.finishScrub(now: 5) == nil; #expect(result15)
    }
}

@Suite("Custom player setting changes") struct PlayerSettingTests {
    private func fixture() throws -> MediaItem {
        try Wire.decoder().decode(MediaItem.self, from: Data(#"{"Id":"episode","Name":"Episode","Type":"Episode","RunTimeTicks":27000000000,"MediaSources":[{"MediaStreams":[{"Index":1,"Type":"Audio","Language":"eng"},{"Index":2,"Type":"Audio","Language":"spa"},{"Index":3,"Type":"Subtitle","Language":"eng"}]}]}"#.utf8))
    }
    @Test func audioChangeKeepsPositionQualityAndSubtitles() throws {
        let options = PlaybackOptions(startTicks: 0, bitrate: 20_000_000, audioIndex: 1, subtitleIndex: 3)
        let changed = try options.changing(.audio(2), item: fixture(), position: 1225)
        #expect(changed.audioIndex == 2 && changed.subtitleIndex == 3 && changed.bitrate == 20_000_000)
        #expect(changed.startTicks == 12_250_000_000)
    }
    @Test func qualityAndSubtitleChangesPreserveOtherSelections() throws {
        let options = PlaybackOptions(audioIndex: 2, subtitleIndex: 3)
        let quality = try options.changing(.bitrate(8_000_000), item: fixture(), position: 125)
        #expect(quality.bitrate == 8_000_000 && quality.audioIndex == 2 && quality.subtitleIndex == 3)
        let off = try quality.changing(.subtitles(-1), item: fixture(), position: 126)
        #expect(off.subtitleIndex == -1 && off.audioIndex == 2 && off.bitrate == 8_000_000)
    }
    @Test func invalidTrackIDsAndQualityAreRejected() throws {
        let item = try fixture(), options = PlaybackOptions()
        #expect(throws: SettingsError.invalidInput) { try options.changing(.audio(3), item: item, position: 20) }
        #expect(throws: SettingsError.invalidInput) { try options.changing(.subtitles(2), item: item, position: 20) }
        #expect(throws: SettingsError.invalidInput) { try options.changing(.bitrate(80_000_000), item: item, position: 20) }
        #expect(throws: SettingsError.invalidInput) { try options.changing(.audio(nil), item: item, position: .nan) }
    }
    @Test func automaticChoicesRemainExplicitAndPositionIsBounded() throws {
        let changed = try PlaybackOptions(audioIndex: 2).changing(.audio(nil), item: fixture(), position: 9000)
        #expect(changed.audioIndex == nil && changed.startTicks == 27_000_000_000)
        let automatic = try changed.changing(.subtitles(-2), item: fixture(), position: 100)
        #expect(automatic.subtitleIndex == -2)
    }
    @Test func liveSettingsReconnectAtLiveWithoutUsingVODResumePosition() throws {
        var item = try fixture(); item.type = "TvChannel"
        let old = PlaybackOptions(startTicks: 9_000_000_000, bitrate: 40_000_000, audioIndex: 1, subtitleIndex: 3)
        let quality = try old.changing(.bitrate(8_000_000), item: item, position: 100)
        #expect(quality.startTicks == 0 && quality.bitrate == 8_000_000 && quality.audioIndex == 1 && quality.subtitleIndex == 3)
        let audio = try quality.changing(.audio(2), item: item, position: 123)
        #expect(audio.startTicks == 0 && audio.audioIndex == 2 && audio.subtitleIndex == 3)
        let captions = try audio.changing(.subtitles(-1), item: item, position: 124)
        #expect(captions.startTicks == 0 && captions.subtitleIndex == -1 && captions.audioIndex == 2)
        #expect(throws: SettingsError.invalidInput) { try old.changing(.audio(3), item: item, position: 100) }
    }
}

@Suite("Pending player seeks") struct PlayerPendingSeekTests {
    @Test func newestSeekOwnsCompletionAndResumeIntent() {
        var pending = PlayerPendingSeek()
        let first = pending.begin(position: 100, resume: true)!
        let second = pending.begin(position: first.position + 30, resume: first.resume)!
        pending.finish(first.id)
        #expect(pending.current == second && pending.current?.resume == true)
        pending.finish(second.id); #expect(pending.current == nil)
    }
    @Test func pausedSeeksAndInterruptionNeverInventResume() {
        var pending = PlayerPendingSeek()
        let request = pending.begin(position: 200, resume: false)!
        #expect(!request.resume)
        pending.cancel(); pending.finish(request.id); #expect(pending.current == nil)
    }
    @Test func invalidSeekDoesNotDisplaceAValidPendingRequest() {
        var pending = PlayerPendingSeek()
        let request = pending.begin(position: 100, resume: true)!
        let invalid = pending.begin(position: .nan, resume: false)
        #expect(invalid == nil && pending.current == request)
    }
}


@Suite("Remote Back hierarchy") struct PlayerRemoteBackTests {
    @Test func panelsCloseBeforePlayingControlsOrPlayer() {
        var value = PlayerInteraction(); value.update(phase: .playing, now: 0)
        value.open(.information)
        #expect(value.backAction == .closePanel)
        _ = value.closePanel(now: 1)
        #expect(value.backAction == .hideControls)
        value.toggleControls(now: 2)
        #expect(value.backAction == .closePlayer)
    }
    @Test func remoteBackCancelsDraftSeekWithoutChangingItsResumeIntent() {
        var value = PlayerInteraction(); value.update(phase: .playing, now: 0)
        let beganPlayingScrub = value.beginScrub(at: 120)
        #expect(beganPlayingScrub)
        value.update(phase: .paused, now: 1)
        #expect(value.backAction == .cancelScrub)
        let resumesAfterCancel = value.cancelScrub(now: 2)
        #expect(resumesAfterCancel)
        #expect(value.scrubPosition == nil && value.backAction == .closePlayer)
        value.update(phase: .paused, now: 3)
        let beganPausedScrub = value.beginScrub(at: 180)
        #expect(beganPausedScrub)
        let resumesPausedScrub = value.cancelScrub(now: 4)
        #expect(!resumesPausedScrub)
    }
    @Test func voiceOverDoesNotTrapBackOnPermanentlyVisibleControls() {
        var value = PlayerInteraction(); value.persistentControls = true
        value.update(phase: .playing, now: 0)
        #expect(value.controlsVisible && value.backAction == .closePlayer)
    }
    @Test func failurePreparationAndPausedPlayerCanAlwaysClose() {
        for phase in [PlayerPhase.preparing, .paused, .failed, .buffering, .ended] {
            var value = PlayerInteraction(); value.update(phase: phase, now: 0)
            #expect(value.backAction == .closePlayer)
        }
        var value = PlayerInteraction(); value.setLocked(true, now: 0)
        #expect(value.backAction == .unlock)
        value.close(); #expect(value.backAction == .closePlayer)
    }
}

@Suite("TV timeline preview and transport") struct PlayerRemoteSeekTests {
    private var vod: PlayerTimeline {
        .init(localPosition: 120, duration: 600, seekable: [.init(start: 0, end: 600)!])
    }
    @Test func navigatingButtonsNeverStartsASeekOrPauses() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        for seconds in [-10.0, 10, 10, -10] {
            let accepted = state.previewRemoteSeek(by: seconds, timeline: vod, timelineFocused: false)
            #expect(!accepted && state.scrubPosition == nil && state.phase == .playing)
        }
    }
    @Test func firstHorizontalPressPreviewsWithoutExtraSelectAndRepeatedPressesAccumulate() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        let first = state.previewRemoteSeek(by: 10, timeline: vod, timelineFocused: true)
        #expect(first && state.scrubPosition == 130 && state.scrubResumeIntent)
        state.update(phase: .paused, now: 1)
        _ = state.previewRemoteSeek(by: 10, timeline: vod, timelineFocused: true)
        _ = state.previewRemoteSeek(by: -10, timeline: vod, timelineFocused: true)
        #expect(state.scrubPosition == 130 && vod.position == 120)
        let result = state.finishScrub(now: 2, play: true)
        #expect(result?.position == 130 && result?.resume == true)
        #expect(state.finishScrub(now: 3, play: true) == nil)
    }
    @Test func selectOrPlayConfirmsPausedPreviewAndClearsTheTransportTrap() {
        var state = PlayerInteraction(); state.update(phase: .paused, now: 0)
        _ = state.previewRemoteSeek(by: -10, timeline: vod, timelineFocused: true)
        let result = state.finishScrub(now: 1, play: true)
        #expect(result?.position == 110 && result?.resume == true)
        #expect(state.scrubPosition == nil && !state.scrubResumeIntent)
        state.update(phase: .playing, now: 2); state.tick(now: 6)
        let canPauseAgain = state.pauseFromHiddenSurface(now: 7)
        #expect(canPauseAgain)
    }
    @Test(arguments: [PlayerPhase.playing, .paused])
    func movingToOptionsCancelsWithoutSeekingAndRestoresOriginalIntent(_ phase: PlayerPhase) {
        var state = PlayerInteraction(); state.update(phase: phase, now: 0)
        _ = state.previewRemoteSeek(by: 10, timeline: vod, timelineFocused: true)
        state.update(phase: .paused, now: 1)
        let resume = state.cancelScrub(now: 2)
        #expect(resume == (phase == .playing) && state.scrubPosition == nil)
        #expect(state.finishScrub(now: 3, play: true) == nil && vod.position == 120)
    }
    @Test func previewClampsAndNeverInventsLiveRewind() {
        var state = PlayerInteraction(); state.update(phase: .playing, now: 0)
        _ = state.previewRemoteSeek(by: -1000, timeline: vod, timelineFocused: true)
        #expect(state.scrubPosition == 0)
        _ = state.previewRemoteSeek(by: 1000, timeline: vod, timelineFocused: true)
        #expect(state.scrubPosition == 600)
        _ = state.cancelScrub(now: 1)
        let live = PlayerTimeline(localPosition: 100, duration: nil, isLive: true,
                                 seekable: [.init(start: 90, end: 110)!])
        let rewoundLive = state.previewRemoteSeek(by: -10, timeline: live, timelineFocused: true)
        #expect(!rewoundLive)
        #expect(state.scrubPosition == nil)
    }
    @Test func explicitPlayCannotResumeInterruptedOrClosedPreview() {
        var state = PlayerInteraction(); state.update(phase: .paused, now: 0)
        _ = state.previewRemoteSeek(by: 10, timeline: vod, timelineFocused: true)
        state.interrupt(now: 1)
        #expect(state.finishScrub(now: 2, play: true) == nil)
        _ = state.previewRemoteSeek(by: 10, timeline: vod, timelineFocused: true)
        #expect(state.finishScrub(now: 3, active: false, play: true)?.resume == false)
        state.close()
        let reopened = state.previewRemoteSeek(by: 10, timeline: vod, timelineFocused: true)
        #expect(!reopened)
    }
}
