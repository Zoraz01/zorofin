import Foundation
import Testing
@testable import ZorofinCore

@Suite("4K playback capabilities") struct PlaybackCapabilitiesTests {
    @Test func hardwareHEVCProfileSupports4KAndHDRButDoesNotClaimMKV() throws {
        let data = try JSONEncoder().encode(PlaybackProfile.avPlayer(bitrate: 60_000_000, hevc: true))
        let profile = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let direct = (profile["DirectPlayProfiles"] as! [[String: Any]])[0]
        #expect((direct["VideoCodec"] as! String).contains("hevc"))
        #expect(!(direct["Container"] as! String).contains("mkv"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("2160")); #expect(text.contains("153"))
        let codecs = profile["CodecProfiles"] as! [[String: Any]]
        func ranges(_ codec: String) -> String? {
            codecs.first { $0["Codec"] as? String == codec && $0["ApplyConditions"] == nil && $0["Container"] == nil }
                .flatMap { ($0["Conditions"] as? [[String: Any]])?.first { $0["Property"] as? String == "VideoRangeType" } }?["Value"] as? String
        }
        #expect(ranges("h264") == "SDR")
        let hevc = try #require(ranges("hevc")).split(separator: "|").map(String.init)
        #expect(hevc.contains("HDR10") && hevc.contains("HLG") && hevc.contains("DOVIWithHDR10"))
        #expect(!hevc.contains("DOVIWithEL"))
        let tagged = try #require(codecs.first { $0["Container"] as? String == "mp4,m4v,mov" })
        #expect(String(decoding: try JSONSerialization.data(withJSONObject: tagged), as: UTF8.self).contains("hvc1|dvh1"))
        let transcode = (profile["TranscodingProfiles"] as! [[String: Any]])[0]
        #expect(transcode["Container"] as? String == "mp4")
        let live = (profile["TranscodingProfiles"] as! [[String: Any]]).filter { $0["Container"] as? String == "ts" }
        #expect(live.count == 1)
        #expect(live.first?["Protocol"] as? String == "hls")
        #expect(live.first?["VideoCodec"] as? String == "h264")
        #expect(live.first?["AudioCodec"] as? String == "aac")
    }
    @Test func hdSportsKeep60FPSWithoutRaisingThe4KCeiling() throws {
        let data = try JSONEncoder().encode(PlaybackProfile.avPlayer(bitrate: 40_000_000, hevc: true))
        let profile = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let codecs = profile["CodecProfiles"] as! [[String: Any]]
        func accepts(_ codec: String, width: Int, height: Int, fps: Int) -> Bool {
            let values = ["Width": width, "Height": height, "VideoFramerate": fps]
            func passes(_ condition: [String: Any]) -> Bool {
                guard let actual = values[condition["Property"] as! String] else { return true }
                let limit = Int(condition["Value"] as! String)!
                return condition["Condition"] as? String == "GreaterThanEqual" ? actual >= limit : actual <= limit
            }
            return codecs.filter { $0["Codec"] as? String == codec &&
                (($0["ApplyConditions"] as? [[String: Any]]) ?? []).allSatisfy(passes)
            }.allSatisfy { ($0["Conditions"] as! [[String: Any]]).allSatisfy(passes) }
        }
        for codec in ["h264", "hevc"] {
            #expect(accepts(codec, width: 1920, height: 1080, fps: 60))
            #expect(accepts(codec, width: 3840, height: 2160, fps: 30))
            #expect(!accepts(codec, width: 3840, height: 2160, fps: 60))
            #expect(!accepts(codec, width: 2560, height: 1080, fps: 60))
            #expect(!accepts(codec, width: 1920, height: 1200, fps: 60))
        }
    }
    @Test func unknownHardwareKeepsCompatibilityAndHigherCeilingsAreExplicit() throws {
        #expect(PlaybackProfile.avPlayer(bitrate: 40_000_000, hevc: false) == PlaybackProfile.conservative(bitrate: 40_000_000))
        #expect(PlaybackOptions().bitrate == 40_000_000)
        #expect(PlaybackOptions(bitrate: 120_000_000).bitrate == 120_000_000)
        #expect(PlaybackOptions(bitrate: 999_000_000).bitrate == 120_000_000)
    }
}
