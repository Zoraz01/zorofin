' Source-file quality, the same cases as the Apple MediaQualityTests.

sub Test_Quality_CroppedDolbyVisionFile()
    q = ZQuality({ Type: "Movie", MediaStreams: [{ Index: 0, Type: "Video", Width: 3840, Height: 1600, Codec: "hevc", VideoRangeType: "DOVIWithHDR10", BitDepth: 10 }] })
    AssertEqual(q.badges, ["4K", "Dolby Vision", "HEVC"], "badges")
    AssertTrue(QualityHasFact(q, "Resolution", "3840 × 1600"), "cropped resolution")
    AssertTrue(QualityHasFact(q, "Bit depth", "10-bit"), "bit depth")
end sub

sub Test_Quality_NoInventedHdrOrAtmos()
    q = ZQuality({ Type: "Movie", MediaStreams: [{ Index: 0, Type: "Video", Width: 1920, Height: 800, Codec: "hevc", BitDepth: 10 }, { Index: 1, Type: "Audio", Codec: "eac3", Channels: 6 }] })
    AssertEqual(q.badges, ["1080p", "HEVC", "Dolby Digital Plus", "6 channels"], "no range, no Atmos, no container")
    AssertEqual(ZQuality({ Type: "Movie", MediaStreams: [{ Type: "Video", VideoRangeType: "DOVIInvalid" }] }).dynamicRange, "", "invalid DV")
    AssertEqual(ZQuality({ Type: "Movie", MediaStreams: [{ Type: "Video", VideoRangeType: "DOVIWithSDR" }] }).dynamicRange, "Dolby Vision", "DV variant")
    AssertEqual(ZQuality({ Type: "Movie", MediaStreams: [{ Type: "Video", Width: 720, Height: 480, VideoRange: "SDR" }] }).badges, ["SD", "SDR"], "SDR fallback")
end sub

sub Test_Quality_SelectedAudioTrack()
    json = { Type: "Movie", MediaSources: [{ DefaultAudioStreamIndex: 1, MediaStreams: [
        { Index: 0, Type: "Video", Width: 1920 },
        { Index: 1, Type: "Audio", Codec: "aac", Channels: 2 },
        { Index: 2, Type: "Audio", Codec: "truehd", AudioSpatialFormat: "DolbyAtmos", ChannelLayout: "7.1" },
        { Index: 3, Type: "Audio", Codec: "dts", Profile: "DTS-HD MA + DTS:X" }
    ] }] }
    AssertEqual(ZQuality(json).badges, ["1080p", "AAC", "Stereo"], "default track")
    AssertEqual(ZQuality(json, 2).badges, ["1080p", "Dolby Atmos", "TrueHD", "7.1"], "Atmos track")
    AssertEqual(ZQuality(json, 3).badges, ["1080p", "DTS:X", "DTS"], "DTS:X from profile")
    AssertEqual(ZQuality(json, 99).badges, ["1080p", "AAC", "Stereo"], "unknown index falls back")
end sub

sub Test_Quality_SeriesAndEmptyHaveNone()
    AssertEqual(ZQuality({ Type: "Movie" }).badges.count(), 0, "empty")
    AssertEqual(ZQuality({ Type: "Series", Container: "mkv", MediaStreams: [{ Type: "Video", Width: 3840 }] }).facts.count(), 0, "series")
end sub

sub Test_Quality_FileFacts()
    q = ZQuality({ Type: "Movie", MediaSources: [{ Container: "mkv", Size: 2500000000, Bitrate: 24000000, Path: "/private/file.mkv", MediaStreams: [{ Index: 0, Type: "Video", Codec: "h264", AverageFrameRate: 23.976 }] }] })
    AssertTrue(QualityHasFact(q, "File format", "MKV"), "format")
    AssertTrue(QualityHasFact(q, "File size", "2.5 GB"), "size")
    AssertTrue(QualityHasFact(q, "File bitrate", "24.0 Mbps"), "bitrate")
    AssertTrue(QualityHasFact(q, "Frame rate", "23.976 fps"), "frame rate")
    AssertTrue(QualityHasFact(q, "Video codec", "H.264"), "codec")
    for each f in q.facts
        AssertTrue(Instr(1, f.value, "private") = 0, "no paths")
    end for
    AssertEqual(ZQuality({ Type: "Movie", MediaSources: [{ Container: "mov,mp4,m4a" }] }).badges, ["MOV"], "one container")
end sub

function QualityHasFact(q as object, title as string, value as string) as boolean
    for each f in q.facts
        if f.title = title and f.value = value then return true
    end for
    return false
end function
