import AVFoundation
import SwiftUI
import XCTest
import ZorofinCore
@testable import Zorofin_iOS

@MainActor @Observable private final class PlayerCoverState {
    var presentation: PlaybackPresentation?
    var controls: PlayerControlsSnapshot?
    var onControlsChange: (@MainActor () -> Void)?
    func record(_ snapshot: PlayerControlsSnapshot) {
        controls = snapshot; onControlsChange?()
    }
}

/// Exercise SwiftUI's cover host and the presenting root's changing geometry,
/// rather than presenting UIHostingController directly from UIKit.
@MainActor private struct PlayerCoverHarness: View {
    @Bindable var state: PlayerCoverState
    let model: AppModel
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                NavigationStack { Color.black }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 66) }
            .fullScreenCover(item: $state.presentation) { presentation in
                NativePlayerView(presentation: presentation, onClose: { state.presentation = nil })
                    // An independent UIKit test window has no SwiftUI Scene
                    // to supply this value; model an active playback scene.
                    .environment(\.scenePhase, .active)
                    .environment(\.playerControlsObserver, { state.record($0) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(model)
            .environment(\.adaptiveWindow, AdaptiveWindow(width: geometry.size.width, height: geometry.size.height))
            .preferredColorScheme(.dark)
        }
    }
}

