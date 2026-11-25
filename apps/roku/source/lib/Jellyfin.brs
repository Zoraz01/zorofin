' Jellyfin addressing and authorization rules, ported from the Apple and
' Flutter clients (ServerAddress, ClientIdentity). Pure functions only.

' Parses what the viewer typed into candidate base URLs to probe, in order.
' Returns { ok, candidates: [url...], error }.
' Bare hosts try HTTPS first; plain HTTP is allowed only for local addresses
' (private IPv4, .local, localhost), matching the other Zorofin apps.
function ZServerCandidates(input as dynamic) as object
    text = ZStr(input).trim()
    if text = "" then return { ok: false, error: "Enter your server address." }
    lower = LCase(text)
    if Instr(1, lower, "://") > 0 then
        parsed = ZParseServer(text)
        if not parsed.ok then return parsed
        if parsed.scheme = "http" and not ZIsLocalHost(parsed.host) then
            return { ok: false, error: "Use https:// for servers outside your home network." }
        end if
        return { ok: true, candidates: [parsed.url] }
    end if
    parsed = ZParseServer("https://" + text)
    if not parsed.ok then return parsed
    candidates = [parsed.url]
    if ZIsLocalHost(parsed.host) then
        httpUrl = ZParseServer("http://" + text)
        if httpUrl.ok then
            ' Jellyfin's default plain-HTTP port when none was typed.
            if not httpUrl.hasPort then
                candidates.push("http://" + httpUrl.hostPort + ":8096" + httpUrl.path)
            end if
            candidates.push(httpUrl.url)
        end if
    end if
    return { ok: true, candidates: candidates }
end function

