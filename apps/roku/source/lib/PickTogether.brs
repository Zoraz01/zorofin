' Pick Together (schemaVersion 1) for TVs, matching the Apple TV app: the TV
' hosts with display: true, shows the code, who joined, swipe progress and
' matches, and never votes. Pure parsing and wording; the task does the calls.

function ZPickCode(text as dynamic) as string
    code = UCase(ZStr(text))
    out = ""
    alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    for i = 1 to Len(code)
        c = Mid(code, i, 1)
        if Instr(1, alphabet, c) > 0 then out = out + c
    end for
    if Len(out) <> 6 then return ""
    return out
end function

function ZPickSpaced(code as string) as string
    if Len(code) <> 6 then return code
    return Left(code, 3) + " " + Right(code, 3)
end function

function ZPickValidId(id as dynamic, hexOnly as boolean) as boolean
    s = ZStr(id)
    if Len(s) < 1 or Len(s) > 64 then return false
    for i = 1 to Len(s)
        c = LCase(Mid(s, i, 1))
        isHex = Instr(1, "0123456789abcdef", c) > 0
        if hexOnly then
            if not isHex and c <> "-" then return false
        else if not isHex and Instr(1, "ghijklmnopqrstuvwxyz", c) = 0 then
            return false
        end if
    end for
    return true
end function

' A card, or invalid. Matches and Almost carry likes/of.
function ZPickCard(json as dynamic) as dynamic
    if not ZIsMap(json) then return invalid
    if not ZPickValidId(json.itemId, true) or ZStr(json.title) = "" then return invalid
    t = "Movie"
    if ZStr(json.type) = "Series" then t = "Series"
    card = { itemId: ZStr(json.itemId), title: Left(ZStr(json.title), 300), type: t, year: ZNum(json.year, 0), imageTag: ZStr(json.imageTag), tally: "" }
    if json.likes <> invalid and json.of <> invalid then card.tally = ZStr(ZNum(json.likes, 0)) + " of " + ZStr(ZNum(json.of, 0))
    return card
end function

' Jellyfin item JSON for the ordinary item node, artwork and details.
function ZPickItemJson(card as object) as object
    json = { Id: card.itemId, Name: card.title, Type: card.type }
    if card.year > 0 then json.ProductionYear = card.year
    if card.imageTag <> "" then json.ImageTags = { Primary: card.imageTag }
    return json
end function

' A full session view, or invalid. Voters exclude the TV display.
function ZPickSession(json as dynamic) as dynamic
    if not ZIsMap(json) or ZNum(json.schemaVersion, 0) <> 1 then return invalid
    id = ZStr(json.id)
    if Len(id) <> 32 or not ZPickValidId(id, true) then return invalid
    code = ZPickCode(json.code)
    kind = ZStr(json.kind)
    if code = "" or (kind <> "movie" and kind <> "series") or json.version = invalid then return invalid
    members = []
    if ZIsArray(json.members) then
        for each member in json.members
            if ZIsMap(member) and ZPickValidId(member.seat, false) and members.count() < 12 and not ZBool(member.display) then
                name = Left(ZStr(member.name), 40)
                if name = "" then name = "Guest"
                members.push({ seat: ZStr(member.seat), name: name, host: ZBool(member.host), swiped: ZNum(member.swiped, 0), total: ZNum(member.total, 0), done: ZBool(member.done) })
            end if
        end for
    end if
    status = ZStr(json.status)
    if not ZContains(["lobby", "preparing", "swiping", "empty", "ended", "failed"], status) then status = "unknown"
    voters = ZNum(json.voters, members.count())
    s = { id: id, code: code, kind: kind, status: status, round: ZNum(json.round, 0), version: ZNum(json.version, 0), host: ZBool(json.host), seat: "", members: members, voters: voters, matches: [], almost: [] }
    if ZPickValidId(json.seat, false) then s.seat = ZStr(json.seat)
    for each key in ["matches", "almost"]
        if ZIsArray(json[key]) then
            for each c in json[key]
                card = ZPickCard(c)
                if card <> invalid then s[key].push(card)
            end for
        end if
    end for
    s.canStart = s.host and status = "lobby" and voters >= 2
    return s
end function

function ZPickKindLabel(kind as string) as string
    if kind = "series" then return "Shows"
    return "Movies"
end function

function ZPickTitle(s as object) as string
    if s.status = "swiping" then
        done = s.members.count() > 0
        for each member in s.members
            if not member.done then done = false
        end for
        if done then return "Everyone's done"
        return "Swiping…"
    end if
    if s.status = "empty" then return "Out of titles"
    if s.status = "ended" then return "Session ended"
    if s.status = "failed" then return "Couldn't find titles"
    return "Getting ready…"
end function

' Short, actionable wording from an HTTP result.
function ZPickError(status as integer) as object
    if status = 404 then return { text: "This session has ended.", ended: true }
    if status = 403 then return { text: "You're no longer in this session.", ended: true }
    if status = 429 then return { text: "The server is busy. Try again in a moment.", ended: false }
    if status <= 0 then return { text: "Couldn't reach Pick Together. Check the connection and try again.", ended: false }
    return { text: "Couldn't reach Pick Together. Try again.", ended: false }
end function

' Direct play only for previews: mp4/mov, H.264 or HEVC up to 1080p,
' AAC/AC-3/E-AC-3 audio. Never transcode a preview.
function ZTrailerCompatible(source as dynamic) as boolean
    if not ZIsMap(source) then return false
    containers = LCase(ZStr(source.Container))
    if Instr(1, containers, "mp4") = 0 and Instr(1, containers, "mov") = 0 and Instr(1, containers, "m4v") = 0 then return false
    video = invalid
    audio = []
    if ZIsArray(source.MediaStreams) then
        for each s in source.MediaStreams
            if ZIsMap(s) then
                if ZStr(s.Type) = "Video" and video = invalid then video = s
                if ZStr(s.Type) = "Audio" then audio.push(LCase(ZStr(s.Codec)))
            end if
        end for
    end if
    if video = invalid then return false
    codec = LCase(ZStr(video.Codec))
    if codec <> "h264" and codec <> "hevc" and codec <> "h265" then return false
    if ZNum(video.Height, 0) > 1080 then return false
    if audio.count() = 0 then return true
    for each a in audio
        if a = "aac" or a = "ac3" or a = "eac3" then return true
    end for
    return false
end function
