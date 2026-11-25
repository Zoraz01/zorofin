' Chapters and the per-show track memory for the player. The pure parts
' (chapters, picking) have no network, registry or nodes.

' Chapters in time order; unnamed ones are numbered in that order. A single
' chapter is no navigation at all, so it gives none.
function ZChapters(json as dynamic) as object
    out = []
    if not ZIsMap(json) or not ZIsArray(json.Chapters) then return out
    for each c in json.Chapters
        if ZIsMap(c) and c.StartPositionTicks <> invalid and ZNum(c.StartPositionTicks, -1) >= 0 then
            entry = { start: ZTicksToSeconds(c.StartPositionTicks), name: ZStr(c.Name).trim() }
            ' Insert in time order.
            at = out.count()
            while at > 0 and out[at - 1].start > entry.start
                at = at - 1
            end while
            sorted = []
            for i = 0 to out.count() - 1
                if i = at then sorted.push(entry)
                sorted.push(out[i])
            end for
            if at = out.count() then sorted.push(entry)
            out = sorted
        end if
    end for
    if out.count() < 2 then return []
    for i = 0 to out.count() - 1
        if out[i].name = "" then out[i].name = "Chapter " + (i + 1).toStr()
    end for
    return out
end function

' The chapter playing at `seconds`, or -1 before the first one.
function ZChapterIndex(chapters as object, seconds as dynamic) as integer
    current = -1
    for i = 0 to chapters.count() - 1
        if chapters[i].start <= ZNum(seconds, 0) then current = i
    end for
    return current
end function

function ZSameTrackLanguage(a as dynamic, b as dynamic) as boolean
    x = LCase(ZStr(a)).trim()
    y = LCase(ZStr(b)).trim()
    return x <> "" and x <> "und" and x = y
end function

' Track indexes matching what was last picked ({ audio, subtitle, off,
' forced }); invalid where nothing is remembered or this file has no track
' in that language. A subtitle of -1 means Off.
function ZPickTracks(memory as dynamic, audioTracks as object, subtitles as object) as object
    pick = { audio: invalid, subtitle: invalid }
    if not ZIsMap(memory) then return pick
    for each a in audioTracks
        if pick.audio = invalid and ZSameTrackLanguage(a.language, memory.audio) then pick.audio = a.index
    end for
    if memory.off = true then
        pick.subtitle = -1
    else
        first = invalid
        for each s in subtitles
            if ZSameTrackLanguage(s.language, memory.subtitle) then
                if first = invalid then first = s.index
                if pick.subtitle = invalid and ZBool(s.forced) = ZBool(memory.forced) then pick.subtitle = s.index
            end if
        end for
        if pick.subtitle = invalid then pick.subtitle = first
    end if
    return pick
end function

' MARK: Registry (this Roku only)

function ZTrackMemoryKey() as string
    s = m.global.session
    if s = invalid then return ""
    return "tracks:" + ZStr(s.serverId) + ":" + ZStr(s.userId)
end function

function ZTrackMemoryList() as object
    key = ZTrackMemoryKey()
    if key = "" then return []
    sec = CreateObject("roRegistrySection", "zorofin")
    if not sec.Exists(key) then return []
    saved = ParseJson(sec.Read(key))
    if ZIsArray(saved) then return saved
    return []
end function

' What was last picked for a show (or movie), or invalid.
function ZTrackMemory(show as string) as dynamic
    for each entry in ZTrackMemoryList()
        if ZIsMap(entry) and entry.k = show then return entry
    end for
    return invalid
end function

' Merges `patch` into the show's memory. Capped at 40 shows, newest last, so
' the registry stays well under Roku's limit.
sub ZRememberTracks(show as string, patch as object)
    key = ZTrackMemoryKey()
    if key = "" or show = "" then return
    entry = { k: show }
    list = []
    for each saved in ZTrackMemoryList()
        if ZIsMap(saved) and saved.k = show then
            entry = saved
        else
            list.push(saved)
        end if
    end for
    for each field in patch
        entry[field] = patch[field]
    end for
    list.push(entry)
    while list.count() > 40
        list.shift()
    end while
    sec = CreateObject("roRegistrySection", "zorofin")
    sec.Write(key, FormatJson(list))
    sec.Flush()
end sub

' MARK: Playback problem reports

