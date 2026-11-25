import SwiftUI
import AVFoundation
import ZorofinCore

/// Chapters and scrub thumbnails for the title that is playing. Images load
/// on first use (with the Authorization header) and are kept for the title.
@MainActor @Observable final class PlayerExtrasModel {
    private(set) var extras = PlayerExtras.none
    private(set) var itemID: String?
    private var mediaSourceID: String?
    @ObservationIgnored private var client: JellyfinClient?
    private var sheets: [Int: UIImage] = [:]
    private var stills: [Int: UIImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []

    /// The viewer's "Show chapters" preference. Off hides every chapter name,
    /// mark and picture; scrub thumbnails are not affected.
    var showChapters = false

    var chapters: [PlayerChapter] { showChapters ? extras.chapters : [] }
    var hasChapters: Bool { !chapters.isEmpty }

    func load(client: JellyfinClient, itemID: String, mediaSourceID: String?) async {
        reset()
        self.itemID = itemID; self.mediaSourceID = mediaSourceID; self.client = client
        guard let value = try? await client.playerExtras(itemID: itemID, mediaSourceID: mediaSourceID),
              !Task.isCancelled, self.itemID == itemID else { return }
        extras = value
    }

    func reset() {
        extras = .none; itemID = nil; mediaSourceID = nil; client = nil
        sheets = [:]; stills = [:]; requested = []
    }

    /// The chapter playing at `seconds`.
    func chapterIndex(at seconds: Double) -> Int? { PlayerChapter.index(in: chapters, at: seconds) }
    func chapterName(at seconds: Double) -> String? { chapterIndex(at: seconds).map { chapters[$0].name } }

    /// The sheet image if it has arrived; asks for it otherwise.
    func sheet(_ index: Int) -> UIImage? {
        if let image = sheets[index] { return image }
        guard let trickplay = extras.trickplay, let client, let itemID, requested.insert("sheet-\(index)").inserted else { return nil }
        let source = mediaSourceID
        Task { [weak self] in
            guard let data = try? await client.trickplaySheet(itemID: itemID, trickplay: trickplay, sheet: index, mediaSourceID: source),
                  let image = UIImage(data: data), let self, self.itemID == itemID else { return }
            self.sheets[index] = image
        }
        return nil
    }

    func still(_ chapter: PlayerChapter) -> UIImage? {
        if let image = stills[chapter.imageIndex] { return image }
        guard chapter.imageTag != nil, let client, let itemID, requested.insert("still-\(chapter.imageIndex)").inserted else { return nil }
        Task { [weak self] in
            guard let data = try? await client.chapterImage(itemID: itemID, chapter: chapter),
                  let image = UIImage(data: data), let self, self.itemID == itemID else { return }
            self.stills[chapter.imageIndex] = image
        }
        return nil
    }
}

/// What floats over the timeline while scrubbing: the frame (when the server
/// made trickplay images), the time, and the chapter it lands in.
struct ScrubPreviewCard: View {
    let extras: PlayerExtrasModel
    let seconds: Double
    var width: CGFloat = Theme.isTV ? 320 : 176

    var body: some View {
        VStack(spacing: 4) {
            if let trickplay = extras.extras.trickplay {
                let frame = trickplay.frame(at: seconds)
                let height = width * CGFloat(trickplay.height) / CGFloat(trickplay.width)
                ZStack(alignment: .topLeading) {
                    Color.white.opacity(0.08)
                    if let sheet = extras.sheet(frame.sheet) {
                        Image(uiImage: sheet).resizable().interpolation(.medium)
                            .frame(width: width * CGFloat(trickplay.tileWidth), height: height * CGFloat(trickplay.tileHeight))
                            .offset(x: -CGFloat(frame.column) * width, y: -CGFloat(frame.row) * height)
                    }
                }.frame(width: width, height: height, alignment: .topLeading).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.isTV ? 10 : 7))
            }
            Text(PlayerTimeline.timeLabel(seconds))
                .font(Theme.font(Theme.isTV ? 22 : 14, weight: .semibold)).monospacedDigit()
            if let chapter = extras.chapterName(at: seconds) {
                Text(chapter).font(Theme.font(Theme.isTV ? 17 : 12)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1).frame(maxWidth: extras.extras.trickplay == nil ? (Theme.isTV ? 320 : 176) : width)
            }
        }
        .padding(.horizontal, extras.extras.trickplay == nil ? 12 : 4).padding(.top, 4).padding(.bottom, 6)
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.09, blue: 0.09).opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.isTV ? 14 : 10))
        .overlay(RoundedRectangle(cornerRadius: Theme.isTV ? 14 : 10).stroke(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.5), radius: 12)
        .fixedSize().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Chapter breaks drawn on the timeline track.
