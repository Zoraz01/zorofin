import AVFoundation
import SwiftUI
import ZorofinCore

// Trailer previews on Apple TV Home: the focused poster in an eligible row widens to
// 16:9 and, after a 2 s rest, plays the title's local trailer muted.
// Handoff: docs/handoffs/TRAILER_PREVIEWS_APPS_HANDOFF.md. Mockups:
// docs/design/trailer-previews/mockups/card-*.jpg. iPhone and iPad get nothing.

#if os(tvOS)
/// One preview player for Home. Rows report focus here; the rules live in Core's PreviewCoordinator.
@MainActor @Observable final class TrailerPreviewEngine {
    private(set) var coordinator = PreviewCoordinator()
    /// The row that owns the focused title.
    private(set) var row: String?
    private(set) var played: TimeInterval = 0
    @ObservationIgnored let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        return player
    }()
    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var failObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    var itemID: String? { coordinator.itemID }
    var phase: PreviewCoordinator.Phase { coordinator.phase }
    var muted: Bool { coordinator.muted }
    var hints: PreviewCoordinator.Hints { coordinator.hints }

    func configure(client: JellyfinClient?, autoplay: Bool) {
        if client?.server != self.client?.server || client?.session?.viewer.id != self.client?.session?.viewer.id {
            stopAll(endVisit: true)
        }
        self.client = client
        if coordinator.autoplay != autoplay { coordinator.autoplay = autoplay }
    }

    func focus(_ item: MediaItem?, row: String) {
        if item == nil && self.row != row { return } // another row already took focus
        self.row = item == nil ? nil : row
        perform(coordinator.focus(item, at: .now))
        runClock()
    }

    func playPause() { perform(coordinator.playPause(at: .now)); runClock() }
    func toggleSound() { player.isMuted = coordinator.toggleSound() }
    func stopAll(endVisit: Bool) {
        row = nil
        perform(coordinator.stopAll(endVisit: endVisit))
        release()
    }

    /// 0.6 s lookup, 2 s start and the first-frame timeout. Runs only while a title waits or starts.
    private func runClock() {
        clock?.cancel()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch self.coordinator.phase {
                case .waiting, .starting: break
                default: return
                }
                self.perform(self.coordinator.tick(at: .now))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func perform(_ commands: [PreviewCoordinator.Command]) {
        for command in commands {
            switch command {
            case .lookup(let itemID): startLookup(itemID)
            case .start(let source): start(source)
            case .pause: player.pause()
            case .resume: player.play()
            case .stop: release()
            }
        }
    }

    private func startLookup(_ itemID: String) {
        lookup?.cancel()
        guard let client else { perform(coordinator.lookedUp(itemID, source: nil, at: .now)); return }
        lookup = Task { [weak self] in
            // Cache-only lookups are not involved: the trailer list is small and per title.
            let item = MediaItem(id: itemID, name: "", type: "Movie")
            let source = try? await client.previewTrailer(for: item)
            guard !Task.isCancelled, let self else { return }
            self.perform(self.coordinator.lookedUp(itemID, source: source ?? nil, at: .now))
            self.runClock()
        }
    }

    private func start(_ source: TrailerSource) {
        release()
        // Ambient: a muted preview never interrupts other audio.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        let item = AVPlayerItem(url: source.url)
        item.preferredForwardBufferDuration = 4
        played = 0
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.perform(self?.coordinator.failed() ?? []) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(self?.coordinator.progress(played: self?.played ?? 0, ended: true) ?? []) }
        }
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.perform(self?.coordinator.failed() ?? []) }
        }
        // Actual playback time only; buffering and pause do not advance it.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.coordinator.showsVideo else { return }
                self.played = max(0, time.seconds)
                self.perform(self.coordinator.progress(played: self.played))
            }
        }
        player.play()
    }

    /// Called by the video layer when it can draw a frame.
    func firstFrame() {
        coordinator.firstFrame()
    }

    private func release() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = nil; failObserver = nil; statusObservation = nil
        player.replaceCurrentItem(with: nil)
        played = 0
    }
}

