import Foundation
import Testing
@testable import ZorofinCore

private func qualityItem(_ extra: String, type: String = "Movie") throws -> MediaItem {
    try Wire.decoder().decode(MediaItem.self, from: Data("{\"Id\":\"fixture\",\"Name\":\"4K Dolby Vision Atmos is only a title\",\"Type\":\"\(type)\",\(extra)}".utf8))
}

@Suite("Source-file quality") struct MediaQualityTests {
    @Test func ordinaryJellyfinListMetadataSupportsCroppedVideo() throws {
        let item = try qualityItem(#""MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"Height":1600,"Codec":"hevc","VideoRangeType":"DOVIWithHDR10","BitDepth":10}]"#)
        #expect(item.quality().thumbnailBadges == ["4K", "DV"])
        #expect(item.quality().badges.contains("HEVC"))
        #expect(item.quality().facts.contains { $0.title == "Resolution" && $0.value == "3840 × 1600" })
        #expect(item.quality().facts.contains { $0.value == "10-bit" })
    }
    @Test func titleCodecAndBitDepthCannotInventHDRorAtmos() throws {
        let item = try qualityItem(#""MediaStreams":[{"Index":0,"Type":"Video","Width":1920,"Height":800,"Codec":"hevc","BitDepth":10},{"Index":1,"Type":"Audio","Codec":"eac3","Channels":6}]"#)
        #expect(item.quality().thumbnailBadges == ["1080p"])
        #expect(item.quality().dynamicRange == nil)
        #expect(item.quality().spatialAudio == nil)
        #expect(item.quality().audioLayout == "6 channels")
        #expect(item.quality().container == nil)
    }
    @Test(arguments: ["DOVI", "DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR", "DOVIWithEL", "DOVIWithHDR10Plus", "DOVIWithELHDR10Plus"])
    func recognizedDolbyVisionVariants(_ range: String) throws {
        let item = try qualityItem("\"MediaStreams\":[{\"Index\":0,\"Type\":\"Video\",\"VideoRangeType\":\"\(range)\"}]")
        #expect(item.quality().dynamicRange == "Dolby Vision")
    }
    @Test(arguments: ["DOVIInvalid", "DOVISomethingNew", "Unknown"])
    func invalidAndUnknownRangesDoNotClaimDolbyVision(_ range: String) throws {
        let item = try qualityItem("\"MediaStreams\":[{\"Index\":0,\"Type\":\"Video\",\"VideoRangeType\":\"\(range)\"}]")
        #expect(item.quality().dynamicRange == nil)
        #expect(item.quality().thumbnailBadges.isEmpty)
    }
    @Test func explicitHDRAndSDRFallbacks() throws {
        let hdr = try qualityItem(#""MediaStreams":[{"Index":0,"Type":"Video","VideoRangeType":"HDR10Plus"}]"#)
        let sdr = try qualityItem(#""MediaStreams":[{"Index":0,"Type":"Video","Width":720,"Height":480,"VideoRange":"SDR"}]"#)
        #expect(hdr.quality().dynamicRange == "HDR10+")
        #expect(sdr.quality().dynamicRange == "SDR")
        #expect(sdr.quality().thumbnailBadges == ["SD"])
    }
    @Test func multipleVersionsNeverCombineQualityClaims() throws {
        let item = try qualityItem(#""MediaSources":[{"Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"Height":1600,"VideoRange":"SDR"}]},{"Container":"mp4","MediaStreams":[{"Index":0,"Type":"Video","Width":1920,"Height":1080,"VideoRangeType":"DOVI"}]}]"#)
        #expect(item.quality().thumbnailBadges == ["4K"])
        #expect(item.fileQualities.map(\.container) == ["MKV", "MP4"])
        #expect(item.fileQualities[1].thumbnailBadges == ["1080p", "DV"])
        var cached = item; cached.removePlaybackSources()
        #expect(cached.mediaSources == nil)
        #expect(cached.quality().thumbnailBadges == item.quality().thumbnailBadges)
        #expect(cached.container == "mkv")
    }
    @Test func selectedAudioAndOlderProfileMetadata() throws {
        let item = try qualityItem(#""MediaSources":[{"DefaultAudioStreamIndex":1,"MediaStreams":[{"Index":0,"Type":"Video","Width":1920},{"Index":1,"Type":"Audio","Codec":"aac","Channels":2},{"Index":2,"Type":"Audio","Codec":"truehd","AudioSpatialFormat":"DolbyAtmos","ChannelLayout":"7.1"},{"Index":3,"Type":"Audio","Codec":"dts","Profile":"DTS-HD MA + DTS:X"}]}]"#)
        #expect(item.quality().spatialAudio == nil)
        #expect(item.quality().audioLayout == "Stereo")
        #expect(item.quality(audioIndex: 2).spatialAudio == "Dolby Atmos")
        #expect(item.quality(audioIndex: 2).audioLayout == "7.1")
        #expect(item.quality(audioIndex: 3).spatialAudio == "DTS:X")
        #expect(item.quality(audioIndex: 99).audioLayout == "Stereo")
    }
    @Test func emptyMetadataAndSeriesDoNotClaimAFileFormat() throws {
        let missing = MediaItem(id: "empty", name: "4K HDR Dolby Vision")
        #expect(missing.quality().badges.isEmpty)
        #expect(missing.quality().facts.isEmpty)
        let series = try qualityItem(#""Container":"mkv","MediaStreams":[{"Index":0,"Type":"Video","Width":3840,"VideoRangeType":"DOVI"}]"#, type: "Series")
        #expect(series.quality().badges.isEmpty)
        #expect(series.fileQualities.isEmpty)
    }
    @Test func fileDetailsUseOnlyKnownSourceFields() throws {
        let item = try qualityItem(#""MediaSources":[{"Container":"mkv","Size":2500000000,"Bitrate":24000000,"Path":"/private/file.mkv","TranscodingUrl":"/secret","MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","AverageFrameRate":23.976}]}]"#)
        #expect(item.quality().facts.contains { $0.title == "File bitrate" && $0.value == "24.0 Mbps" })
        #expect(item.quality().facts.contains { $0.title == "File size" })
        let expectedRate = 23.976.formatted(.number.precision(.fractionLength(0...3))) + " fps"
        #expect(item.quality().facts.contains { $0.title == "Frame rate" && $0.value == expectedRate })
        #expect(item.quality().facts.contains { $0.title == "Video codec" && $0.value == "H.264" })
        #expect(!item.quality().facts.contains { $0.value.contains("private") || $0.value.contains("secret") })
    }
    @Test func homeRowMovesOnlyKnownFormatLabelsOntoArtwork() {
        let card = HomeRowCard(id: "fixture", item: .init(id: "fixture", name: "Movie"), subtitle: "", badges: ["4K", "Dolby Vision", "Ready to watch", "HDR-ish"])
        #expect(card.qualityBadges == ["4K", "Dolby Vision"])
        #expect(card.contextBadges == ["Ready to watch", "HDR-ish"])
    }
}
