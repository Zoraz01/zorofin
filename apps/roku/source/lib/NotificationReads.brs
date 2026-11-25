' Account notification receipts; no hosts, tokens or message text persisted here.
function ZNotificationScope(session as dynamic) as string
    if not ZIsMap(session) or ZStr(session.server) = "" or ZStr(session.userId) = "" then return ""
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(ZStr(session.server) + Chr(10) + ZStr(session.userId) + Chr(10) + ZStr(session.token))
    digest = CreateObject("roEVPDigest")
    digest.Setup("sha256")
    return Left(digest.Process(bytes), 32)
end function

function ZNotificationReplyIdentity(reply as object) as string
    id = ZStr(reply.id)
    stamp = ZStr(reply.updatedAt)
    if not CreateObject("roRegex", "^T[a-z0-9]{6,20}$", "").isMatch(id) then return ""
    if Len(stamp) > 64 or Instr(1, stamp, "|") > 0 or ZIsoToSeconds(stamp) <= 0 then return ""
    return id + "|" + stamp
end function

function ZNotificationRequestId(id as dynamic) as boolean
    n = ZNum(id, 0)
    return n > 0 and n <= 2147483647 and Int(n) = n and GetInterface(id, "ifString") = invalid
end function

function ZParseNotificationReads(body as dynamic) as dynamic
    if not ZIsMap(body) or GetInterface(body.initialized, "ifBoolean") = invalid then return invalid
    if not ZIsArray(body.requests) or not ZIsArray(body.replies) then return invalid
    if body.requests.count() > 2000 or body.replies.count() > 500 then return invalid
    requests = {}
    replies = {}
    for each id in body.requests
        if not ZNotificationRequestId(id) then return invalid
        requests[id.toStr()] = true
    end for
    for each key in body.replies
        if GetInterface(key, "ifString") = invalid then return invalid
        at = Instr(1, key, "|")
        if at <= 1 then return invalid
        if ZNotificationReplyIdentity({ id: Left(key, at - 1), updatedAt: Mid(key, at + 1) }) <> key then return invalid
        replies[key] = true
    end for
    return { initialized: body.initialized, requests: requests, replies: replies }
end function

' Only a complete availability check may initialize history. An already
' initialized account disables the new-device local first-snapshot rule.
function ZNotificationPlan(notices as object, replies as object, local as object, remote as dynamic, complete as boolean) as object
    mark = []
    sync = []
    syncReplies = []
    initialize = remote <> invalid and remote.initialized <> true and complete
    history = complete and not (local.initialized = true) and (remote = invalid or remote.initialized <> true)
    for each notice in notices
        key = notice.id.toStr()
        if initialize or history then mark.push(notice.id)
        read = local.requests[key] = true or initialize or history
        if complete and remote <> invalid and read and remote.requests[key] <> true then sync.push(notice.id)
    end for
    if remote <> invalid then
        for each reply in replies
            key = ZNotificationReplyIdentity(reply)
            if key <> "" and reply.localSeen = true and remote.replies[key] <> true then syncReplies.push({ id: reply.id, updatedAt: reply.updatedAt })
        end for
    end if
    return { mark: mark, localInitialized: complete, requests: sync, replies: syncReplies, initialize: initialize }
end function

function ZNotificationRows(notices as object, replies as object, local as object, remote as dynamic) as object
    fresh = []
    old = []
    for each n in notices
        read = local.requests[n.id.toStr()] = true
        if remote <> invalid and remote.requests[n.id.toStr()] = true then read = true
        if read then old.push(n) else fresh.push(n)
    end for
    for each reply in replies
        read = reply.localSeen = true
        key = ZNotificationReplyIdentity(reply)
        if remote <> invalid and key <> "" and remote.replies[key] = true then read = true
        if read then old.push(reply) else fresh.push(reply)
    end for
    return { fresh: fresh, old: old, unread: fresh.count() }
end function

' Every write is <=500 items. Initialize only after all receipts in the batch
' sequence have been recorded, so a partial failure cannot complete history.
function ZNotificationBatches(requests as object, replies as object, initialize = false as boolean) as object
    batches = []
    body = { requests: [], replies: [], initialize: false }
    for each id in requests
        if ZNotificationRequestId(id) then
            if body.requests.count() + body.replies.count() = 500 then
                batches.push(body)
                body = { requests: [], replies: [], initialize: false }
            end if
            body.requests.push(id)
        end if
    end for
    for each reply in replies
        if ZIsMap(reply) and ZNotificationReplyIdentity(reply) <> "" then
            if body.requests.count() + body.replies.count() = 500 then
                batches.push(body)
                body = { requests: [], replies: [], initialize: false }
            end if
            body.replies.push({ id: reply.id, updatedAt: reply.updatedAt })
        end if
    end for
    body.initialize = initialize
    if body.requests.count() + body.replies.count() > 0 or initialize then batches.push(body)
    return batches
end function

' Match the same request receipt, quality and requested seasons used by the
' other clients. Download progress or another season being ready is not enough.
function ZReadyRequest(activity as object, detail as dynamic) as dynamic
    if not ZIsMap(detail) or not ZIsMap(detail.mediaInfo) or not ZIsArray(detail.mediaInfo.requests) then return invalid
    if not ZNotificationRequestId(activity.id) or not ZContains([2, 5], Int(ZNum(activity.requestStatus, 0))) then return invalid
    if not ZContains(["movie", "tv"], ZStr(activity.type)) or ZNum(activity.tmdbId, 0) <> ZNum(detail.id, -1) then return invalid
    if ZStr(activity.title).trim() = "" then return invalid
    for each receipt in detail.mediaInfo.requests
        if ZIsMap(receipt) and receipt.id = activity.id and ZContains([2, 5], Int(ZNum(receipt.status, 0))) then
            if GetInterface(receipt.is4k, "ifBoolean") = invalid then return invalid
            status = detail.mediaInfo.status
            if receipt.is4k then status = detail.mediaInfo.status4k
            available = ZNum(status, 0) = 5
            if activity.type = "tv" and ZIsArray(receipt.seasons) and receipt.seasons.count() > 0 then
                available = ZContains([4, 5], Int(ZNum(status, 0)))
                for each requested in receipt.seasons
                    found = false
                    if ZIsMap(requested) and ZNum(requested.seasonNumber, -1) >= 0 and ZIsArray(detail.mediaInfo.seasons) then
                        for each season in detail.mediaInfo.seasons
                            if ZIsMap(season) and season.seasonNumber = requested.seasonNumber then
                                s = season.status
                                if receipt.is4k then s = season.status4k
                                found = ZNum(s, 0) = 5
                            end if
                        end for
                    end if
                    if not found then available = false
                end for
            end if
            if not available then return invalid
            message = "Your request is available."
            if receipt.is4k then message = "Your 4K request is available."
            return { id: activity.id, kind: "request", affectedMedia: Left(ZStr(activity.title), 160), issueType: "Request available", message: message, updatedAt: "" }
        end if
    end for
    return invalid
end function


' Monotonic receipts prevent a late POST response from undoing a newer GET.
function ZMergeNotificationReads(current as dynamic, incoming as dynamic) as dynamic
    if incoming = invalid then return current
    if current = invalid then return incoming
    requests = {}
    replies = {}
    requests.append(current.requests)
    requests.append(incoming.requests)
    replies.append(current.replies)
    replies.append(incoming.replies)
    return { initialized: current.initialized or incoming.initialized, requests: requests, replies: replies }
end function
