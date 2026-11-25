' Which channels are using the server's Live TV streams, from the companion's
' liveTvStreams module (capability version 1). Viewers get channel names and
' counts only, never who is watching. The wording matches the Apple TV and
' Flutter apps and the web client, so every app says the same thing.

function ZLtsRoute(features as dynamic) as string
    if not ZIsMap(features) then return ""
    if ZNum(features.liveTvStreams, 0) = 1 then return "companion"
    if ZNum(features.liveTVAvailability, 0) = 1 then return "legacy"
    return ""
end function

' The older availability adapter has no precise usage count. Preserve its
' conflict hints without inventing N-of-M from sessions or visible channels.
function ZLtsParseLegacy(json as dynamic, channelId as string) as dynamic
    if not ZIsMap(json) then return invalid
    limit = Int(ZNum(json.limit, 0))
    state = ZStr(json.state)
    if limit < 1 or limit > 1000 or not ZContains(["available", "busy", "unknown"], state) then return invalid
    for each key in ["sameChannel", "differentChannel", "ownStream"]
        if GetInterface(json[key], "ifBoolean") = invalid then return invalid
    end for
    if json.sameChannel and json.differentChannel then return invalid
    if state <> "busy" and (json.sameChannel or json.differentChannel or json.ownStream) then return invalid
    message = "Live TV availability could not be checked."
    if state = "available" then message = "Live TV is available."
    if state = "busy" then message = "Live TV is in use. A different channel must wait until a stream is free."
    if json.sameChannel then message = "This channel is already playing. You can join it."
    if json.ownStream then message = "You can switch channels on this device."
    return { legacy: true, limit: limit, state: state, message: message, streams: [],
        blocked: state = "busy" and json.differentChannel and not json.sameChannel and not json.ownStream }
end function

' Checks a status response and keeps only the fields the app uses.
function ZLtsParse(json as dynamic) as dynamic
    if not ZIsMap(json) then return invalid
    if ZNum(json.version, 0) <> 1 then return invalid
    limit = Int(ZNum(json.limit, 0))
    inUse = Int(ZNum(json.inUse, -1))
    free = Int(ZNum(json.free, -1))
    if limit <= 0 or limit > 1000 or inUse < 0 or free < 0 then return invalid
    streams = []
    if ZIsArray(json.streams) then
        for each s in json.streams
            if ZIsMap(s) and ZStr(s.channelId) <> "" then
                programme = invalid
                if ZIsMap(s.programme) then programme = { title: ZStr(s.programme.title), endsAt: ZStr(s.programme.endsAt) }
                streams.push({
                    channelId: ZStr(s.channelId),
                    channelName: ZStr(s.channelName),
                    channelNumber: ZStr(s.channelNumber),
                    programme: programme,
                    viewers: Int(ZNum(s.viewers, 1)),
                    paused: ZBool(s.paused),
                    yours: ZBool(s.yours)
                })
            end if
        end for
    end if
    request = invalid
    if ZIsMap(json.request) then
        request = {
            channelId: ZStr(json.request.channelId),
            playing: ZBool(json.request.playing),
            canStart: ZBool(json.request.canStart),
            reason: ZStr(json.request.reason)
        }
    end if
    return {
        limit: limit, inUse: inUse, free: free,
        otherUse: Int(ZNum(json.otherUse, 0)),
        streams: streams, request: request
    }
end function

function ZLtsClean(id as dynamic) as string
    return LCase(ZStr(id).Replace("-", ""))
end function

function ZLtsPlural(count as integer, word as string) as string
    text = count.toStr() + " " + word
    if count <> 1 then text = text + "s"
    return text
end function

function ZLtsIsFull(status as object) as boolean
    if status.legacy = true then return status.state = "busy"
    return status.free <= 0
end function

' "1 of 1 Live TV stream in use. Anyone can join a channel that's already playing."
function ZLtsSummary(status as object) as string
    if status.legacy = true then return status.message
    head = status.inUse.toStr() + " of " + ZLtsPlural(status.limit, "Live TV stream") + " in use."
    if ZLtsIsFull(status) then return head + " Anyone can join a channel that’s already playing."
    return head + " " + ZLtsPlural(status.free, "stream") + " free for another channel."
end function

