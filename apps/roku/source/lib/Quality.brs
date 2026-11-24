' Source-file quality, ported from the Apple app's MediaQuality: the badges
' under a title ("1080p · SDR · MKV · H.264 · AAC · Stereo") and the File
' details facts. These describe the file, never the negotiated playback.
' A series or season has no single file, so it has no quality.

function ZQuality(json as dynamic, audioIndex = invalid as dynamic) as object
    out = { badges: [], facts: [], resolution: "", dynamicRange: "" }
    if not ZIsMap(json) then return out
    kind = ZStr(json.Type)
    if kind = "Series" or kind = "Season" then return out
    source = invalid
    if ZIsArray(json.MediaSources) and json.MediaSources.count() > 0 and ZIsMap(json.MediaSources[0]) then source = json.MediaSources[0]
    streams = invalid
    if source <> invalid then streams = source.MediaStreams
    if not ZIsArray(streams) then streams = json.MediaStreams
    if not ZIsArray(streams) then streams = []

    video = invalid
    audios = []
    for each s in streams
        if ZIsMap(s) then
            if s.Type = "Video" and s.IsAttachedPicture <> true and video = invalid then video = s
            if s.Type = "Audio" then audios.push(s)
        end if
    end for
    wanted = audioIndex
    if wanted = invalid and source <> invalid then wanted = source.DefaultAudioStreamIndex
    audio = invalid
    for each a in audios
        if audio = invalid and wanted <> invalid and ZNum(a.Index, -1) = ZNum(wanted, -2) then audio = a
    end for
    for each a in audios
        if audio = invalid and a.IsDefault = true then audio = a
    end for
    if audio = invalid and audios.count() > 0 then audio = audios[0]

    container = ""
    if source <> invalid then container = ZQualityClean(source.Container)
    if container = "" then container = ZQualityClean(json.Container)
    ' Jellyfin lists every container a file matches ("mov,mp4,m4a"); keep one.
    if Instr(1, container, ",") > 0 then container = Left(container, Instr(1, container, ",") - 1)
    container = UCase(container)

    resolution = ""
    range = ""
    videoCodec = ""
    if video <> invalid then
        resolution = ZResolution(video.Width, video.Height, ZBool(video.IsInterlaced))
        range = ZDynamicRange(video)
        videoCodec = ZCodecName(video.Codec)
    end if
    spatial = ""
    audioCodec = ""
    layout = ""
    if audio <> invalid then
        format = UCase(ZStr(audio.AudioSpatialFormat))
        profile = UCase(ZStr(audio.Profile))
        if format = "DOLBYATMOS" then
            spatial = "Dolby Atmos"
        else if format = "DTSX" then
            spatial = "DTS:X"
        else if format = "" or format = "NONE" then
            if Instr(1, profile, "DOLBY ATMOS") > 0 then
                spatial = "Dolby Atmos"
            else if Instr(1, profile, "DTS:X") > 0 then
                spatial = "DTS:X"
            end if
        end if
        audioCodec = ZCodecName(audio.Codec)
        layout = ZQualityClean(audio.ChannelLayout)
        if layout = "" then
            channels = Int(ZNum(audio.Channels, 0))
            if channels = 1 then
                layout = "Mono"
            else if channels = 2 then
                layout = "Stereo"
            else if channels > 2 then
                layout = channels.toStr() + " channels"
            end if
        end if
    end if

    for each b in [resolution, range, container, videoCodec, spatial, audioCodec, layout]
        if b <> "" then out.badges.push(b)
    end for
    out.resolution = resolution
    out.dynamicRange = range

    facts = out.facts
    if container <> "" then facts.push({ title: "File format", value: container })
    if source <> invalid then
        size = ZNum(source.Size, 0)
        if size > 0 then facts.push({ title: "File size", value: ZByteText(size) })
        bitrate = ZNum(source.Bitrate, 0)
        if bitrate > 0 then facts.push({ title: "File bitrate", value: ZOneDecimal(bitrate / 1000000) + " Mbps" })
    end if
    if video <> invalid then
        w = Int(ZNum(video.Width, 0))
        h = Int(ZNum(video.Height, 0))
        if w > 0 and h > 0 then
            facts.push({ title: "Resolution", value: w.toStr() + " × " + h.toStr() })
        else if resolution <> "" then
            facts.push({ title: "Resolution", value: resolution })
        end if
        if videoCodec <> "" then facts.push({ title: "Video codec", value: videoCodec })
        if range <> "" then facts.push({ title: "Dynamic range", value: range })
        depth = Int(ZNum(video.BitDepth, 0))
        if depth > 0 then facts.push({ title: "Bit depth", value: depth.toStr() + "-bit" })
        rate = ZNum(video.AverageFrameRate, 0)
        if rate > 0 then facts.push({ title: "Frame rate", value: ZFrameRateText(rate) + " fps" })
    end if
    if audioCodec <> "" then facts.push({ title: "Audio codec", value: audioCodec })
    if spatial <> "" then facts.push({ title: "Spatial audio", value: spatial })
    if layout <> "" then facts.push({ title: "Audio channels", value: layout })
    return out