/// The actual browsing shell owns presentation, dock sizing and navigation.
/// Only authentication/network data and the active-scene value are synthetic.
@MainActor private struct ProductionPlayerHarness: View {
    let state: PlayerCoverState
    let model: AppModel
    var body: some View {
        GeometryReader { geometry in
            ZorofinShell().id(model.generation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .environment(model)
                .environment(\.scenePhase, .active)
                .environment(\.playerControlsObserver, { state.record($0) })
                .environment(\.adaptiveWindow, AdaptiveWindow(width: geometry.size.width, height: geometry.size.height))
                .modifier(NativeMotionPreference(reduce: model.preferences.reduceMotion))
                .preferredColorScheme(.dark)
                .tint(Theme.jade)
        }
    }
}

/// Runs the shipping player view with a generated local video, never a saved
/// account or server. Bounds checks are not physical rotation acceptance.
final class PlayerLayoutTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        // Release always uses this branch. Debug comparison preferences on a
        // physical phone must not silently change what these tests exercise.
        guard ProcessInfo.processInfo.arguments.contains("--custom-player") else {
            XCTFail("Hosted player tests require --custom-player; rebuild the dedicated test scheme")
            throw NSError(domain: "PlayerLayoutTests", code: 2)
        }
    }

    @MainActor private func activeScene() async throws -> UIWindowScene {
        try await waitFor("foreground-active scene", seconds: 15) {
            UIApplication.shared.connectedScenes.contains {
                $0 is UIWindowScene && $0.activationState == .foregroundActive
            }
        }
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    @MainActor private func renderedSurface(in controller: UIViewController, window: UIWindow) async throws -> UIView {
        try await waitFor("attached custom AVPlayerLayer surface", seconds: 15) {
            guard window.windowScene?.activationState == .foregroundActive,
                  controller.view.window === window, !controller.isBeingPresented,
                  controller.transitionCoordinator == nil else { return false }
            controller.view.layoutIfNeeded()
            guard let surface = self.videoView(in: controller.view), surface.window === window,
                  surface.bounds.width > 0, surface.bounds.height > 0,
                  let layer = surface.layer as? AVPlayerLayer else { return false }
            return layer.player != nil
        }
        return try XCTUnwrap(videoView(in: controller.view))
    }

    @MainActor private func waitFor(_ description: String, seconds: Double = 10,
                                   condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while true {
            if await condition() { return }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(description)")
        throw URLError(.timedOut)
    }

    @MainActor private func assertWindowGeometry(surface: UIView, cover: UIViewController, window: UIWindow,
                                                stage: String, decoded: Bool) {
        let expected = window.safeAreaLayoutGuide.layoutFrame
        let actual = surface.convert(surface.bounds, to: window)
        XCTAssertEqual(cover.view.bounds.width, window.bounds.width, accuracy: 1, stage)
        XCTAssertEqual(cover.view.bounds.height, window.bounds.height, accuracy: 1, stage)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, stage)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, stage)
        XCTAssertEqual(actual.midX, expected.midX, accuracy: 1, stage)
        XCTAssertEqual(actual.midY, expected.midY, accuracy: 1, stage)
        if decoded, let layer = surface.layer as? AVPlayerLayer {
            XCTAssertGreaterThan(layer.videoRect.height, 0, stage)
            XCTAssertEqual(layer.videoRect.width / layer.videoRect.height, 16.0 / 9, accuracy: 0.01, stage)
            XCTAssertEqual(layer.videoRect.midX, surface.bounds.midX, accuracy: 1, stage)
            XCTAssertEqual(layer.videoRect.midY, surface.bounds.midY, accuracy: 1, stage)
            XCTAssertEqual(layer.videoGravity, .resizeAspect, stage)
        }
        print("Player startup layout: stage=\(stage) horizontalSizeClass=\(cover.traitCollection.horizontalSizeClass.rawValue) window=\(window.bounds.size) video=\(actual)")
    }

    @MainActor private func videoView(in view: UIView) -> UIView? {
        if view.layer is AVPlayerLayer { return view }
        return view.subviews.lazy.compactMap { self.videoView(in: $0) }.first
    }

    @MainActor func testVideoBoundsSurviveRepeatedViewportChanges() async throws {
        let scene = try await activeScene()
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let model = AppModel()
        model.showDemo()
        let presentation = PlaybackPresentation(item: PreviewLibrary.episodes[2], options: .init())
        let host = UIHostingController(rootView: NativePlayerView(presentation: presentation, onClose: {}).environment(model))
        let parent = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = parent
        window.makeKeyAndVisible()
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
        defer {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }

        host.view.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let surface = try await renderedSurface(in: host, window: window)
        let layer = try XCTUnwrap(surface.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "player-preparation", withExtension: "mp4"))
        let driver = AVPlayerPreparationDriver(player: player, url: fixture,
            allowsLiveResourcesWhilePaused: false, isActive: { true })
        try await PlayerPreparation.run(driver, startSeconds: 1.25, primePausedFrame: true, recoverPausedHLS: false)

        // Stale 15 Pro Max/16 Pro portrait and landscape host frames, including
        // offsets, must not move the picture away from the actual window. Real
        // orientation changes are covered by the full-screen rotation test.
        let sizes: [CGSize] = [
            .init(width: 430, height: 932), .init(width: 932, height: 430),
            .init(width: 430, height: 932), .init(width: 932, height: 430),
            .init(width: 402, height: 874), .init(width: 874, height: 402),
            .init(width: 402, height: 874), .init(width: 430, height: 932)]
        let origins: [CGPoint] = [.zero, .init(x: 37, y: 83), .init(x: -29, y: -61)]
        let frames = sizes.flatMap { size in origins.map { CGRect(origin: $0, size: size) } }
        let item = try XCTUnwrap(player.currentItem)
        for frame in frames {
            host.view.frame = frame
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(videoView(in: host.view) === surface, "Host changes must retain the video surface")
            XCTAssertTrue(surface.layer === layer && layer.player === player, "Host changes must retain the layer/player")
            XCTAssertTrue(player.currentItem === item, "Host changes must retain the decoded item")
            let safe = window.safeAreaLayoutGuide.layoutFrame
            let actual = surface.convert(surface.bounds, to: window)
            XCTAssertEqual(actual.width, safe.width, accuracy: 1, "Video width at host \(frame)")
            XCTAssertEqual(actual.height, safe.height, accuracy: 1, "Video height at host \(frame)")
            XCTAssertEqual(actual.midX, safe.midX, accuracy: 1, "Video horizontal alignment at host \(frame)")
            XCTAssertEqual(actual.midY, safe.midY, accuracy: 1, "Video vertical alignment at host \(frame)")
            XCTAssertEqual(player.rate, 0, "Host changes must preserve paused playback")
            XCTAssertEqual(player.currentTime().seconds, 1.25, accuracy: 0.2)
            XCTAssertEqual(layer.videoGravity, .resizeAspect)
            XCTAssertGreaterThan(layer.videoRect.height, 0)
            XCTAssertEqual(layer.videoRect.width / layer.videoRect.height, 16.0 / 9, accuracy: 0.01)
            XCTAssertEqual(layer.videoRect.midX, surface.bounds.midX, accuracy: 1)
            XCTAssertEqual(layer.videoRect.midY, surface.bounds.midY, accuracy: 1)
        }
    }

    @MainActor func testPlaybackRotationLeaseSurvivesOverlappingPlayersAndMoves() {
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        let second = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let lease = PhonePlaybackOrientation.RotationLeaseView()
        let overlap = PhonePlaybackOrientation.RotationLeaseView()
        let delegate = ZorofinAppDelegate()
        func mask(_ window: UIWindow) -> UIInterfaceOrientationMask {
            delegate.application(.shared, supportedInterfaceOrientationsFor: window)
        }
        XCTAssertEqual(mask(first), .portrait)
        first.addSubview(lease)
        first.addSubview(overlap)
        XCTAssertEqual(mask(first), .allButUpsideDown)
        second.addSubview(lease)
        XCTAssertEqual(mask(first), .allButUpsideDown)
        XCTAssertEqual(mask(second), .allButUpsideDown)
        overlap.removeFromSuperview()
        XCTAssertEqual(mask(first), .portrait)
        XCTAssertEqual(mask(second), .allButUpsideDown)
        lease.removeFromSuperview()
        lease.releaseWindow() // Teardown may arrive after didMoveToWindow.
        XCTAssertEqual(mask(second), .portrait)
    }

    @MainActor private func rotate(_ scene: UIWindowScene, to orientation: UIInterfaceOrientation) async throws {
        if scene.interfaceOrientation != orientation {
            let mask: UIInterfaceOrientationMask = switch orientation {
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            default: .portrait
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            for _ in 0..<60 {
                if scene.interfaceOrientation == orientation { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        XCTAssertEqual(scene.interfaceOrientation, orientation, "The player must support the requested orientation")
        try await Task.sleep(for: .milliseconds(250))
    }

    @MainActor func testFullScreenRotationRetainsVideoAndRestoresPortrait() async throws {
        let scene = try await activeScene()
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(200))
        let model = AppModel()
        model.showDemo()
        let presentation = PlaybackPresentation(item: PreviewLibrary.episodes[2], options: .init())
        let host = UIHostingController(rootView: NativePlayerView(presentation: presentation, onClose: {})
            .environment(model).environment(\.dynamicTypeSize, .accessibility1))
        host.modalPresentationStyle = .fullScreen
        presenter.present(host, animated: true)
        for _ in 0..<100 {
            if presenter.presentedViewController === host && !host.isBeingPresented { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(presenter.presentedViewController === host)
        guard presenter.presentedViewController === host else {
            throw NSError(domain: "PlayerLayoutTests", code: 1)
        }
        defer { presenter.dismiss(animated: false) }
        let surface = try await renderedSurface(in: host, window: window)
        let layer = try XCTUnwrap(surface.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "player-preparation", withExtension: "mp4"))
        let driver = AVPlayerPreparationDriver(player: player, url: fixture,
            allowsLiveResourcesWhilePaused: false, isActive: { true })
        try await PlayerPreparation.run(driver, startSeconds: 1.25, primePausedFrame: true, recoverPausedHLS: false)
        let item = try XCTUnwrap(player.currentItem)
        for orientation: UIInterfaceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait, .landscapeLeft] {
            try await rotate(scene, to: orientation)
            let safe = host.view.safeAreaLayoutGuide.layoutFrame
            let actual = surface.convert(surface.bounds, to: host.view)
            XCTAssertEqual(actual.width, safe.width, accuracy: 1)
            XCTAssertEqual(actual.height, safe.height, accuracy: 1)
            XCTAssertEqual(actual.midX, safe.midX, accuracy: 1)
            XCTAssertEqual(actual.midY, safe.midY, accuracy: 1)
            XCTAssertTrue(videoView(in: host.view) === surface)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(player.rate, 0, "Rotation must preserve paused playback")
            XCTAssertEqual(player.currentTime().seconds, 1.25, accuracy: 0.2)
        }
        presenter.dismiss(animated: true)
        for _ in 0..<100 {
            if presenter.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(presenter.presentedViewController)
        // The app's release policy, rather than this test helper, requests
        // portrait when the last playback lease leaves the window.
        for _ in 0..<60 {
            if scene.interfaceOrientation == .portrait { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(scene.interfaceOrientation, .portrait)
        XCTAssertEqual(ZorofinAppDelegate().application(.shared, supportedInterfaceOrientationsFor: window), .portrait)
    }

    @MainActor func testSwiftUICoverMatchesWindowThroughSizeClassChanges() async throws {
        let scene = try await activeScene()
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = PlayerCoverState()
        let model = AppModel()
        model.showDemo()
        let root = UIHostingController(rootView: PlayerCoverHarness(state: state, model: model))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { state.presentation = nil; window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        state.presentation = PlaybackPresentation(item: PreviewLibrary.episodes[2], options: .init())
        for _ in 0..<100 {
            if let cover = root.presentedViewController, !cover.isBeingPresented,
               videoView(in: cover.view) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let cover = try XCTUnwrap(root.presentedViewController)
        let surface = try await renderedSurface(in: cover, window: window)
        let layer = try XCTUnwrap(surface.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "player-preparation", withExtension: "mp4"))
        let driver = AVPlayerPreparationDriver(player: player, url: fixture,
            allowsLiveResourcesWhilePaused: false, isActive: { true })
        try await PlayerPreparation.run(driver, startSeconds: 1.25, primePausedFrame: true, recoverPausedHLS: false)
        let item = try XCTUnwrap(player.currentItem)
        for orientation: UIInterfaceOrientation in [.portrait, .landscapeLeft, .portrait, .landscapeRight, .portrait] {
            try await rotate(scene, to: orientation)
            let expected = window.safeAreaLayoutGuide.layoutFrame
            let actual = surface.convert(surface.bounds, to: window)
            XCTAssertEqual(cover.view.bounds.width, window.bounds.width, accuracy: 1, "Cover width must match its window")
            XCTAssertEqual(cover.view.bounds.height, window.bounds.height, accuracy: 1, "Cover height must match its window")
            XCTAssertEqual(actual.width, expected.width, accuracy: 1, "Video must match the window's safe width")
            XCTAssertEqual(actual.height, expected.height, accuracy: 1, "Video must match the window's safe height")
            XCTAssertEqual(actual.midX, expected.midX, accuracy: 1)
            XCTAssertEqual(actual.midY, expected.midY, accuracy: 1)
            XCTAssertTrue(videoView(in: cover.view) === surface)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertGreaterThan(layer.videoRect.width, 0)
            XCTAssertGreaterThan(layer.videoRect.height, 0)
            XCTAssertEqual(layer.videoRect.width / layer.videoRect.height, 16.0 / 9, accuracy: 0.01)
            print("Player cover layout: orientation=\(orientation.rawValue) horizontalSizeClass=\(cover.traitCollection.horizontalSizeClass.rawValue) window=\(window.bounds.size) cover=\(cover.view.bounds.size) video=\(actual)")
        }
        state.presentation = nil
        for _ in 0..<100 {
            if root.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(root.presentedViewController)
    }

    @MainActor func testProductionStartupAndHiddenControlsRetainWindowGeometry() async throws {
        let origin = try PlayerHLSOrigin(bundle: Bundle(for: Self.self))
        defer { origin.stop() }
        let address = try await origin.address()
        let transport = PlayerStartupTransport()
        let model = AppModel()
        model.client = JellyfinClient(server: address, identity: .init(deviceID: "layout", deviceName: "Layout fixture"),
            session: .init(server: address, viewer: .init(id: "layout-viewer", name: "Fixture"), token: "synthetic", deviceID: "layout"),
            transport: transport)
        model.session = model.client?.session
        model.preferencesReady = true
        let scene = try await activeScene()
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = PlayerCoverState()
        let root = UIHostingController(rootView: ProductionPlayerHarness(state: state, model: model))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { model.generation = UUID(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        // Use the shell's existing incoming-playback path; no group is joined
        // and no production API, preview player or test presentation replaces it.
        model.watchTogether.playbackRequest = GroupPlaybackRequest(
            item: .init(id: "layout-movie", name: "Synthetic rotation fixture", type: "Movie"), options: .init())
        try await waitFor("production playback negotiation") { await transport.negotiationStarted }
        let cover = try XCTUnwrap(root.presentedViewController)
        try await waitFor("completed cover presentation") {
            !cover.isBeingPresented && cover.transitionCoordinator == nil
        }
        let surface = try await renderedSurface(in: cover, window: window)
        let layer = try XCTUnwrap(surface.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let startupDeadline = ProcessInfo.processInfo.systemUptime + 60
        for orientation: UIInterfaceOrientation in [.portrait, .landscapeLeft, .portrait, .landscapeRight, .portrait] {
            try await rotate(scene, to: orientation)
            assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "preparing", decoded: false)
        }
        // Match the report's long preparation interval without slowing a real
        // server or changing AVFoundation timeouts. Rotation remains live here.
        while ProcessInfo.processInfo.systemUptime < startupDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNil(player.currentItem, "The fixture must still be negotiating")
        XCTAssertEqual(state.controls?.phase, .preparing)
        XCTAssertEqual(state.controls?.visible, true)
        await transport.allowPlayback()
        do {
            try await waitFor("HLS decoding and playing", seconds: 30) {
                player.timeControlStatus == .playing && layer.videoRect.height > 0
            }
        } catch {
            let item = player.currentItem
            print("Player startup diagnostic: status=\(player.status.rawValue) timeControl=\(player.timeControlStatus.rawValue) item=\(item?.status.rawValue ?? -1) phase=\(state.controls?.phase.rawValue ?? "none") size=\(item?.presentationSize ?? .zero) rect=\(layer.videoRect) errors=\(item?.errorLog()?.events.map(\.errorStatusCode) ?? []) paths=\(origin.requestedPaths)")
            throw error
        }
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(origin.requestedPaths.contains("/stream.m3u8"))
        XCTAssertTrue(origin.requestedPaths.contains { $0.hasSuffix(".ts") })
        try await waitFor("playing controls") { state.controls?.phase == .playing && state.controls?.visible == true }
        for orientation: UIInterfaceOrientation in [.landscapeLeft, .portrait, .landscapeRight] {
            try await rotate(scene, to: orientation)
            assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "playing", decoded: true)
        }
        try await waitFor("automatic control hiding") {
            state.controls?.phase == .playing && state.controls?.visible == false
        }
        for orientation: UIInterfaceOrientation in [.portrait, .landscapeLeft, .portrait, .landscapeRight] {
            try await rotate(scene, to: orientation)
            assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "controls-hidden", decoded: true)
            XCTAssertTrue(videoView(in: cover.view) === surface)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(player.timeControlStatus, .playing)
            XCTAssertEqual(state.controls?.visible, false)
            let viewport = try XCTUnwrap(state.controls?.viewport)
            XCTAssertEqual(viewport.width, window.safeAreaLayoutGuide.layoutFrame.width, accuracy: 1)
            XCTAssertEqual(viewport.height, window.safeAreaLayoutGuide.layoutFrame.height, accuracy: 1)
        }
        player.pause() // The production KVO/phase/control lifecycle handles this.
        try await waitFor("paused controls returning") { state.controls?.phase == .paused && state.controls?.visible == true }
        try await rotate(scene, to: .portrait)
        assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "paused", decoded: true)
        player.play()
        try await waitFor("resumed playback") { player.timeControlStatus == .playing }
        try await waitFor("resumed control hiding") { state.controls?.phase == .playing && state.controls?.visible == false }
        try await rotate(scene, to: .landscapeLeft)
        assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "resumed-hidden", decoded: true)
        model.generation = UUID() // Exercise the shell's normal account-generation dismissal.
        try await waitFor("dismissal and playback cleanup") {
            root.presentedViewController == nil && player.currentItem == nil && scene.interfaceOrientation == .portrait
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.contains("/Items/layout-movie"))
        XCTAssertTrue(requests.contains("/Sessions/Playing"))
        XCTAssertTrue(requests.contains("/Sessions/Playing/Stopped"))
    }

    private enum DelayedReplay: String {
        case playlist, initialSegment, resumeSegment, combinedResume
        var resumes: Bool { self == .resumeSegment || self == .combinedResume }
    }

    @MainActor func testDelayedPlaylistFirstFrameRotation() async throws { try await delayedReplay(.playlist) }
    @MainActor func testDelayedInitialSegmentFirstFrameRotation() async throws { try await delayedReplay(.initialSegment) }
    @MainActor func testDelayedResumeSegmentFirstFrameRotation() async throws { try await delayedReplay(.resumeSegment) }
    @MainActor func testCombinedDelayedResumeFirstFrameRotation() async throws { try await delayedReplay(.combinedResume) }

    @MainActor private func delayedReplay(_ scenario: DelayedReplay) async throws {
        let (directory, profile) = try PlayerReplayProfile.load()
        let master = "/master.m3u8", firstSegment = "/segment-00000.ts"
        var gates: Set<String> = [master] // Bootstrap gate lets the real cover finish before any video bytes arrive.
        if scenario == .initialSegment || scenario == .combinedResume { gates.insert(firstSegment) }
        if scenario.resumes { gates.insert(profile.resumeSegment) }
        let origin = try PlayerHLSOrigin(bundle: Bundle(for: Self.self), directory: directory, heldPaths: gates)
        defer { origin.stop() }
        let transport = PlayerStartupTransport(profile: profile)
        let address = try await origin.address(), model = AppModel()
        model.client = JellyfinClient(server: address, identity: .init(deviceID: "layout", deviceName: "Layout fixture"),
            session: .init(server: address, viewer: .init(id: "layout-viewer", name: "Fixture"), token: "synthetic", deviceID: "layout"),
            transport: transport)
        model.session = model.client?.session; model.preferencesReady = true
        let scene = try await activeScene()
        let previousWindow = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let state = PlayerCoverState()
        let root = UIHostingController(rootView: ProductionPlayerHarness(state: state, model: model))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { model.generation = UUID(); window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        let startSeconds = scenario.resumes ? profile.resumeSeconds : 0
        model.watchTogether.playbackRequest = .init(item: .init(id: "layout-episode", name: "Synthetic episode", type: "Episode"),
            options: .init(startTicks: MediaTime.ticks(seconds: startSeconds), audioIndex: profile.audioStreamIndex,
                           subtitleIndex: profile.subtitleStreamIndex))
        try await waitFor("production renderer before media setup", seconds: 15) {
            guard let cover = root.presentedViewController else { return false }
            return self.videoView(in: cover.view) != nil
        }
        let cover = try XCTUnwrap(root.presentedViewController)
        let surface = try await renderedSurface(in: cover, window: window), layer = try XCTUnwrap(surface.layer as? AVPlayerLayer)
        let player = try XCTUnwrap(layer.player)
        let trace = PlayerRotationTrace(window: window, cover: cover, surface: surface, controls: { state.controls })
        state.onControlsChange = { [weak trace] in trace?.capture("controls-change") }
        defer {
            state.onControlsChange = nil
            do { add(try trace.finish(name: scenario.rawValue, requests: origin.requestEvents)) }
            catch { XCTFail("Could not retain numeric rotation trace: \(error)") }
        }
        try await waitFor("completed production cover") { !cover.isBeingPresented && cover.transitionCoordinator == nil }
        try await waitFor("negotiation bootstrap ready") { await transport.negotiationStarted }
        trace.mark("negotiation-bootstrap-released")
        await transport.allowPlayback()
        try await waitFor("AVPlayer master request held after item creation", seconds: 30) { origin.isHolding(master) }
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(state.controls?.phase, .preparing)
        XCTAssertFalse(layer.isReadyForDisplay, "The bootstrap gate must prevent a decoded frame")
        trace.mark("item-created-before-bytes")
        assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "gated-portrait", decoded: false)

        let firstFrameRotation = Task { @MainActor in
            try await self.waitFor("first decoded frame", seconds: 40) { trace.firstFrameAt != nil }
            trace.mark("first-frame-before-rotation")
            try await self.rotate(scene, to: .landscapeLeft)
            trace.mark("first-frame-landscape-settled")
            self.assertWindowGeometry(surface: surface, cover: cover, window: window,
                stage: "first-frame-settled", decoded: layer.isReadyForDisplay && layer.videoRect.height > 0)
        }
        defer { firstFrameRotation.cancel() }
        let holdSeconds: Double = scenario == .combinedResume ? 6 : 8
        var delayedPaths: [String] = []
        if scenario == .playlist || scenario == .combinedResume {
            delayedPaths.append(master); trace.mark("playlist-held-with-item")
            try await Task.sleep(for: .seconds(holdSeconds))
        }
        origin.release(master)
        if gates.contains(firstSegment) {
            try await waitFor("initial media segment held") { origin.isHolding(firstSegment) }
            trace.mark("initial-segment-held-with-item"); delayedPaths.append(firstSegment)
            XCTAssertTrue(player.currentItem === item)
            try await Task.sleep(for: .seconds(holdSeconds)); origin.release(firstSegment)
        }
        if scenario.resumes {
            try await waitFor("resumed media segment held", seconds: 20) { origin.isHolding(profile.resumeSegment) }
            trace.mark("resume-segment-held-with-item"); delayedPaths.append(profile.resumeSegment)
            XCTAssertTrue(player.currentItem === item)
            try await Task.sleep(for: .seconds(holdSeconds)); origin.release(profile.resumeSegment)
        }
        try await firstFrameRotation.value
        try await waitFor("decoded playback at requested position", seconds: 15) {
            player.timeControlStatus == .playing && layer.isReadyForDisplay && state.controls?.phase == .playing
        }
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, startSeconds - 0.3)
        XCTAssertLessThan(player.currentTime().seconds, startSeconds + 10)
        XCTAssertEqual(item.presentationSize.width, CGFloat(profile.width), accuracy: 1)
        XCTAssertEqual(item.presentationSize.height, CGFloat(profile.height), accuracy: 1)
        for orientation: UIInterfaceOrientation in [.portrait, .landscapeRight] {
            trace.mark("playing-before-rotation")
            try await rotate(scene, to: orientation)
            trace.mark("playing-settled")
            assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "delayed-playing", decoded: true)
        }
        try await waitFor("real controls hiding after delayed startup") { state.controls?.visible == false }
        for orientation: UIInterfaceOrientation in [.portrait, .landscapeLeft] {
            trace.mark("hidden-before-rotation")
            try await rotate(scene, to: orientation)
            trace.mark("hidden-settled")
            assertWindowGeometry(surface: surface, cover: cover, window: window, stage: "delayed-hidden", decoded: true)
            XCTAssertTrue(videoView(in: cover.view) === surface && player.currentItem === item)
            let viewport = try XCTUnwrap(state.controls?.viewport)
            XCTAssertEqual(viewport.width, window.safeAreaLayoutGuide.layoutFrame.width, accuracy: 1)
            XCTAssertEqual(viewport.height, window.safeAreaLayoutGuide.layoutFrame.height, accuracy: 1)
        }
        for path in delayedPaths {
            let event = try XCTUnwrap(origin.requestEvents.first { $0.path == path && $0.held })
            let responded = try XCTUnwrap(event.respondedAt)
            XCTAssertGreaterThanOrEqual(responded - event.requestedAt, holdSeconds - 0.2, "The gate must delay actual media delivery")
        }
        let negotiated = await transport.negotiatedOptions
        let options = try XCTUnwrap(negotiated.last)
        XCTAssertEqual(options.startTicks, MediaTime.ticks(seconds: startSeconds))
        XCTAssertEqual(options.audioIndex, profile.audioStreamIndex)
        XCTAssertEqual(options.subtitleIndex, profile.subtitleStreamIndex)
        trace.mark("before-account-dismissal")
        model.generation = UUID()
        try await waitFor("account dismissal and portrait cleanup") {
            root.presentedViewController == nil && player.currentItem == nil && scene.interfaceOrientation == .portrait
        }
        trace.mark("dismissed")
        let requests = await transport.requests
        XCTAssertTrue(requests.contains("/Sessions/Playing/Stopped"))
    }
}

private actor HomeCapabilitiesGate: HTTPTransport {
    let blocked: Bool
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    init(blocked: Bool = false) { self.blocked = blocked }
    func waitForRead() async {
        if started { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { gate?.resume(); gate = nil }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true; observer?.resume(); observer = nil
        if blocked { await withCheckedContinuation { gate = $0 } }
        let payload = Data(#"{"schemaVersion":1,"features":{"homeRows":{"version":2,"enabled":true}}}"#.utf8)
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class HomeRowsSwitchoverTests: XCTestCase {
    private func client(_ transport: any HTTPTransport) throws -> JellyfinClient {
        let server = try ServerAddress("https://example.test/jellyfin")
        return JellyfinClient(server: server, identity: .init(deviceID: "fixture", deviceName: "Test"),
            session: .init(server: server, viewer: .init(id: "viewer", name: "Viewer"), token: "fixture", deviceID: "fixture"),
            transport: transport)
    }
    func testCapabilityChangeRetiresVisibleRowsAndPendingLoadIdentity() async throws {
        let model = AppModel()
        model.client = try client(HomeCapabilitiesGate())
        model.features = .init(homeRowsContract: .legacy)
        model.homeLibrary.rowsContract = .legacy
        model.homeLibrary.homeFeed = HomeFeed(generatedAt: "fixture", preferences: .init(), rows: [])
        let oldLoad = model.homeLibrary.rowLoadID
        await model.checkFeatures()
        XCTAssertEqual(model.features.homeRowsContract, .plugin)
        XCTAssertNil(model.homeLibrary.homeFeed)
        XCTAssertNotEqual(model.homeLibrary.rowLoadID, oldLoad)
        XCTAssertEqual(model.homeLibrary.rowsRevision, -1)
    }
    func testLateCapabilityResponseCannotChangeTheNewAccount() async throws {
        let gate = HomeCapabilitiesGate(blocked: true), model = AppModel()
        model.client = try client(gate)
        let pending = Task { await model.checkFeatures() }
        await gate.waitForRead()
        model.generation = UUID()
        model.features = .init()
        model.homeLibrary = HomeLibraryState()
        let currentLoad = model.homeLibrary.rowLoadID
        await gate.release()
        await pending.value
        XCTAssertNil(model.features.homeRowsContract)
        XCTAssertNil(model.homeLibrary.homeFeed)
        XCTAssertEqual(model.homeLibrary.rowLoadID, currentLoad)
    }
}
