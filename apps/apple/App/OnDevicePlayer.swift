import SwiftUI
import AVFoundation
import Combine
import AetherEngine
import ZorofinCore

/// Plays the original file on the device with AetherEngine (LGPL-3.0 with an App
/// Store exception, the engine Moonfin also uses) when AVPlayer can't take it
/// and the server would otherwise convert it: MKV with DTS or TrueHD audio, and
/// Blu-ray PGS or styled ASS subtitles. See `OnDevicePlayback` for the rule.
///
/// The engine demuxes with FFmpeg, decodes video with VideoToolbox and hands
/// AVPlayer a local HLS stream, so the app's existing AVPlayer surfaces, PiP and
/// HDR handling keep working. Subtitles are drawn by `OnDeviceSubtitleOverlay`.
@MainActor final class OnDevicePlayer {
    /// One engine for the app's lifetime, as the engine requires.
    static let shared: OnDevicePlayer? = try? OnDevicePlayer()
    let engine: AetherEngine
    /// The playback that opened the current file. A closing player's late
    /// cleanup must not stop the next one's session.
    private weak var owner: AnyObject?
    private var headers: [String: String] = [:]
    private var pgsDownload: Task<Void, Never>?
    private var preparedPGS: (id: Int, url: URL)?

    private init() throws {
        engine = try AetherEngine()
        #if os(iOS)
        engine.backgroundPlaybackEnabled = true
        #endif
    }

    enum Failure: Error { case noNativePlayer }

    /// Opens the file and returns the AVPlayer that presents it, paused at the start position.
    func load(_ request: OnDevicePlayback.Request, client: JellyfinClient, owner: AnyObject) async throws -> AVPlayer {
        clearPreparedPGS()
        self.owner = owner
        headers = request.headers
        var options = LoadOptions()
        options.httpHeaders = request.headers
        options.autoplay = false
        // Our AVPlayer surfaces need an AVPlayer; a file that would need the
        // engine's own software decoder fails here and falls back to the server.
        options.escalatesToSoftwarePath = false
        switch request.subtitle {
        case .off: break
        case .embedded(let index), .embeddedPGS(let index, _, _): options.initialSubtitleTrackID = index
        case .external(let url, let language):
            options.externalSubtitles = [ExternalSubtitleTrack(url: url, language: language, httpHeaders: request.headers)]
            options.initialSubtitleTrackID = AetherEngine.externalSubtitleTrackIDBase
        }
        #if os(tvOS)
        // The engine switches the TV's picture mode before the item loads, which
        // HDR needs on tvOS 26.5+. The player view turns AVKit's own switch off
        // while this route plays. tvOS still applies its Match Content setting.
        options.matchContentEnabled = true
        options.displayCriteriaOwner = .engine
        #endif
        _ = try await engine.load(url: request.url, startPosition: request.startSeconds > 0 ? request.startSeconds : nil,
                              options: options, audioSourceStreamIndex: request.audioStreamIndex.map(Int32.init))
        guard self.owner === owner else { throw CancellationError() }
        guard engine.videoRoute != .software, let player = engine.currentAVPlayer else {
            stop(owner: owner)
            throw Failure.noNativePlayer
        }
        preparePGS(request.subtitle, client: client)
        return player
    }

    /// Shows a different subtitle track without reopening the file.
    func selectSubtitle(_ subtitle: OnDevicePlayback.Subtitle, client: JellyfinClient) {
        clearPreparedPGS()
        switch subtitle {
        case .off: engine.clearSubtitle()
        case .embedded(let index): engine.selectSubtitleTrack(index: index)
        case .embeddedPGS(let index, _, _):
            engine.selectSubtitleTrack(index: index)
            preparePGS(subtitle, client: client)
        case .external(let url, let language):
            let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, language: language, httpHeaders: headers))
            engine.selectSubtitleTrack(index: track.id)
        }
    }

    /// A separate SUP supplies the authored bitmap packets even if the embedded demuxer has
    /// read past them during startup. Video keeps playing while the server prepares the track.
    private func preparePGS(_ subtitle: OnDevicePlayback.Subtitle, client: JellyfinClient) {
        guard case .embeddedPGS(_, let path, let language) = subtitle else { return }
        pgsDownload = Task {
            guard let file = try? await client.preparePGSFile(path: path) else { return }
            guard !Task.isCancelled else { try? FileManager.default.removeItem(at: file); return }
            let track = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: file, language: language))
            preparedPGS = (track.id, file)
            // Keep the original embedded selection, including if this sidecar cannot decode.
            // The overlay uses this second reader only when the embedded reader missed a cue.
            engine.selectSecondarySubtitleTrack(index: track.id)
        }
    }

    private func clearPreparedPGS() {
        pgsDownload?.cancel()
        pgsDownload = nil
        if let preparedPGS {
            engine.removeExternalSubtitleTrack(id: preparedPGS.id)
            try? FileManager.default.removeItem(at: preparedPGS.url)
            self.preparedPGS = nil
        }
    }

    /// Calls back on the main actor when the file ends, fails, changes state,
    /// or the engine rebuilds its session around a new AVPlayer.
    func observe(ended: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void,
                 changed: @escaping @MainActor () -> Void,
                 playerReplaced: @escaping @MainActor (AVPlayer) -> Void) -> [AnyCancellable] {
        [engine.$state.dropFirst().receive(on: DispatchQueue.main).sink { state in
            MainActor.assumeIsolated {
                switch state {
                case .ended: ended()
                case .error: failed()
                default: changed()
                }
            }
        },
        engine.$currentAVPlayer.dropFirst().receive(on: DispatchQueue.main).sink { player in
            MainActor.assumeIsolated { if let player { playerReplaced(player) } }
        }]
    }

    var position: Double { engine.clock.currentTime }
    var duration: Double? { engine.duration > 0 ? engine.duration : nil }
    var buffered: Double { engine.clock.bufferedPosition }
    func play() { engine.play() }
    func pause() { engine.pause() }
    func seek(to seconds: Double) async { await engine.seek(to: seconds, exact: true) }
    /// Positive: sound plays later. The engine re-anchors at the playhead.
    func setAudioDelay(_ seconds: Double) { engine.setAudioDelay(seconds) }
    func stop(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        clearPreparedPGS()
        engine.stop()
    }
}