' How the stream was being played, in the words every Zorofin app uses.
function ZPlaybackProblemMethod(info as dynamic) as string
    if not ZIsMap(info) then return ""
    if info.isLive = true then return "live"
    method = LCase(ZStr(info.playMethod))
    if method = "directplay" then return "direct"
    if method = "directstream" then return "remux"
    if method = "transcode" then return "transcode"
    return ""
end function

' The body of one report for POST /Zorofin/PlaybackReports. `sent` is how
' many this app run already sent; returns invalid when nothing should go:
' the server doesn't collect reports, the viewer said no, the server
' refused earlier, or this run hit its limit of 30.
function ZPlaybackProblemBody(kind as string, reason as dynamic, info as dynamic, features as dynamic, settings as dynamic, state as dynamic, version as dynamic, device as dynamic, position = 0 as dynamic) as dynamic
    if not ZIsMap(features) or ZNum(features.playbackReports, 0) <> 1 then return invalid
    if ZIsMap(settings) and settings.sendPlaybackReports = false then return invalid
    if ZIsMap(state) and (state.refused = true or ZNum(state.sent, 0) >= 30) then return invalid
    if not ZIsMap(info) or ZStr(info.id) = "" then return invalid
    body = {
        kind: kind,
        itemId: ZStr(info.id),
        title: Left(ZStr(info.title), 200),
        platform: "Roku",
        appVersion: ZStr(version),
        device: Left(ZStr(device), 120),
        method: ZPlaybackProblemMethod(info),
        reason: Left(ZStr(reason), 300)
    }
    if ZNum(position, 0) > 0 then body.positionSeconds = Int(ZNum(position, 0))
    return body
end function

' MARK: Automatic quality

' The next lower streaming limit (bits per second) under what is playing
' now, or 0 when already at the lowest. `current` is the viewer's limit
' (0 = Auto), `ceiling` what the device allows and `stream` what the server
' says it is sending.
function ZLowerQuality(current as dynamic, ceiling as dynamic, stream as dynamic) as integer
    top = ZNum(current, 0)
    if top <= 0 then top = ZNum(ceiling, 0)
    if ZNum(stream, 0) > 0 and (top <= 0 or ZNum(stream, 0) < top) then top = ZNum(stream, 0)
    for each mbps in [40, 20, 12, 8, 4, 2]
        if top <= 0 or mbps * 1000000 < top then return mbps * 1000000
    end for
    return 0
end function

' Whether playback has run dry often enough to step the quality down: twice
' within a minute, or one stall of 6 seconds. `stamps` are the times
' (seconds) playback ran dry; `stalled` how long the current one has lasted.
function ZShouldLowerQuality(stamps as object, now as dynamic, stalled as dynamic) as boolean
    if ZNum(stalled, 0) >= 6 then return true
    recent = 0
    for each at in stamps
        if ZNum(now, 0) - ZNum(at, 0) <= 60 then recent = recent + 1
    end for
    return recent >= 2
end function

' MARK: Subtitle timing

' "In sync", "+0.3 s" (later), "−1.2 s" (earlier), from tenths of a second.
function ZTimingLabel(tenths as dynamic) as string
    t = Int(ZNum(tenths, 0))
    if t = 0 then return "In sync"
    sign = "+"
    if t < 0 then
        sign = "−"
        t = -t
    end if
    return sign + Int(t / 10).toStr() + "." + (t mod 10).toStr() + " s"
end function

' Keeps a timing offset within 10 seconds either way.
function ZClampTiming(tenths as dynamic) as integer
    t = Int(ZNum(tenths, 0))
    if t > 100 then return 100
    if t < -100 then return -100
    return t
end function

' A Jellyfin subtitle address that delivers the same track shifted by
' `tenths` (positive = later). The server subtracts the start position in
' the address from every cue, so a negative start moves them later. An
' address in another shape is returned unchanged.
function ZSubtitleUrlShifted(url as string, tenths as dynamic) as string
    t = Int(ZNum(tenths, 0))
    if t = 0 or url = "" then return url
    re = CreateObject("roRegex", "(/Subtitles/[0-9]+/)-?[0-9]+(/Stream\.)", "i")
    if not re.IsMatch(url) then return url
    ticks = (-t).toStr() + "000000"
    return re.Replace(url, "\1" + ticks + "\2")
end function
