' Calendar and Catch Up (plugin extras), as on the web
' (branding/zorofin-extras-pages.js). Pure helpers; times are epoch seconds
' and `offset` is the viewer's UTC offset in seconds (ZGuideLocalOffset).

' { calendar, catchUp } from GET /Zorofin/Extras; both off when missing.
function ZParseExtras(json as dynamic) as object
    if not ZIsMap(json) then return { calendar: false, catchUp: false }
    return { calendar: json.calendar = true, catchUp: json.catchUp = true }
end function

' The local day an event falls on ("yyyy-mm-dd"): episodes by air time,
' movie releases (allDay) by their date. "" when unreadable.
function ZCalendarDay(event as object, offset as integer) as string
    at = ZStr(event.at)
    if event.allDay = true then
        if Len(at) >= 10 then return Left(at, 10)
        return ""
    end if
    t = ZIsoToSeconds(at)
    if t <= 0 then return ""
    return ZCalendarKey(t, offset)
end function

function ZCalendarKey(t as integer, offset as integer) as string
    dt = CreateObject("roDateTime")
    dt.FromSeconds(t + offset)
    return dt.GetYear().toStr() + "-" + ZPad2(dt.GetMonth()) + "-" + ZPad2(dt.GetDayOfMonth())
end function

' "Today · Monday, November 9", "Tomorrow · …" or "Wednesday, November 11".
function ZCalendarLabel(key as string, now as integer, offset as integer) as string
    dt = CreateObject("roDateTime")
    dt.FromISO8601String(key + "T12:00:00Z")
    months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    name = dt.GetWeekday() + ", " + months[dt.GetMonth() - 1] + " " + dt.GetDayOfMonth().toStr()
    if key = ZCalendarKey(now, offset) then return "Today · " + name
    if key = ZCalendarKey(now + 86400, offset) then return "Tomorrow · " + name
    return name
end function

' Events grouped by local day, days in order, from today on (the server
' sends a day either side so evening shows land on the right local day).
' filter is "all", "shows" or "movies".
function ZCalendarGroups(items as dynamic, now as integer, offset as integer, filter = "all" as string, days = 0 as integer) as object
    groups = {}
    order = []
    today = ZCalendarKey(now, offset)
    if days > 28 then days = 28
    if days > 0 then
        for day = 0 to days - 1
            key = ZCalendarKey(now + day * 86400, offset)
            groups[key] = []
            order.push(key)
        end for
    end if
    if not ZIsArray(items) then items = []
    for each e in items
        if ZIsMap(e) and ZStr(e.title) <> "" then
            keep = filter = "all" or (filter = "shows" and e.kind = "episode") or (filter = "movies" and e.kind = "movie")
            key = ZCalendarDay(e, offset)
            if keep and key <> "" and key >= today and (days = 0 or groups.doesExist(key)) then
                if not groups.doesExist(key) then
                    groups[key] = []
                    order.push(key)
                end if
                groups[key].push(e)
            end if
        end if
    end for
    order.sort()
    out = []
    for each key in order
        out.push({ day: key, label: ZCalendarLabel(key, now, offset), events: groups[key] })
    end for
    return out
end function

' The badge an event wears: premieres, then the release kind.
function ZCalendarBadge(event as object) as string
    if event.premiere = true then
        if Left(ZStr(event.subtitle), 5) = "S1:E1" or Left(ZStr(event.subtitle), 5) = "S1 E1" then return "Series premiere"
        return "Season premiere"
    end if
    kinds = { airing: "New episode", cinema: "In cinemas", digital: "Digital release", physical: "On disc" }
    badge = kinds[ZStr(event.release)]
    if badge = invalid then return ""
    return badge
end function

' The caption under a calendar card: "8:00 PM · S1:E3 · Name" or the
' release kind for movies.
function ZCalendarCaption(event as object, offset as integer) as string
    parts = []
    if event.allDay <> true then
        t = ZIsoToSeconds(event.at)
        if t > 0 then parts.push(ZCalendarTime(t, offset))
    end if
    if ZStr(event.subtitle) <> "" then parts.push(ZStr(event.subtitle))
    return ZJoin(parts, " · ")
end function

function ZCalendarTime(t as integer, offset as integer) as string
    local = ((t + offset) mod 86400 + 86400) mod 86400
    h = Int(local / 3600)
    mins = Int((local mod 3600) / 60)
    suffix = "AM"
    if h >= 12 then suffix = "PM"
    h12 = h mod 12
    if h12 = 0 then h12 = 12
    return h12.toStr() + ":" + ZPad2(mins) + " " + suffix
end function

function ZTasteSet(data as dynamic) as dynamic
    if not ZIsMap(data) then return invalid
    if data.schemaVersion <> 1 or not ZIsArray(data.likedItemIds) then return invalid
    if data.likedItemIds.count() > 500 then return invalid
    liked = {}
    for each id in data.likedItemIds
        if type(id) <> "roString" and type(id) <> "String" then return invalid
        if id = "" then return invalid
        liked[LCase(id.replace("-", ""))] = true
    end for
    return liked
end function

' Watched and unwatched titles, excluding recommendation likes and device skips.
function ZCatchUpQueue(items as dynamic, skips as object, liked as object) as object
    out = []
    if not ZIsArray(items) then return out
    skipped = {}
    for each id in skips
        skipped[ZStr(id)] = true
    end for
    for each i in items
        if ZIsMap(i) and ZStr(i.Id) <> "" and not skipped.doesExist(ZStr(i.Id)) and not liked.doesExist(LCase(ZStr(i.Id).replace("-", ""))) then out.push(i)
    end for
    return out
end function

' Adds a skipped id, newest last, keeping the list small for the registry.
function ZCatchUpSkip(skips as dynamic, id as string, limit = 150 as integer) as object
    out = []
    if ZIsArray(skips) then
        for each s in skips
            if ZStr(s) <> id then out.push(ZStr(s))
        end for
    end if
    out.push(id)
    while out.count() > limit
        out.shift()
    end while
    return out
end function

' The remote's arrows on a Catch Up card, as on the web.
function ZCatchUpKeyAction(key as string) as string
    actions = { left: "skip", right: "like", OK: "detail" }
    a = actions[key]
    if a = invalid then return ""
    return a
end function

function ZRequestAvailableSeasons(title as object, specials as boolean) as object
    available = []
    if not ZIsArray(title.seasons) then return available
    info = title.mediaInfo
    if not ZIsMap(info) then info = {}
    blocked = {}
    if ZIsArray(info.requests) then
        for each receipt in info.requests
            if ZIsMap(receipt) and ZContains([1, 2], receipt.status) and ZIsArray(receipt.seasons) then
                for each season in receipt.seasons
                    if ZIsMap(season) then blocked[ZStr(season.seasonNumber)] = true
                end for
            end if
        end for
    end if
    for each season in title.seasons
        if ZIsMap(season) and ZNum(season.episodeCount, 0) > 0 then
            n = Int(ZNum(season.seasonNumber, -1))
            state = season
            if ZIsArray(info.seasons) then
                for each stored in info.seasons
                    if ZIsMap(stored) and stored.seasonNumber = n then state = stored
                end for
            end if
            missing = ZContains([1, 4, 6, 7], ZNum(state.status, 1)) and ZContains([1, 4, 6, 7], ZNum(state.status4k, 1))
            if (state.status = invalid and info.status = 5) or (state.status4k = invalid and info.status4k = 5) then missing = false
            if (n > 0 or (specials and n = 0)) and missing and not blocked.doesExist(n.toStr()) and not ZContains(available, n) then available.push(n)
        end if
    end for
    return available
end function
