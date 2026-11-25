/// Text subtitles for remuxed streams arrive as WebVTT renditions in the HLS
/// manifest instead of being burned into the video. When a subtitle is chosen,
/// Jellyfin lists every text track it can deliver that way, names each
/// rendition after the track's display title, and marks the requested one
/// DEFAULT=YES. With subtitles off the manifest has no subtitle renditions.
public enum ManifestSubtitleMatch {
    /// The manifest rendition to show for a stream, `.off` to hide subtitles,
    /// or nil when the change needs a new stream (image subtitles, a track the
    /// manifest does not carry, or names that do not identify one rendition).
    public enum Choice: Equatable, Sendable { case off, option(Int) }

    public static func choice(for streamIndex: Int, streams: [MediaStream], optionNames: [String]) -> Choice? {
        if streamIndex == -1 { return .off }
        guard let stream = streams.first(where: { $0.index == streamIndex && $0.type == "Subtitle" }),
              let codec = stream.codec?.lowercased(), PlaybackProfile.manifestSubtitleFormats.contains(codec),
              let title = stream.displayTitle, !title.isEmpty else { return nil }
        let matches = optionNames.indices.filter { optionNames[$0] == title }
        guard matches.count == 1,
              streams.filter({ $0.type == "Subtitle" && $0.displayTitle == title }).count == 1 else { return nil }
        return .option(matches[0])
    }
}

#if canImport(AVFoundation)
import AVFoundation

@MainActor public enum ManifestSubtitles {
    /// Show the rendition the server marked as requested, or none.
    public static func applyServerSelection(to item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        item.select(group.defaultOption, in: group)
    }

    /// Switch subtitles inside the current stream without asking the server
    /// for a new one. Returns false when the caller has to renegotiate.
    public static func select(streamIndex: Int, streams: [MediaStream], in item: AVPlayerItem) async -> Bool {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return false }
        switch ManifestSubtitleMatch.choice(for: streamIndex, streams: streams, optionNames: group.options.map(\.displayName)) {
        case .off?:
            guard group.allowsEmptySelection else { return false }
            item.select(nil, in: group)
        case .option(let index)?:
            item.select(group.options[index], in: group)
        case nil:
            return false
        }
        return true
    }
}
#endif