function ZLtsStream(status as object, channelId as string) as dynamic
    id = ZLtsClean(channelId)
    for each s in status.streams
        if ZLtsClean(s.channelId) = id then return s
    end for
    return invalid
end function

' "2 watching · 18 min left"
function ZLtsDetail(stream as object, nowSeconds as integer) as string
    viewers = stream.viewers
    if viewers < 1 then viewers = 1
    text = viewers.toStr() + " watching"
    endsAt = ""
    if stream.programme <> invalid then endsAt = stream.programme.endsAt
    left = ZLtsTimeLeft(endsAt, nowSeconds)
    if left <> "" then text = text + " · " + left
    return text
end function

function ZLtsTimeLeft(endsAt as string, nowSeconds as integer) as string
    if endsAt = "" then return ""
    endSeconds = ZIsoToSeconds(endsAt)
    if endSeconds <= 0 then return ""
    minutes = Int((endSeconds - nowSeconds) / 60 + 0.5)
    if minutes <= 0 then return ""
    if minutes < 60 then return minutes.toStr() + " min left"
    text = Int(minutes / 60).toStr() + " hr "
    if minutes mod 60 > 0 then text = text + (minutes mod 60).toStr() + " min "
    return text + "left"
end function

function ZLtsOthers(status as object, channelId as string) as object
    id = ZLtsClean(channelId)
    others = []
    for each s in status.streams
        if ZLtsClean(s.channelId) <> id then others.push(s)
    end for
    return others
end function

' "ESPN", "ESPN and CNN", "ESPN, CNN and another app", or "" when nothing else is using a stream.
function ZLtsOthersList(status as object, channelId as string) as string
    names = []
    for each s in ZLtsOthers(status, channelId)
        if s.channelName <> "" then names.push(s.channelName)
    end for
    if status.otherUse = 1 then
        names.push("another app")
    else if status.otherUse > 1 then
        names.push(status.otherUse.toStr() + " other apps")
    end if
    if names.count() = 0 then return ""
    if names.count() = 1 then return names[0]
    head = []
    for i = 0 to names.count() - 2
        head.push(names[i])
    end for
    return ZJoin(head, ", ") + " and " + names[names.count() - 1]
end function

' The line under a channel's Play button, or "" when there is nothing to say.
function ZLtsChannelLine(status as object, channelId as string) as string
    if status.legacy = true then return status.message
    playing = ZLtsStream(status, channelId)
    if playing <> invalid then
        if playing.yours then return "You’re watching this channel."
        text = "Already playing"
        if playing.viewers > 1 then text = text + " for " + playing.viewers.toStr() + " people"
        return text + ". Joining doesn’t use another stream."
    end if
    if not ZLtsIsFull(status) then return ""
    list = ZLtsOthersList(status, channelId)
    if list = "" then return ""
    if status.limit = 1 then return list + " is using the only Live TV stream."
    return list + " are using all " + status.limit.toStr() + " Live TV streams."
end function

' Set when starting this channel would need a stream and none is free:
' { title, text, hint, join } where join is the one channel to watch instead.
function ZLtsBlocked(status as object, channelId as string) as dynamic
    if status.legacy = true then
        if not status.blocked then return invalid
        return { title: "Live TV is in use", text: status.message, hint: "Try again when a stream is free.", join: invalid }
    end if
    request = status.request
    if request <> invalid and ZLtsClean(request.channelId) = ZLtsClean(channelId) then
        if request.canStart then return invalid
    else if ZLtsStream(status, channelId) <> invalid or not ZLtsIsFull(status) then
        return invalid
    end if
    others = ZLtsOthers(status, channelId)
    list = ZLtsOthersList(status, channelId)
    text = "Every Live TV stream is in use right now."
    if list <> "" then
        if status.limit = 1 then
            text = list + " is using the only Live TV stream right now."
        else
            text = list + " are using all " + status.limit.toStr() + " Live TV streams right now."
        end if
    end if
    hint = "Try again when a stream is free."
    join = invalid
    if others.count() = 1 then
        hint = "You can watch " + others[0].channelName + " instead, or try again when a stream is free."
        join = others[0]
    else if others.count() > 1 then
        hint = "You can watch one of those channels instead, or try again when a stream is free."
    end if
    return { title: "Live TV is in use", text: text, hint: hint, join: join }
end function