' Validates and normalizes "scheme://host[:port][/path]" into a base URL that
' always ends with "/". No credentials, query, fragment or dot segments.
function ZParseServer(text as string) as object
    bad = { ok: false, error: "That doesn't look like a server address." }
    re = CreateObject("roRegex", "^(https?)://([^/?#@\s]+)(/[^?#\s]*)?$", "i")
    match = re.match(text.trim())
    if match.count() < 3 then return bad
    scheme = LCase(match[1])
    hostPort = LCase(match[2])
    path = ""
    if match.count() > 3 then path = match[3]
    if Instr(1, path, "\") > 0 or Instr(1, path, "%") > 0 then return bad
    segments = path.split("/")
    for each s in segments
        if s = "." or s = ".." then return bad
    end for
    host = hostPort
    hasPort = false
    portRe = CreateObject("roRegex", "^(\[[0-9a-f:.]+\]|[a-z0-9.-]+)(:([0-9]{1,5}))?$", "i")
    hp = portRe.match(hostPort)
    if hp.count() < 2 then return bad
    host = hp[1]
    if hp.count() > 3 and hp[3] <> "" then
        port = hp[3].toInt()
        if port < 1 or port > 65535 then return bad
        hasPort = true
    end if
    if host = "" or Left(host, 1) = "." or Left(host, 1) = "-" then return bad
    clean = []
    for each s in segments
        if s <> "" then clean.push(s)
    end for
    normalized = "/"
    if clean.count() > 0 then normalized = "/" + ZJoin(clean, "/") + "/"
    return {
        ok: true,
        scheme: scheme,
        host: host,
        hostPort: hostPort,
        hasPort: hasPort,
        path: normalized,
        url: scheme + "://" + hostPort + normalized
    }
end function

function ZIsLocalHost(host as string) as boolean
    h = LCase(host)
    if h = "localhost" or h = "[::1]" or Right(h, 6) = ".local" then return true
    if Left(h, 1) = "[" then
        inner = Mid(h, 2, Len(h) - 2)
        re6 = CreateObject("roRegex", "^(f[cd][0-9a-f]{0,2}|fe[89ab][0-9a-f]?):", "")
        return re6.isMatch(inner)
    end if
    re = CreateObject("roRegex", "^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$", "")
    m = re.match(h)
    if m.count() < 5 then return false
    a = m[1].toInt()
    b = m[2].toInt()
    for i = 1 to 4
        if m[i].toInt() > 255 then return false
    end for
    if a = 10 or a = 127 then return true
    if a = 192 and b = 168 then return true
    if a = 172 and b >= 16 and b <= 31 then return true
    if a = 169 and b = 254 then return true
    if a = 100 and b >= 64 and b <= 127 then return true
    return false
end function

' Joins validated path components onto the base URL.
' Components must be plain identifiers, so nothing can escape the base path.
function ZEndpoint(base as string, path as object, query = invalid as dynamic) as string
    re = CreateObject("roRegex", "^[A-Za-z0-9_-]+([.][A-Za-z0-9_-]+)*$", "")
    for each part in path
        if not re.isMatch(ZStr(part)) then return ""
    end for
    url = base + ZJoin(path, "/")
    q = ZQuery(query)
    if q <> "" then url = url + "?" + q
    return url
end function

' MediaBrowser authorization header, same field order as the Apple client.
' Quotes, backslashes and control characters are stripped from values.
function ZAuthHeader(deviceName as string, deviceId as string, version as string, token = "" as string) as string
    fields = [
        ["Client", "Zorofin"],
        ["Device", deviceName],
        ["DeviceId", deviceId],
        ["Version", version]
    ]
    if token <> "" then fields.push(["Token", token])
    parts = []
    for each f in fields
        parts.push(f[0] + "=" + Chr(34) + ZHeaderSafe(f[1]) + Chr(34))
    end for
    return "MediaBrowser " + ZJoin(parts, ", ")
end function

function ZHeaderSafe(value as string) as string
    out = ""
    for i = 1 to Len(value)
        c = Mid(value, i, 1)
        code = Asc(c)
        if code >= 32 and code < 127 and code <> 34 and code <> 92 then out = out + c
    end for
    return out
end function

' Artwork URL; Jellyfin serves images without a token.
function ZImageUrl(base as string, itemId as dynamic, kind as string, tag as dynamic, width as integer) as string
    if itemId = invalid or ZStr(itemId) = "" or tag = invalid or ZStr(tag) = "" then return ""
    query = { maxWidth: ZClamp(width, 80, 1920), quality: 85, tag: tag }
    return ZEndpoint(base, ["Items", itemId, "Images", kind], query)
end function

function ZUserImageUrl(base as string, userId as dynamic, tag as dynamic, width = 240 as integer) as string
    if userId = invalid or tag = invalid or ZStr(tag) = "" then return ""
    return ZEndpoint(base, ["Users", userId, "Images", "Primary"], { maxWidth: width, quality: 85, tag: tag })
end function

' Resolves a server-provided relative media path (a TranscodingUrl or
' subtitle DeliveryUrl) against the base and attaches the token, refusing
' anything that would leave this server.
function ZMediaUrl(base as string, reference as string, token as string) as string
    if reference = "" or Instr(1, reference, "\") > 0 then return ""
    lower = LCase(reference)
    if Left(lower, 7) = "http://" or Left(lower, 8) = "https://" then
        if Left(lower, Len(base)) <> LCase(base) then return ""
        target = reference
    else
        rel = reference
        while Left(rel, 1) = "/"
            rel = Mid(rel, 2)
        end while
        target = base + rel
    end if
    pathPart = target
    q = Instr(1, target, "?")
    queryPart = ""
    if q > 0 then
        pathPart = Left(target, q - 1)
        queryPart = Mid(target, q + 1)
    end if
    for each seg in pathPart.split("/")
        if seg = ".." or seg = "." then return ""
    end for
    kept = []
    if queryPart <> "" then
        for each pair in queryPart.split("&")
            key = LCase(pair.split("=")[0])
            if key <> "apikey" and key <> "api_key" and key <> "x-emby-token" and key <> "token" and key <> "access_token" and pair <> "" then kept.push(pair)
        end for
    end if
    kept.push("ApiKey=" + ZEscape(token))
    return pathPart + "?" + ZJoin(kept, "&")
end function

' MARK: Deep links (Roku certification: contentId + mediaType)

' What a deep link's mediaType asks for: "play" (straight into playback),
' "series" or "season" (play the smart bookmark), "item" (no type given:
' go by the item) or "invalid" (an unknown type, which lands on Home).
function ZDeepLinkAction(mediaType as dynamic) as string
    t = LCase(ZStr(mediaType))
    if t = "" then return "item"
    if t = "movie" or t = "episode" or t = "shortformvideo" or t = "tvspecial" or t = "special" or t = "live" then return "play"
    if t = "series" or t = "season" then return t
    return "invalid"
end function

' A Jellyfin item id (32 hex digits, dashes allowed), lower case, or "".
function ZDeepLinkId(contentId as dynamic) as string
    id = LCase(CreateObject("roRegex", "-", "").replaceAll(ZStr(contentId).trim(), ""))
    re = CreateObject("roRegex", "^[0-9a-f]{32}$", "")
    if not re.isMatch(id) then return ""
    return id
end function

' What a resolved item does: "play", "details" (a show or season with no
' episode to play) or "" when a link can't open it (folders, people…).
function ZDeepLinkTarget(itemType as dynamic) as string
    t = ZStr(itemType)
    if t = "Movie" or t = "Episode" or t = "Video" or t = "MusicVideo" or t = "TvChannel" then return "play"
    if t = "Series" or t = "Season" then return "details"
    return ""
end function

' The episode a series or season link plays (smart bookmark): the first one
' in progress, else the first unwatched, else the first.
function ZBookmarkEpisode(episodes as dynamic) as dynamic
    if not ZIsArray(episodes) or episodes.count() = 0 then return invalid
    for each e in episodes
        if ZNum(ZGet(e, "UserData", "PlaybackPositionTicks"), 0) > 0 and ZGet(e, "UserData", "Played") <> true then return e
    end for
    for each e in episodes
        if ZGet(e, "UserData", "Played") <> true then return e
    end for
    return episodes[0]
end function
