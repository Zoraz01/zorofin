' Requests v1 and v2 use the same response shapes and different authenticated routes.
function RequestApi(req as object, tail as object, query = invalid as dynamic, body = invalid as dynamic) as object
    path = ["Zorofin", "Requests"]
    if req.version = 1 then path = ["JellyfinEnhanced", "jellyseerr"]
    path.append(tail)
    method = "GET"
    if body <> invalid then method = "POST"
    return Api(method, path, query, body, true)
end function

function CanUseRequests(req as object) as boolean
    status = RequestApi(req, ["user-status"])
    return status.ok and ZIsMap(status.json) and status.json.active = true and status.json.userFound = true
end function

function CmdRequestBrowse(req as object) as object
    if not CanUseRequests(req) then return { ok: false, message: "Requests are unavailable for this account." }
    page = Int(ZClamp(ZNum(req.page, 1), 1, 500))
    query = { page: page }
    path = ["discover", "trending"]
    term = Left(ZStr(req.term).trim(), 256)
    if term <> "" then
        path = ["search"]
        query.query = term
    end if
    r = RequestApi(req, path, query)
    if not r.ok or not ZIsMap(r.json) or not ZIsArray(r.json.results) then return { ok: false, message: "Couldn’t load requests. Press Options to retry." }
    rows = []
    for each entry in r.json.results
        if ZIsMap(entry) and ZContains(["tv", "movie"], entry.mediaType) and ZNum(entry.id, 0) > 0 then
            kind = entry.mediaType
            title = ZStr(entry.title, ZStr(entry.name))
            rows.push({ id: kind + ":" + entry.id.toStr(), title: title, subtitle: ZStr(entry.releaseDate, ZStr(entry.firstAirDate)), kind: kind, mediaId: entry.id })
        end if
    end for
    return { ok: true, rows: rows, more: page < ZNum(r.json.totalPages, 1) and page < 500 }
end function

function CmdRequestChoice(req as object) as object
    kind = ZStr(req.kind)
    if not ZContains(["movie", "tv"], kind) or ZNum(req.mediaId, 0) <= 0 then return { ok: false }
    if not CanUseRequests(req) then return { ok: false, message: "Requests are unavailable for this account." }
    r = RequestApi(req, [kind, req.mediaId.toStr()])
    if not r.ok or not ZIsMap(r.json) or r.json.id <> req.mediaId then return { ok: false, message: "Couldn’t check the current request status." }
    title = r.json
    info = title.mediaInfo
    if not ZIsMap(info) then info = {}
    body = { mediaId: req.mediaId, mediaType: kind, is4k: false }
    needed = 1
    message = "Request this movie?"
    if kind = "movie" then
        if not ZContains([1, 6, 7], ZNum(info.status, 1)) or not ZContains([1, 6, 7], ZNum(info.status4k, 1)) then return { ok: false, message: "Already available or requested." }
        if ZIsArray(info.requests) then
            for each receipt in info.requests
                if ZIsMap(receipt) and ZContains([1, 2], receipt.status) then return { ok: false, message: "Already requested." }
            end for
        end if
    else
        settings = RequestApi(req, ["settings", "partial-requests"])
        if not settings.ok or not ZIsMap(settings.json) then return { ok: false, message: "Couldn’t check season settings." }
        body.seasons = ZRequestAvailableSeasons(title, settings.json.enableSpecialEpisodes = true)
        needed = body.seasons.count()
        if needed = 0 then return { ok: false, message: "No seasons available to request." }
        if ZNum(ZGet(title, "externalIds", "tvdbId"), 0) > 0 then body.tvdbId = title.externalIds.tvdbId
        message = "Request seasons " + ZJoin(body.seasons, ", ") + "?"
    end if
    quota = RequestApi(req, ["quota"])
    if not quota.ok or not ZIsMap(quota.json) then return { ok: false, message: "Couldn’t check the request quota." }
    cap = quota.json[kind]
    if ZIsMap(cap) and (cap.restricted = true or (ZNum(cap.limit, 0) > 0 and cap.limit - ZNum(cap.used, 0) < needed)) then return { ok: false, message: "This request exceeds the account quota." }
    if req.confirmed = invalid then return { ok: true, choice: body, message: message }
    if kind = "tv" and FormatJson(req.confirmed.seasons) <> FormatJson(body.seasons) then return { ok: false, message: "Available seasons changed. Select the title again." }
    result = RequestApi(req, ["request"], invalid, body)
    if result.ok and ZIsMap(result.json) and ZNum(result.json.id, 0) > 0 then return { ok: true, message: "Request submitted." }
    return { ok: false, message: "Request not confirmed. Check its status before trying again." }
end function