private struct PreviewEngineKey: EnvironmentKey {
    static let defaultValue: TrailerPreviewEngine? = nil
}
extension EnvironmentValues {
    var trailerPreview: TrailerPreviewEngine? {
        get { self[PreviewEngineKey.self] }
        set { self[PreviewEngineKey.self] = newValue }
    }
}

/// An AVPlayerLayer-backed view (not AVPlayerViewController): no transport UI, no Now Playing.
private struct PreviewVideoLayer: UIViewRepresentable {
    let engine: TrailerPreviewEngine
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var observation: NSKeyValueObservation?
    }
    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = engine.player
        view.playerLayer.videoGravity = .resizeAspectFill
        view.isUserInteractionEnabled = false
        view.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak engine] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in engine?.firstFrame() }
        }
        return view
    }
    func updateUIView(_ view: LayerView, context: Context) {}
    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        view.observation = nil; view.playerLayer.player = nil
    }
}

/// A Home row of movies and shows whose focused poster widens and can preview its trailer.
struct PreviewShelf: View {
    @Environment(AppModel.self) private var model
    @Environment(\.trailerPreview) private var engine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeReduceMotion) private var appReduceMotion
    let id: String
    let title: String
    let items: [MediaItem]
    /// One context line per title ("85 min"), in place of the year.
    var labels: [String: String] = [:]
    @FocusState private var focused: String?
    @FocusState private var pillFocused: Bool
    private var scale: CGFloat { model.posterScale }
    private var posterSize: CGSize { CGSize(width: 212 * scale, height: 318 * scale) }
    private var focusedItem: MediaItem? { items.first { $0.id == focused } ?? (pillFocused ? items.first { $0.id == engine?.itemID } : nil) }
    private var still: Bool { reduceMotion || appReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: title).padding(.horizontal, Theme.gutter)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 28) {
                        // Row-scoped ids: the same title often appears in several Home rows.
                        ForEach(items) { item in card(item).id(self.id + "|" + item.id) }
                    }.padding(.horizontal, Theme.gutter).padding(.vertical, 18)
                }.scrollIndicators(.hidden).scrollClipDisabled()
                    .onChange(of: focused) { _, id in
                        guard let id else { return }
                        // Keep the widened card (and its trailer) in the middle of
                        // the screen rather than against an edge; the first and
                        // last cards stop where the row ends.
                        withAnimation(still ? nil : .easeOut(duration: 0.26)) { proxy.scrollTo(self.id + "|" + id, anchor: .center) }
                    }
            }
            if let item = focusedItem { info(item).padding(.horizontal, Theme.gutter).transition(.opacity) }
        }
        // The focused row grows by its info block and the row it left shrinks.
        // Animate both with the focus scroll, so moving between rows glides
        // instead of jumping when the layout snaps to its new height.
        .animation(still ? nil : .smooth(duration: 0.32), value: focusedItem == nil)
        .onChange(of: focused) { _, id in
            if pillFocused { return }
            engine?.focus(items.first { $0.id == id }, row: self.id)
        }
        .onChange(of: pillFocused) { _, onPill in
            if !onPill && focused == nil { engine?.focus(nil, row: self.id) }
        }
    }

    private func isPreviewing(_ item: MediaItem) -> Bool {
        guard let engine, engine.itemID == item.id else { return false }
        switch engine.phase { case .starting, .playing, .paused: return true; default: return false }
    }

    @ViewBuilder private func card(_ item: MediaItem) -> some View {
        let wide = focused == item.id || (pillFocused && engine?.itemID == item.id)
        let eligible = TrailerPreview.eligible(item)
        let width = wide && eligible ? posterSize.height * 16 / 9 : posterSize.width
        VStack(alignment: .leading, spacing: 9) {
            NavigationLink(value: item) {
                ZStack(alignment: .bottomLeading) {
                    MediaArtwork(item: item, landscape: wide && eligible, width: wide && eligible ? 1280 : 420, showPreviewTitle: !(wide && eligible))
                    if wide && eligible { widened(item) }
                }
                .frame(width: width, height: posterSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(ArtworkButtonStyle()).focused($focused, equals: item.id)
                .onPlayPauseCommand { if focused == item.id { engine?.playPause() } }
                .accessibilityIdentifier("item-\(item.id)")
                .accessibilityLabel(item.name)
                .accessibilityHint(eligible ? "Play/Pause previews the trailer" : "")
            // Captions hide in the focused row while the info block shows.
            if model.preferences.showTitles && focusedItem == nil {
                Text(item.displayTitle).font(Theme.font(22, weight: .semibold)).lineLimit(1)
                Text(labels[item.id] ?? item.productionYear.map(String.init) ?? "").font(Theme.font(17)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            // Up from a playing card lands here; OK toggles sound, Down returns to the card.
            if isPreviewing(item), engine?.coordinator.showsVideo == true {
                Button { engine?.toggleSound() } label: {
                    Label(engine?.muted == false ? "Sound on" : "Muted",
                          systemImage: engine?.muted == false ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(Theme.font(18, weight: .semibold)).padding(.horizontal, 14).frame(height: 40)
                        .background(.black.opacity(0.55), in: Capsule())
                }.buttonStyle(PreviewPillStyle()).focused($pillFocused).padding(14)
                    .accessibilityLabel(engine?.muted == false ? "Sound on" : "Muted")
            }
        }
        .animation(still ? nil : .easeOut(duration: 0.26), value: wide)
    }

    @ViewBuilder private func widened(_ item: MediaItem) -> some View {
        let showing = isPreviewing(item)
        let video = showing && engine?.coordinator.showsVideo == true
        ZStack(alignment: .bottomLeading) {
            if showing, let engine {
                PreviewVideoLayer(engine: engine).opacity(video ? 1 : 0)
                    .animation(.easeIn(duration: TrailerPreviewTiming.fadeIn), value: video)
            }
            // Wordmark: the title, fading out when the video appears.
            Text(item.name).font(Theme.font(34, weight: .heavy)).foregroundStyle(.white).lineLimit(2)
                .shadow(color: .black.opacity(0.6), radius: 8).padding(22).opacity(video ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: video)
            if engine?.itemID == item.id, engine?.phase == .paused {
                Color.black.opacity(0.28)
                Label("Paused", systemImage: "pause.fill").font(Theme.font(22, weight: .semibold))
                    .padding(.horizontal, 18).frame(height: 48).background(.black.opacity(0.6), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if video, let engine {
                GeometryReader { geometry in
                    Rectangle().fill(Theme.jade)
                        .frame(width: geometry.size.width * min(1, engine.played / TrailerPreviewTiming.previewCap), height: 5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func info(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name).font(Theme.font(40, weight: .bold)).lineLimit(1)
            HStack(spacing: 12) {
                if let year = item.productionYear { Text(String(year)) }
                if let rating = item.officialRating, !rating.isEmpty {
                    Text(rating).font(Theme.font(18, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.muted, lineWidth: 1.5))
                }
                if !item.durationLabel.isEmpty && !item.isSeries { Text(item.durationLabel) }
                if let genres = item.genres, !genres.isEmpty { Text(genres.prefix(2).joined(separator: " · ")) }
            }.font(Theme.font(22)).foregroundStyle(Theme.muted)
            if let overview = item.overview?.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), !overview.isEmpty {
                // Always two lines tall, so the row keeps one height between titles.
                Text(overview).font(Theme.font(22)).lineLimit(2, reservesSpace: true).frame(maxWidth: 1100, alignment: .leading)
            }
        }.foregroundStyle(Theme.text).accessibilityElement(children: .combine)
    }

}

private struct PreviewPillStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .overlay(Capsule().stroke(focused ? Color.white : .clear, lineWidth: 3))
            .scaleEffect(focused ? 1.06 : 1)
    }
}
#endif
