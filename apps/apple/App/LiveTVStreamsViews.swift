import SwiftUI
import UIKit
import ZorofinCore

/// Polls the companion's Live TV stream status while the screen is visible,
/// the app is in the foreground and the server offers it.
private struct LiveTVStreamsPolling: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    var channelID: String?
    @Binding var status: LiveTVStreams?
    func body(content: Content) -> some View {
        content.task(id: "\(model.generation)-\(model.features.liveTvStreams)-\(scenePhase == .active)-\(channelID ?? "")") {
            status = nil
            guard model.features.liveTvStreams, !model.isDemo, scenePhase == .active, let client = model.client else { return }
            let generation = model.generation
            while !Task.isCancelled {
                let fresh = try? await client.liveTVStreams(channelID: channelID)
                guard !Task.isCancelled, generation == model.generation, scenePhase == .active else { return }
                status = fresh
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
}

/// Channel logo from the server, with the channel's initials while it loads or if it has none.
struct LiveTVChannelLogo: View {
    @Environment(AppModel.self) private var model
    let channelID: String
    let name: String
    var size: CGFloat
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.19).fill(Color(hex: 0x0d110f))
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.12)
            } else {
                Text(String(name.prefix(3)).uppercased())
                    .font(Theme.font(size * 0.24, weight: .bold)).foregroundStyle(Theme.muted)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: channelID) {
            guard let client = model.client else { return }
            if let data = try? await client.image(itemID: channelID, kind: "Primary", width: Int(size * 3)) {
                image = UIImage(data: data)
            }
        }
    }
}

/// The "LIVE" capsule used on Live TV cards.
struct LiveTVLiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(Theme.font(Theme.isTV ? 15 : 11, weight: .heavy)).tracking(1.2)
            .foregroundStyle(Theme.jade)
            .padding(.horizontal, Theme.isTV ? 10 : 8).padding(.vertical, Theme.isTV ? 5 : 3)
            .background(Color(hex: 0x05120a).opacity(0.9), in: Capsule())
            .overlay(Capsule().stroke(Theme.jade.opacity(0.55), lineWidth: 1))
    }
}

/// One channel in use: logo, LIVE, channel, show, "2 watching · 18 min left".
struct LiveTVStreamSummary: View {
    let stream: LiveTVStreams.Stream
    var showDetail = true
    var body: some View {
        HStack(spacing: Theme.isTV ? 18 : 12) {
            LiveTVChannelLogo(channelID: stream.channelId, name: stream.channelName, size: Theme.isTV ? 80 : 56)
            VStack(alignment: .leading, spacing: Theme.isTV ? 5 : 3) {
                HStack(spacing: 8) {
                    LiveTVLiveBadge()
                    Text(stream.channelName).font(Theme.font(Theme.isTV ? 26 : 17, weight: .bold)).lineLimit(1)
                }
                if let title = stream.programme?.title, !title.isEmpty {
                    Text(title).font(Theme.font(Theme.isTV ? 21 : 15)).foregroundStyle(Theme.text).lineLimit(1)
                }
                if showDetail {
                    Text(stream.detail()).font(Theme.font(Theme.isTV ? 18 : 13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
        }
    }
}

/// "Playing now" on the Live TV screen: each channel using a stream, with Join.
/// Hidden when nothing is playing or the server doesn't offer it.
struct LiveTVStreamsStrip: View {
    @Environment(AppModel.self) private var model
    let play: (MediaItem) -> Void
    @State private var status: LiveTVStreams?
    var body: some View {
        Group {
            if model.features.liveTvStreams, let status {
                VStack(alignment: .leading, spacing: Theme.isTV ? 14 : 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.isTV ? 24 : 12) {
                            ForEach(status.streams) { stream in card(stream) }
                        }.padding(.vertical, Theme.isTV ? 12 : 2)
                    }
                    #if os(tvOS)
                    .scrollClipDisabled()
                    #endif
                    Text(status.summary).font(Theme.font(Theme.isTV ? 19 : 14)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("live-tv-streams")
            }
        }
        .modifier(LiveTVStreamsPolling(channelID: nil, status: $status))
    }
    private func card(_ stream: LiveTVStreams.Stream) -> some View {
        HStack(spacing: Theme.isTV ? 20 : 12) {
            LiveTVStreamSummary(stream: stream)
            Spacer(minLength: 8)
            Button(stream.yours ? "Watching" : "Join") { play(stream.channel) }
                .buttonStyle(ZoroButtonStyle(primary: !stream.yours))
                .accessibilityLabel(stream.yours ? "You are watching \(stream.channelName)" : "Join \(stream.channelName)")
        }
        .padding(Theme.isTV ? 20 : 14)
        .frame(width: Theme.isTV ? 600 : 330, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(stream.yours ? Theme.jade.opacity(0.45) : Theme.border, lineWidth: 1))
        .foregroundStyle(Theme.text)
    }
}

/// One line under a channel's Play button: who's on this channel, or which
/// channel is using the last stream (with "Watch ESPN").
struct LiveTVStreamsLine: View {
    @Environment(AppModel.self) private var model
    let channelID: String
    let play: (MediaItem) -> Void
    @State private var status: LiveTVStreams?
    var body: some View {
        Group {
            if model.features.liveTvStreams, let status, let line = status.channelLine(for: channelID) {
                let playing = status.stream(for: channelID) != nil
                let join = status.blocked(channelID: channelID)?.join
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { dot(playing); text(line); if let join { button(join) } }
                    VStack(alignment: .leading, spacing: 10) { HStack(spacing: 12) { dot(playing); text(line) }; if let join { button(join) } }
                }
                .accessibilityIdentifier("live-tv-stream-line")
            }
        }
        .modifier(LiveTVStreamsPolling(channelID: channelID, status: $status))
    }
    private func dot(_ playing: Bool) -> some View {
        Circle().fill(playing ? Theme.jade : Color(hex: 0xe0b44a)).frame(width: 9, height: 9)
            .background(Circle().fill((playing ? Theme.jade : Color(hex: 0xe0b44a)).opacity(0.2)).frame(width: 17, height: 17))
            .accessibilityHidden(true)
    }
    private func text(_ line: String) -> some View {
        Text(line).font(Theme.font(Theme.isTV ? 22 : 15)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
    }
    private func button(_ stream: LiveTVStreams.Stream) -> some View {
        Button("Watch \(stream.channelName)") { play(stream.channel) }.buttonStyle(ZoroButtonStyle())
    }
}

/// What the "Live TV is in use" alert shows.
struct LiveTVConflictAlert: Equatable {
    var title = "Live TV is in use"
    var message: String
    var join: MediaItem?
    init(message: String) { self.message = message }
    init(_ blocked: LiveTVStreams.Blocked) {
        title = blocked.title
        message = blocked.text + " " + blocked.hint
        join = blocked.join?.channel
    }
}
