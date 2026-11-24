' Small helpers shared by the render thread and task threads.
' Everything here is pure: no network, no registry, no nodes.

' Percent-encodes a string as UTF-8 (RFC 3986 unreserved set kept).
function ZEscape(value as dynamic) as string
    if value = invalid then return ""
    text = value.toStr()
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(text)
    hex = "0123456789ABCDEF"
    out = ""
    for i = 0 to bytes.count() - 1
        b = bytes[i]
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b = 45 or b = 46 or b = 95 or b = 126 then
            out = out + Chr(b)
        else
            out = out + "%" + Mid(hex, (b >> 4) + 1, 1) + Mid(hex, (b and 15) + 1, 1)
        end if
    end for
    return out
end function

' Builds "a=1&b=2" from an associative array; invalid values are skipped.
' Keys are emitted in sorted order so URLs are stable and testable.
function ZQuery(params as dynamic) as string
    if params = invalid then return ""
    keys = []
    for each key in params
        keys.push(key)
    end for
    keys.sort()
    parts = []
    for each key in keys
        value = params[key]
        if value <> invalid then
            if type(value) = "roBoolean" or type(value) = "Boolean" then
                if value then value = "true" else value = "false"
            end if
            parts.push(ZEscape(key) + "=" + ZEscape(value.toStr()))
        end if
    end for
    return ZJoin(parts, "&")
end function

function ZJoin(items as object, separator as string) as string
    out = ""
    first = true
    for each item in items
        if item <> invalid then
            text = item.toStr()
            if text <> "" then
                if not first then out = out + separator
                out = out + text
                first = false
            end if
        end if
    end for
    return out
end function

' Reads a nested value safely: ZGet(json, "UserData", "PlaybackPositionTicks").
function ZGet(obj as dynamic, a as dynamic, b = invalid as dynamic, c = invalid as dynamic) as dynamic
    if obj = invalid or type(obj) <> "roAssociativeArray" then return invalid
    value = obj[a]
    if b = invalid then return value
    if value = invalid or type(value) <> "roAssociativeArray" then return invalid
    value = value[b]
    if c = invalid then return value
    if value = invalid or type(value) <> "roAssociativeArray" then return invalid
    return value[c]
end function

function ZStr(value as dynamic, fallback = "" as string) as string
    if value = invalid then return fallback
    t = type(value)
    if t = "roString" or t = "String" then return value
    if t = "roInt" or t = "roInteger" or t = "Integer" or t = "roFloat" or t = "Float" or t = "roDouble" or t = "Double" or t = "LongInteger" or t = "roLongInteger" then return value.toStr()
    if t = "roBoolean" or t = "Boolean" then
        if value then return "true"
        return "false"
    end if
    return fallback
end function

function ZNum(value as dynamic, fallback = 0 as dynamic) as dynamic
    if value = invalid then return fallback
    t = type(value)
    if t = "roInt" or t = "roInteger" or t = "Integer" or t = "roFloat" or t = "Float" or t = "roDouble" or t = "Double" or t = "LongInteger" or t = "roLongInteger" then return value
    if t = "roString" or t = "String" then
        if value = "" then return fallback
        return value.toFloat()
    end if
    return fallback
end function

function ZBool(value as dynamic) as boolean
    if value = invalid then return false
    t = type(value)
    if t = "roBoolean" or t = "Boolean" then return value
    if t = "roString" or t = "String" then return LCase(value) = "true"
    return false
end function

function ZIsArray(value as dynamic) as boolean
    return value <> invalid and type(value) = "roArray"
end function

function ZIsMap(value as dynamic) as boolean
    return value <> invalid and type(value) = "roAssociativeArray"
end function

