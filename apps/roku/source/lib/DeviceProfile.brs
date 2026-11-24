' Builds the Jellyfin DeviceProfile from what this Roku can actually decode,
' so the server direct-plays whenever possible and otherwise sends HLS.
' Runs in a task thread (roDeviceInfo capability checks can be slow).

function ZCanVideo(di as object, codec as string, container as string, profile = "" as string) as boolean
    req = { Codec: codec, Container: container }
    if profile <> "" then req.Profile = profile
    res = di.CanDecodeVideo(req)
    return res <> invalid and res.Result = true
end function

function ZCanAudio(di as object, codec as string, container = "" as string) as boolean
    req = { Codec: codec }
    if container <> "" then req.Container = container
    res = di.CanDecodeAudio(req)
    return res <> invalid and res.Result = true
end function

' Returns { profile, maxBitrate, supports4k, hdr: { hdr10, dolbyVision, hlg } }.
function ZDeviceProfile(maxBitrateSetting = 0 as integer) as object
    di = CreateObject("roDeviceInfo")
    display = di.GetDisplayProperties()
    uiMode = di.GetVideoMode()
    supports4k = Left(uiMode, 4) = "2160" or (display <> invalid and display.Hdr10 = true)

    video = ["h264"]
    if ZCanVideo(di, "hevc", "mkv") or ZCanVideo(di, "hevc", "mp4") then video.push("hevc")
    if ZCanVideo(di, "vp9", "mkv") then video.push("vp9")
    if ZCanVideo(di, "av1", "mkv") then video.push("av1")
    if ZCanVideo(di, "mpeg2", "mkv") then video.push("mpeg2video")

    audio = ["aac", "mp3", "mp2"]
    for each codec in ["ac3", "eac3", "flac", "alac", "opus", "vorbis", "lpcm", "dts", "truehd"]
        if ZCanAudio(di, codec) then
            name = codec
            if codec = "lpcm" then name = "pcm_s16le,pcm_s24le"
            audio.push(name)
        end if
    end for
    passthrough = ZCanAudio(di, "eac3") or ZCanAudio(di, "ac3")

    maxChannels = "2"
    if passthrough then maxChannels = "6"

    maxBitrate = 20000000
    if supports4k then maxBitrate = 80000000
    if maxBitrateSetting > 0 and maxBitrateSetting < maxBitrate then maxBitrate = maxBitrateSetting

    videoList = ZJoin(video, ",")
    audioList = ZJoin(audio, ",")
    hlsVideo = "h264"
    ' Jellyfin encodes to the first codec listed: keep real encodes H.264, still copy HEVC.
    if video.count() > 1 and video[1] = "hevc" then hlsVideo = "h264,hevc"
    hlsAudio = "aac"
    if passthrough then hlsAudio = "aac,ac3,eac3"

    hdr = { hdr10: false, dolbyVision: false, hlg: false }
    if display <> invalid then
        hdr.hdr10 = display.Hdr10 = true
        hdr.dolbyVision = display.DolbyVision = true
        hdr.hlg = display.HLG = true
    end if
    ranges = ["SDR"]
    if hdr.hdr10 then ranges.push("HDR10")
    if hdr.hlg then ranges.push("HLG")
    if hdr.dolbyVision then
        ranges.push("DOVI")
        ranges.push("DOVIWithHDR10")
    end if

    maxWidth = "1920"
    if supports4k then maxWidth = "3840"

    profile = {
        Name: "Zorofin Roku",
        MaxStreamingBitrate: maxBitrate,
        MaxStaticBitrate: maxBitrate,
        MusicStreamingTranscodingBitrate: 320000,
        DirectPlayProfiles: [
            { Container: "mp4,m4v,mov", Type: "Video", VideoCodec: videoList, AudioCodec: audioList },
            { Container: "mkv", Type: "Video", VideoCodec: videoList, AudioCodec: audioList },
            { Container: "mp3,aac,m4a,flac,wav", Type: "Audio" }
        ],
        TranscodingProfiles: [
            {
                Container: "ts", Type: "Video", Protocol: "hls", Context: "Streaming",
                VideoCodec: hlsVideo, AudioCodec: hlsAudio, MaxAudioChannels: maxChannels,
                MinSegments: 1, BreakOnNonKeyFrames: true, CopyTimestamps: false
            },
            { Container: "mp3", Type: "Audio", AudioCodec: "mp3", Protocol: "http", Context: "Streaming", MaxAudioChannels: "2" }
        ],
        ContainerProfiles: [],
        CodecProfiles: [
            {
                Type: "Video", Codec: "h264",
                Conditions: [
                    { Condition: "LessThanEqual", Property: "VideoLevel", Value: "51", IsRequired: false },
                    { Condition: "NotEquals", Property: "IsAnamorphic", Value: "true", IsRequired: false },
                    ' Broadcast channels are often 1080i; the Roku stalls on
                    ' interlaced H.264, so the server deinterlaces instead.
                    { Condition: "NotEquals", Property: "IsInterlaced", Value: "true", IsRequired: false },
                    { Condition: "LessThanEqual", Property: "VideoBitDepth", Value: "8", IsRequired: false },
                    { Condition: "EqualsAny", Property: "VideoProfile", Value: "high|main|baseline|constrained baseline", IsRequired: false },
                    { Condition: "LessThanEqual", Property: "Width", Value: maxWidth, IsRequired: false }
                ]
            },
            {
                Type: "Video", Codec: "hevc",
                Conditions: [
                    { Condition: "EqualsAny", Property: "VideoProfile", Value: "main|main 10", IsRequired: false },
                    { Condition: "EqualsAny", Property: "VideoRangeType", Value: ZJoin(ranges, "|"), IsRequired: false },
                    { Condition: "LessThanEqual", Property: "Width", Value: maxWidth, IsRequired: false }
                ]
            },
            {
                Type: "Video",
                Conditions: [
                    { Condition: "EqualsAny", Property: "VideoRangeType", Value: ZJoin(ranges, "|"), IsRequired: false }
                ]
            },
            {
                Type: "VideoAudio",
                Conditions: [
                    { Condition: "LessThanEqual", Property: "AudioChannels", Value: maxChannels, IsRequired: false }
                ]
            }
        ],
        ' Text subtitles (ASS/SSA are converted by the server) arrive as WebVTT
        ' or SRT tracks the Roku renders itself; image subtitles are burned in.
        SubtitleProfiles: [
            { Format: "vtt", Method: "External" },
            { Format: "srt", Method: "External" },
            { Format: "subrip", Method: "External" },
            { Format: "pgssub", Method: "Encode" },
            { Format: "pgs", Method: "Encode" },
            { Format: "dvdsub", Method: "Encode" },
            { Format: "dvbsub", Method: "Encode" }
        ],
        ResponseProfiles: []
    }
    return { profile: profile, maxBitrate: maxBitrate, supports4k: supports4k, hdr: hdr }
end function