struct ChapterMarks: View {
    let timeline: PlayerTimeline
    let chapters: [PlayerChapter]
    var body: some View {
        GeometryReader { geometry in
            ForEach(chapters.dropFirst()) { chapter in
                Rectangle().fill(.black.opacity(0.75)).frame(width: 2, height: 9)
                    .offset(x: geometry.size.width * timeline.fraction(at: chapter.start) - 1)
            }.frame(maxHeight: .infinity, alignment: .center)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The chapter list in the player options: stills with names and start times;
/// the playing chapter is marked and focused first on TV.
struct ChapterChoices: View {
    let extras: PlayerExtrasModel
    let position: Double
    let select: (PlayerChapter) -> Void

    var body: some View {
        let current = extras.chapterIndex(at: position)
        ScrollViewReader { proxy in
            #if os(tvOS)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(Array(extras.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Button { select(chapter) } label: {
                            card(chapter, number: index + 1, playing: index == current)
                        }.buttonStyle(.card)
                            .playerOptionsDefaultFocus(index == (current ?? 0))
                            .id(chapter.id)
                    }
                }.padding(.vertical, 30).padding(.horizontal, 8)
            }.scrollClipDisabled()
                .onAppear { if let current { proxy.scrollTo(extras.chapters[current].id, anchor: .center) } }
            #else
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(extras.chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button { select(chapter) } label: {
                        row(chapter, number: index + 1, playing: index == current)
                    }.buttonStyle(FlatOptionStyle()).id(chapter.id)
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                }
            }.onAppear { if let current { proxy.scrollTo(extras.chapters[current].id, anchor: .center) } }
            #endif
        }
    }

    @ViewBuilder private func still(_ chapter: PlayerChapter, number: Int, width: CGFloat) -> some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image = extras.still(chapter) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Text("\(number)").font(Theme.font(width / 6, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }.frame(width: width, height: width * 9 / 16).clipped()
    }

    #if os(tvOS)
    private func card(_ chapter: PlayerChapter, number: Int, playing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            still(chapter, number: number, width: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(playing ? Theme.jade : .clear, lineWidth: 4))
            Text(chapter.name).font(Theme.font(22, weight: .semibold)).lineLimit(1)
                .foregroundStyle(Theme.text).frame(width: 320, alignment: .leading)
            Text(playing ? "Playing · " + PlayerTimeline.timeLabel(chapter.start) : PlayerTimeline.timeLabel(chapter.start))
                .font(Theme.font(18)).foregroundStyle(playing ? Theme.jade : Theme.muted)
        }.accessibilityElement(children: .combine)
            .accessibilityLabel("\(chapter.name), \(PlayerTimeline.timeLabel(chapter.start))\(playing ? ", playing" : "")")
    }
    #else
    private func row(_ chapter: PlayerChapter, number: Int, playing: Bool) -> some View {
        HStack(spacing: 14) {
            still(chapter, number: number, width: 112)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(playing ? Theme.jade : .clear, lineWidth: 2))
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.name).font(Theme.font(17, weight: playing ? .semibold : .regular)).lineLimit(2)
                    .foregroundStyle(Theme.text)
                Text(playing ? "Playing · " + PlayerTimeline.timeLabel(chapter.start) : PlayerTimeline.timeLabel(chapter.start))
                    .font(Theme.font(13)).monospacedDigit().foregroundStyle(playing ? Theme.jade : Theme.muted)
            }
            Spacer(minLength: 4)
        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(chapter.name), \(PlayerTimeline.timeLabel(chapter.start))\(playing ? ", playing" : "")")
    }
    #endif
}