end function

function ZResolution(width as dynamic, height as dynamic, interlaced = false as boolean) as string
    w = ZNum(width, 0)
    h = ZNum(height, 0)
    if w <= 0 and h <= 0 then return ""
    if w >= 7680 or h >= 4320 then return "8K"
    if w >= 3840 or h >= 2160 then return "4K"
    if w >= 1920 or h >= 1080 then
        if interlaced then return "1080i"
        return "1080p"
    end if
    if w >= 1280 or h >= 720 then return "720p"
    return "SD"
end function

function ZDynamicRange(stream as dynamic) as string
    if not ZIsMap(stream) then return ""
    kind = UCase(ZStr(stream.VideoRangeType))
    if Left(kind, 4) = "DOVI" and kind <> "DOVIINVALID" then return "Dolby Vision"
    if kind = "HDR10PLUS" then return "HDR10+"
    if kind = "HDR10" then return "HDR10"
    if kind = "HLG" then return "HLG"
    if kind = "SDR" then return "SDR"
    if UCase(ZStr(stream.VideoRange)) = "HDR" then return "HDR"
    if UCase(ZStr(stream.VideoRange)) = "SDR" then return "SDR"
    return ""
end function

function ZQualityClean(value as dynamic) as string
    text = ZStr(value).trim()
    if Len(text) > 48 then text = Left(text, 48)
    return text
end function

function ZCodecName(value as dynamic) as string
    text = ZQualityClean(value)
    if text = "" then return ""
    lower = LCase(text)
    if lower = "h264" or lower = "avc" then return "H.264"
    if lower = "hevc" or lower = "h265" then return "HEVC"
    if lower = "eac3" then return "Dolby Digital Plus"
    if lower = "ac3" then return "Dolby Digital"
    if lower = "truehd" then return "TrueHD"
    return UCase(text)
end function

' 1 decimal place, e.g. 24.0.
function ZOneDecimal(value as float) as string
    tenths = Int(value * 10 + 0.5)
    whole = Int(tenths / 10)
    return whole.toStr() + "." + (tenths - whole * 10).toStr()
end function

' Up to 3 decimals without trailing zeros: 24, 23.976, 29.97.
function ZFrameRateText(value as float) as string
    thousandths = Int(value * 1000 + 0.5)
    whole = Int(thousandths / 1000)
    frac = thousandths - whole * 1000
    if frac = 0 then return whole.toStr()
    digits = Right("00" + frac.toStr(), 3)
    while Right(digits, 1) = "0"
        digits = Left(digits, Len(digits) - 1)
    end while
    return whole.toStr() + "." + digits
end function

' File sizes like Apple's ByteCountFormatter (.file, decimal units).
function ZByteText(bytes as double) as string
    if bytes >= 1000000000 then return ZOneDecimal(bytes / 1000000000) + " GB"
    if bytes >= 1000000 then return ZOneDecimal(bytes / 1000000) + " MB"
    if bytes >= 1000 then return Int(bytes / 1000 + 0.5).toStr() + " KB"
    return Int(bytes).toStr() + " bytes"
end function
