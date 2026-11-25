import Foundation
import Testing
@testable import ZorofinCore

@Suite("Remux audio and manifest subtitles") struct ManifestSubtitleProfileTests {
    private func profile(manifestSubtitles: Bool) throws -> [String: Any] {
        let data = try JSONEncoder().encode(PlaybackProfile.avPlayer(bitrate: 40_000_000, hevc: true,
                                                                     manifestSubtitles: manifestSubtitles))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func methods(_ profile: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in profile["SubtitleProfiles"] as? [[String: Any]] ?? [] {
            if let format = entry["Format"] as? String { result[format] = entry["Method"] as? String }
        }
        return result
    }

    @Test func remuxCopiesDolbyAudio() throws {
        let hls = try #require((try profile(manifestSubtitles: false)["TranscodingProfiles"] as? [[String: Any]])?.first)
        #expect(hls["Container"] as? String == "mp4")
        #expect(hls["AudioCodec"] as? String == "aac,ac3,eac3")
        #expect(hls["MaxAudioChannels"] as? String == "8")
        let rules = try #require(try profile(manifestSubtitles: false)["CodecProfiles"] as? [[String: Any]])
        for (codec, limit) in [("aac", "6"), ("ac3", "6"), ("eac3", "8")] {
            let rule = try #require(rules.first { $0["Type"] as? String == "VideoAudio" && $0["Codec"] as? String == codec })
            let conditions = try #require(rule["Conditions"] as? [[String: Any]])
            #expect(conditions.first { $0["Property"] as? String == "AudioChannels" }?["Value"] as? String == limit)
        }
    }

    @Test func textSubtitlesTravelInTheManifestWhenRequested() throws {
        let on = try profile(manifestSubtitles: true)
        let hls = try #require((on["TranscodingProfiles"] as? [[String: Any]])?.first)
        #expect(hls["EnableSubtitlesInManifest"] as? Bool == true)
        let chosen = methods(on)
        #expect(chosen["subrip"] == "Hls" && chosen["ass"] == "Hls" && chosen["webvtt"] == "Hls")
        #expect(chosen["pgssub"] == "Encode" && chosen["dvdsub"] == "Encode")
        // The live TS fallback never carries manifest subtitles.
        let live = (on["TranscodingProfiles"] as? [[String: Any]] ?? []).filter { $0["Container"] as? String == "ts" }
        #expect(live.allSatisfy { $0["EnableSubtitlesInManifest"] as? Bool == false })
    }

    @Test func downloadsAndLiveTVKeepBurnIn() throws {
        let off = try profile(manifestSubtitles: false)
        #expect(methods(off).values.allSatisfy { $0 == "Encode" })
        let options = PlaybackOptions(subtitleIndex: 3)
        #expect(!options.manifestSubtitles)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PlaybackProfile.request(userID: "u", options: options))) as? [String: Any])
        #expect(body["AlwaysBurnInSubtitleWhenTranscoding"] as? Bool == true)
    }

    @Test func playersWithoutHEVCKeepTheCompatibilityProfile() {
        #expect(PlaybackProfile.avPlayer(bitrate: 40_000_000, hevc: false, manifestSubtitles: true)
                == PlaybackProfile.conservative(bitrate: 40_000_000))
    }
}