' Jellyfin ticks are 100 ns. 10,000,000 ticks = 1 second.
function ZTicksToSeconds(ticks as dynamic) as integer
    t = ZNum(ticks, 0)
    if t <= 0 then return 0
    return Int(t / 10000000#)
end function

function ZSecondsToTicks(seconds as dynamic) as dynamic
    s = ZNum(seconds, 0)
    if s < 0 then s = 0
    return Int(s * 1000#) * 10000&
end function

' "1h 32m", "48m" or "" for unknown runtimes (Apple metadata line style).
function ZRuntimeText(ticks as dynamic) as string
    total = ZTicksToSeconds(ticks)
    if total <= 0 then return ""
    minutes = Int((total + 30) / 60)
    if minutes < 1 then minutes = 1
    hours = Int(minutes / 60)
    rest = minutes - hours * 60
    if hours > 0 and rest > 0 then return hours.toStr() + "h " + rest.toStr() + "m"
    if hours > 0 then return hours.toStr() + "h"
    return rest.toStr() + "m"
end function

' "12m left" for resume cards.
function ZRemainingText(runtimeTicks as dynamic, positionTicks as dynamic) as string
    remaining = ZTicksToSeconds(runtimeTicks) - ZTicksToSeconds(positionTicks)
    if remaining <= 0 then return ""
    return ZRuntimeText(ZSecondsToTicks(remaining)) + " left"
end function

' "1:02:03" or "2:03" for the player clock.
function ZClock(seconds as dynamic) as string
    s = Int(ZNum(seconds, 0))
    if s < 0 then s = 0
    h = Int(s / 3600)
    mm = Int((s - h * 3600) / 60)
    ss = s - h * 3600 - mm * 60
    if h > 0 then return h.toStr() + ":" + ZPad2(mm) + ":" + ZPad2(ss)
    return mm.toStr() + ":" + ZPad2(ss)
end function

function ZPad2(n as integer) as string
    if n < 10 then return "0" + n.toStr()
    return n.toStr()
end function

' "S1 E3" labels, as on Apple cards (MediaItem.episodeLabel).
function ZEpisodeLabel(season as dynamic, episode as dynamic) as string
    s = ZNum(season, -1)
    e = ZNum(episode, -1)
    if s >= 0 and e >= 0 then return "S" + Int(s).toStr() + " E" + Int(e).toStr()
    if e >= 0 then return "Episode " + Int(e).toStr()
    return ""
end function

function ZClamp(value as dynamic, low as dynamic, high as dynamic) as dynamic
    if value < low then return low
    if value > high then return high
    return value
end function

' Truncates on a character boundary, adding an ellipsis.
function ZTruncate(text as string, limit as integer) as string
    if Len(text) <= limit then return text
    return Left(text, limit - 1).trim() + "…"
end function

' Parses an ISO 8601 UTC stamp into epoch seconds, or 0 when malformed.
function ZIsoToSeconds(text as dynamic) as integer
    if text = invalid or text = "" then return 0
    dt = CreateObject("roDateTime")
    stamp = text
    ' roDateTime wants at most milliseconds and a trailing Z.
    dot = Instr(1, stamp, ".")
    if dot > 0 then stamp = Left(stamp, dot - 1) + "Z"
    if Right(stamp, 1) <> "Z" then stamp = stamp + "Z"
    dt.FromISO8601String(stamp)
    return dt.AsSeconds()
end function

' Local "7:30 PM" for guide times.
function ZLocalTime(epochSeconds as integer) as string
    if epochSeconds <= 0 then return ""
    dt = CreateObject("roDateTime")
    dt.FromSeconds(epochSeconds)
    dt.ToLocalTime()
    h = dt.GetHours()
    mins = dt.GetMinutes()
    suffix = "AM"
    if h >= 12 then suffix = "PM"
    h12 = h mod 12
    if h12 = 0 then h12 = 12
    mm = mins.toStr()
    if mins < 10 then mm = "0" + mm
    return h12.toStr() + ":" + mm + " " + suffix
end function

function ZNowSeconds() as integer
    dt = CreateObject("roDateTime")
    return dt.AsSeconds()
end function

' Viewer-facing sentence for an error code.
function ZErrorText(code as dynamic) as string
    if code = "network" then return "Couldn't reach the server. Check the address and your network."
    if code = "unauthorized" then return "Your sign-in has expired. Please sign in again."
    if code = "forbidden" then return "This account isn't allowed to do that."
    if code = "notFound" then return "That item is no longer on the server."
    if code = "invalid" then return "The server sent something Zorofin couldn't read."
    if code = "credentials" then return "That username or password didn't work."
    if code = "timeout" then return "This took too long to start. Try again in a moment."
    return "Something went wrong on the server. Try again in a moment."
end function

function ZMin(a as dynamic, b as dynamic) as dynamic
    if a < b then return a
    return b
end function

function ZMax(a as dynamic, b as dynamic) as dynamic
    if a > b then return a
    return b
end function

' One decimal place, e.g. 7.0 or 8.4 (ratings).
function ZOneDecimalText(value as float) as string
    tenths = Int(value * 10 + 0.5)
    whole = Int(tenths / 10)
    return whole.toStr() + "." + (tenths - whole * 10).toStr()
end function

' Removes HTML tags, as Apple does before showing an overview.
function ZStripTags(text as dynamic) as string
    value = ZStr(text)
    if Instr(1, value, "<") = 0 then return value
    return CreateObject("roRegex", "<[^>]+>", "").replaceAll(value, "")
end function

' The kind label above a title ("Movie", "Series", "Episode").
function ZKindName(kind as dynamic) as string
    k = ZStr(kind)
    if k = "TvChannel" then return "Channel"
    if k = "BoxSet" then return "Collection"
    if k = "" then return "Title"
    return k
end function

function ZContains(list as object, value as dynamic) as boolean
    for each v in list
        if v = value then return true
    end for
    return false
end function

' Zorofin's type scale on Roku: every requested size and weight snaps to one
' of seven Inter styles. Each distinct style costs a permanent 4096 px wide
' glyph atlas (0.13-0.27 MB) that Roku's image eviction doesn't account for;
' on a TCL Roku TV about 13 atlases left too little free texture memory for
' a frame and the screen went black. Returns { size, weight }.
function ZTypeStyle(size as integer, weight = "regular" as string) as object
    if weight = "bold" then
        if size >= 35 then return { size: 48, weight: "bold" }
        weight = "semibold"
    end if
    if weight = "semibold" then
        if size <= 19 then return { size: 18, weight: "semibold" }
        if size <= 26 then return { size: 22, weight: "semibold" }
        return { size: 30, weight: "semibold" }
    end if
    if size <= 19 then return { size: 18, weight: "regular" }
    if size <= 24 then return { size: 22, weight: "regular" }
    return { size: 27, weight: "regular" }
end function
