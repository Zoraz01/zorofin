' Live TV guide logic, ported from apps/apple/Core LiveGuide.swift.
' Times are epoch seconds (UTC). `offset` is the local time zone's offset from
' UTC in seconds, so these stay pure and testable.

' Two hours of broadcast time per page.
function ZGuideDuration() as integer
    return 7200
end function

' Local time zone offset from UTC in seconds.
function ZGuideLocalOffset() as integer
    dt = CreateObject("roDateTime")
    utc = dt.AsSeconds()
    dt.ToLocalTime()
    return dt.AsSeconds() - utc
end function

' The guide starts at the current half hour (LiveGuideWindow.current).
function ZGuideWindowStart(now as integer, offset as integer) as integer
    local = now + offset
    return now - ZGuideMod(local, 1800)
end function

' Local midnight of the day holding `t`.
function ZGuideDayStart(t as integer, offset as integer) as integer
    return t - ZGuideMod(t + offset, 86400)
end function

' Keeps a window inside today .. seven days from today, like Apple's move().
function ZGuideClampStart(start as integer, now as integer, offset as integer) as integer
    first = ZGuideDayStart(now, offset)
    last = first + 7 * 86400 - ZGuideDuration()
    if start < first then return first
    if start > last then return last
    return start
end function

function ZGuideMod(a as integer, b as integer) as integer
    r = a mod b
    if r < 0 then r = r + b
    return r
end function

' Where `t` falls across the window, from 0 to 1.
function ZGuideFraction(start as integer, t as integer) as float
    f = (t - start) / ZGuideDuration()
    if f < 0 then return 0
    if f > 1 then return 1
    return f
end function

' Clips programs to the window, keeps gaps as empty slots and drops overlaps
' (LiveGuideRow.init). Programs are { id, name, start, finish, channelId, ... };
' slots are { program (or invalid), start, finish }.
function ZGuideSlots(channelId as string, programs as object, start as integer, finish as integer) as object
    ordered = []
    if programs <> invalid then
        for each p in programs
            if ZStr(p.channelId) = channelId and p.start < finish and p.finish > start and p.finish > p.start then ordered.push(p)
        end for
    end if
    ' Insertion sort by start, then end, then id (lists are short).
    for i = 1 to ordered.count() - 1
        item = ordered[i]
        j = i - 1
        while j >= 0 and ZGuideBefore(item, ordered[j])
            ordered[j + 1] = ordered[j]
            j = j - 1
        end while
        ordered[j + 1] = item
    end for
    slots = []
    cursor = start
    for each p in ordered
        left = ZMax(cursor, p.start)
        right = ZMin(finish, p.finish)
        if right > left then
            if left > cursor then slots.push({ program: invalid, start: cursor, finish: left })
            slots.push({ program: p, start: left, finish: right })
            cursor = right
        end if
    end for
    if cursor < finish then slots.push({ program: invalid, start: cursor, finish: finish })
    return slots
end function

function ZGuideBefore(a as object, b as object) as boolean
    if a.start <> b.start then return a.start < b.start
    if a.finish <> b.finish then return a.finish < b.finish
    return ZStr(a.id, ZStr(a.name)) < ZStr(b.id, ZStr(b.name))
end function

' The slot showing time `t`, or the nearest one at either end.
function ZGuideSlotAt(slots as object, t as integer) as integer
    if slots = invalid or slots.count() = 0 then return -1
    for i = 0 to slots.count() - 1
        if t >= slots[i].start and t < slots[i].finish then return i
    end for
    if t < slots[0].start then return 0
    return slots.count() - 1
end function

' Channels that match a typed query (name or number) and the favorites
' filter, without duplicates (LiveGuideRow.matching).
function ZGuideMatch(channels as object, query as string, favorites as boolean) as object
    q = LCase(ZGuideTrim(query))
    seen = {}
    out = []
    for each c in channels
        id = ZStr(c.id)
        if id <> "" and not seen.doesExist(id) then
            seen[id] = true
            keep = not favorites or c.favorite = true
            if keep and q <> "" then keep = Instr(1, LCase(ZStr(c.name)), q) > 0 or Instr(1, LCase(ZStr(c.number)), q) > 0
            if keep then out.push(c)
        end if
    end for
    return out
end function

function ZGuideTrim(text as string) as string
    s = text
    while Len(s) > 0 and (Left(s, 1) = " " or Left(s, 1) = Chr(9))
        s = Mid(s, 2)
    end while
    while Len(s) > 0 and (Right(s, 1) = " " or Right(s, 1) = Chr(9))
        s = Left(s, Len(s) - 1)
    end while
    return s
end function

function ZGuideAiring(p as dynamic, now as integer) as boolean
    if p = invalid then return false
    return p.start <= now and now < p.finish
end function

' "Today", "Tomorrow" or "Sat, Nov 8" for the day holding `t`.
function ZGuideDayLabel(t as integer, now as integer, offset as integer) as string
    days = Int((ZGuideDayStart(t, offset) - ZGuideDayStart(now, offset)) / 86400)
    if days = 0 then return "Today"
    if days = 1 then return "Tomorrow"
    dt = CreateObject("roDateTime")
    dt.FromSeconds(t + offset)
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return Left(dt.GetWeekday(), 3) + ", " + months[dt.GetMonth() - 1] + " " + dt.GetDayOfMonth().toStr()
end function

' "Saturday, Nov 8" for the date picker.
function ZGuideLongDay(t as integer, offset as integer) as string
    dt = CreateObject("roDateTime")
    dt.FromSeconds(t + offset)
    months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return dt.GetWeekday() + ", " + months[dt.GetMonth() - 1] + " " + dt.GetDayOfMonth().toStr()
end function

' "7:30 PM" from a UTC time and offset (ZLocalTime without the device clock).
function ZGuideTime(t as integer, offset as integer) as string
    local = ZGuideMod(t + offset, 86400)
    h = Int(local / 3600)
    mins = Int((local mod 3600) / 60)
    suffix = "AM"
    if h >= 12 then suffix = "PM"
    h12 = h mod 12
    if h12 = 0 then h12 = 12
    mm = mins.toStr()
    if mins < 10 then mm = "0" + mm
    return h12.toStr() + ":" + mm + " " + suffix
end function

' "7:30 – 8:00 PM" style range used under the program name.
function ZGuideRange(a as integer, b as integer, offset as integer) as string
    return ZGuideTime(a, offset) + " – " + ZGuideTime(b, offset)
end function