/// "Subtitle timing   ‹ +0.3 s ›". On TV, Left and Right move it in 0.1 s
/// steps and Select resets it; on iPhone the buttons step and the value resets.
struct TimingRow: View {
    let title: String
    let value: Double
    var hint = "Left: earlier · Right: later · Select: reset"
    let change: (Double) -> Void
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    private func step(_ direction: Double) {
        let next = TrackMemory.clamp(value + TrackMemory.step * direction)
        if next != value { change(next) }
    }

    var body: some View {
        #if os(tvOS)
        Button { change(0) } label: {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.font(24))
                    if focused { Text(hint).font(Theme.font(17)).foregroundStyle(Theme.muted) }
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.left").opacity(focused ? 1 : 0.4)
                Text(TrackMemory.label(value)).font(Theme.font(23, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 110).foregroundStyle(value == 0 ? Theme.muted : Theme.text)
                Image(systemName: "chevron.right").opacity(focused ? 1 : 0.4)
            }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }.buttonStyle(FlatOptionStyle()).focused($focused)
            .onMoveCommand { direction in
                switch direction {
                case .left: step(-1)
                case .right: step(1)
                default: break
                }
            }
            .accessibilityLabel(title).accessibilityValue(TrackMemory.label(value))
            .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
        #else
        HStack(spacing: 10) {
            Text(title).font(Theme.font(17))
            Spacer(minLength: 8)
            Button { step(-1) } label: { Image(systemName: "minus").frame(width: 40, height: 40) }
                .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("Earlier")
            Button { change(0) } label: {
                Text(TrackMemory.label(value)).font(Theme.font(16, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 76).foregroundStyle(value == 0 ? Theme.muted : Theme.text)
            }.buttonStyle(.plain).accessibilityLabel("Reset \(title.lowercased())").disabled(value == 0)
            Button { step(1) } label: { Image(systemName: "plus").frame(width: 40, height: 40) }
                .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("Later")
        }.tint(Theme.text).frame(minHeight: 52)
            .accessibilityElement(children: .contain)
        #endif
    }
}

/// Draws AVPlayer's own text subtitles earlier or later than the stream has
/// them. AVPlayer has no subtitle delay, so while an offset is set the app
/// takes the cues from the item and draws them itself. At zero nothing is
/// attached and the system draws them as before.
@MainActor @Observable final class ShiftedSubtitles: NSObject, @preconcurrency AVPlayerItemLegibleOutputPushDelegate {
    private(set) var text = ""
    @ObservationIgnored private var output: AVPlayerItemLegibleOutput?
    @ObservationIgnored private weak var item: AVPlayerItem?
    @ObservationIgnored private var offset = 0.0
    /// Bumped whenever waiting cues stop being valid (a seek, a new offset).
    @ObservationIgnored private var epoch = 0

    /// Positive `offset`: later. Zero, or no item, hands drawing back to AVPlayer.
    func apply(offset: Double, to item: AVPlayerItem?) {
        guard offset != self.offset || item !== self.item else { return }
        detach()
        guard let item, offset != 0 else { return }
        self.offset = offset
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = true
        // Earlier: ask for each cue ahead of its time and show it at once.
        output.advanceIntervalForDelegateInvocation = offset < 0 ? -offset : 0
        output.setDelegate(self, queue: .main)
        item.add(output)
        self.output = output; self.item = item
    }

    func detach() {
        epoch += 1
        if let output, let item, item.outputs.contains(output) { item.remove(output) }
        output = nil; item = nil; offset = 0; text = ""
    }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        guard output === self.output else { return }
        let next = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Later: every change (a cue, or the empty one that clears it) waits
        // the same time, so they still arrive in order.
        guard offset > 0 else { text = next; return }
        let epoch = epoch, delay = offset
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.epoch == epoch else { return }
            self.text = next
        }
    }

    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        guard output === self.output else { return }
        epoch += 1; text = ""
    }
}

struct ShiftedSubtitleOverlay: View {
    let subtitles: ShiftedSubtitles

    var body: some View {
        GeometryReader { geometry in
            if !subtitles.text.isEmpty {
                Text(subtitles.text)
                    .font(.system(size: max(16, geometry.size.height / 18), weight: .semibold))
                    .foregroundStyle(.white).multilineTextAlignment(.center)
                    .shadow(color: .black, radius: 1).shadow(color: .black.opacity(0.9), radius: 3)
                    .frame(maxWidth: geometry.size.width * 0.9).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, geometry.size.height * 0.06)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