/// Subtitles for files the on-device player opens: Blu-ray pictures at the
/// place the disc puts them, and text cues (including ASS colours, bold, italic
/// and `\an` / `\pos` placement) drawn over the picture.
struct OnDeviceSubtitleOverlay: View {
    @ObservedObject var engine: AetherEngine
    @ObservedObject var clock: PlaybackClock
    /// The picture fills the screen (cropped) rather than fitting inside it.
    let fill: Bool
    /// Positive: subtitles appear later. Seconds.
    let offset: Double

    init(player: OnDevicePlayer, fill: Bool = false, offset: Double = 0) {
        engine = player.engine; clock = player.engine.clock; self.fill = fill; self.offset = offset
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = videoFrame(in: geometry.size)
            let now = clock.sourceTime - offset
            ZStack(alignment: .topLeading) {
                ForEach(visibleCues(at: now)) { cue in
                    cueView(cue, in: frame)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func visibleCues(at seconds: Double) -> [SubtitleCue] {
        let visible = engine.subtitleCues.filter { $0.startTime <= seconds && seconds < $0.endTime }
        if !visible.isEmpty { return visible }
        return engine.secondarySubtitleCues.filter { $0.startTime <= seconds && seconds < $0.endTime }
    }

    /// Where the picture sits, so cues land on the video rather than the screen.
    private func videoFrame(in size: CGSize) -> CGRect {
        guard let picture = engine.currentAVPlayer?.currentItem?.presentationSize,
              picture.width > 0, picture.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let aspect = picture.width / picture.height
        let wider = size.width / size.height > aspect
        let fitted = wider != fill
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
        var frame = CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                           width: fitted.width, height: fitted.height)
        // A cropped picture keeps its text on screen.
        if fill { frame = frame.intersection(CGRect(origin: .zero, size: size)) }
        return frame
    }

    @ViewBuilder private func cueView(_ cue: SubtitleCue, in frame: CGRect) -> some View {
        switch cue.body {
        case .image(let image):
            let rect = CGRect(x: frame.minX + image.position.minX * frame.width,
                              y: frame.minY + image.position.minY * frame.height,
                              width: image.position.width * frame.width, height: image.position.height * frame.height)
            Image(decorative: image.cgImage, scale: 1).resizable().interpolation(.high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        case .text(let text):
            placed(styled([SubtitleTextRun(text: text)], height: frame.height), placement: cue.placement, in: frame)
        case .richText(let runs):
            placed(styled(runs, height: frame.height), placement: cue.placement, in: frame)
        }
    }

    private func styled(_ runs: [SubtitleTextRun], height: CGFloat) -> Text {
        let base = max(16, height / 18)
        return runs.reduce(Text("")) { line, run in
            var font = Font.system(size: run.fontSize.map { base * CGFloat($0) / 54 } ?? base, weight: run.isBold ? .bold : .semibold)
            if run.isItalic { font = font.italic() }
            var piece = Text(run.text).font(font)
            if let color = run.color {
                piece = piece.foregroundColor(Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255))
            }
            if run.isUnderlined { piece = piece.underline() }
            if run.isStruckThrough { piece = piece.strikethrough() }
            return line + piece
        }
    }

    private func placed(_ text: Text, placement: SubtitleTextPlacement?, in frame: CGRect) -> some View {
        let alignment = placement?.alignment ?? 2
        let column = (alignment - 1) % 3, row = (alignment - 1) / 3 // row 0 bottom, 2 top
        let horizontal: HorizontalAlignment = column == 0 ? .leading : column == 2 ? .trailing : .center
        let lines = text.foregroundColor(.white).multilineTextAlignment(column == 0 ? .leading : column == 2 ? .trailing : .center)
            .shadow(color: .black, radius: 1).shadow(color: .black.opacity(0.9), radius: 3)
            .frame(maxWidth: frame.width * 0.9, alignment: Alignment(horizontal: horizontal, vertical: .center))
            .fixedSize(horizontal: false, vertical: true)
        return Group {
            if let anchor = placement?.position {
                lines.position(x: frame.minX + anchor.x * frame.width, y: frame.minY + anchor.y * frame.height)
            } else {
                let vertical: VerticalAlignment = row == 0 ? .bottom : row == 2 ? .top : .center
                lines.padding(.horizontal, frame.width * 0.05).padding(.vertical, frame.height * 0.06)
                    .frame(width: frame.width, height: frame.height, alignment: Alignment(horizontal: horizontal, vertical: vertical))
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
    }
}

private extension SubtitleTextRun {
    init(text: String) {
        self.init(text: text, color: nil, isBold: false, isItalic: false, isUnderlined: false, isStruckThrough: false,
                  fontName: nil, fontSize: nil)
    }
}
