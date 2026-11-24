sub init()
    m.top.functionName = "execute"
end sub

sub execute()
    req = m.top.request
    if req = invalid then req = {}
    m.session = m.global.session
    cmd = ZStr(req.cmd)
    handlers = {
        probe: CmdProbe,
        publicUsers: CmdPublicUsers,
        login: CmdLogin,
        qcInitiate: CmdQuickConnectInitiate,
        qcPoll: CmdQuickConnectPoll,
        validate: CmdValidate,
        logout: CmdLogout,
        home: CmdHome,
        views: CmdViews,
        items: CmdItems,
        item: CmdItem,
        episodes: CmdEpisodes,
        seasons: CmdSeasons,
        search: CmdSearch,
        searchHints: CmdSearchHints,
        guideChannels: CmdGuideChannels,
        guidePrograms: CmdGuidePrograms,
        playback: CmdPlayback,
        report: CmdReport,
        nextEpisode: CmdNextEpisode,
        setPlayed: CmdSetPlayed,
        setFavorite: CmdSetFavorite,
        resolve: CmdResolve,
        liveStreams: CmdLiveStreams,
        supportReplies: CmdSupportReplies,
        submitSupport: CmdSubmitSupport,
        authorizeQuickConnect: CmdAuthorizeQuickConnect,
        viewerSettings: CmdViewerSettings,
        saveViewerSettings: CmdSaveViewerSettings,
        languages: CmdLanguages,
        changePassword: CmdChangePassword
    }
    handler = handlers[cmd]
    if handler = invalid then
        m.top.response = { ok: false, error: "invalid", cmd: cmd }
        return
    end if
    result = handler(req)
    if result = invalid then result = { ok: false, error: "invalid" }
    result.cmd = cmd
    m.top.response = result
end sub

' MARK: Request helpers

function ServerBase() as string
    if m.session = invalid then return ""
    return ZStr(m.session.server)
end function

function AuthHeaders(token = invalid as dynamic) as object
    s = m.session
    deviceId = ""
    deviceName = "Roku"
    if s <> invalid then
        deviceId = ZStr(s.deviceId)
        deviceName = ZStr(s.deviceName, "Roku")
        if token = invalid then token = ZStr(s.token)
    end if
    if deviceId = "" then deviceId = ZStr(m.top.request.deviceId)
    if m.top.request.deviceName <> invalid then deviceName = m.top.request.deviceName
    if token = invalid then token = ""
    return { Authorization: ZAuthHeader(deviceName, deviceId, ZStr(m.global.appVersion, "1.0.0"), token) }
end function

' Authenticated call on the session's server. Zorofin module routes also
' get X-Jellyfin-Token, which the plugin and companion read.
function Api(method as string, path as object, query = invalid as dynamic, body = invalid as dynamic, extension = false as boolean) as object
    url = ZEndpoint(ServerBase(), path, query)
    headers = AuthHeaders()
    if extension then headers["X-Jellyfin-Token"] = ZStr(m.session.token)
    return ZHttp(method, url, headers, body)
end function

function Fail(r as object) as object
    code = r.error
    if code = "" or code = invalid then code = "invalid"
    return { ok: false, error: code, status: r.status }
end function

function ViewerId() as string
    return ZStr(m.session.userId)
end function

function NodesFrom(list as dynamic, parent as object) as integer
    count = 0
    if not ZIsArray(list) then return 0
    base = ServerBase()
    for each json in list
        if ZIsMap(json) and ZStr(json.Id) <> "" then
            parent.appendChild(ZItemNode(json, base))
            count = count + 1
        end if
    end for
    return count
end function

function MakeRow(title as string, id as string, landscape = false as boolean) as object
    row = CreateObject("roSGNode", "ContentNode")
    row.title = title
    row.id = id
    row.addFields({ landscape: landscape })
    return row
end function

' MARK: Connect and sign in

function CmdProbe(req as object) as object
    parsed = ZServerCandidates(req.address)
    if not parsed.ok then return { ok: false, error: "address", message: parsed.error }
    lastError = "network"
    for each base in parsed.candidates
        r = ZHttp("GET", ZEndpoint(base, ["System", "Info", "Public"]), {}, invalid, 8000)
        if r.ok and ZIsMap(r.json) and ZStr(r.json.Id) <> "" then
            return {
                ok: true,
                server: base,
                serverId: r.json.Id,
                serverName: ZStr(r.json.ServerName, "Jellyfin"),
                version: ZStr(r.json.Version)
            }
        end if
        if r.ok then lastError = "notJellyfin"
    end for
    message = "Couldn't reach a Jellyfin server at that address."
    if lastError = "notJellyfin" then message = "That address answered, but it isn't a Jellyfin server."
    return { ok: false, error: lastError, message: message }
end function

function CmdPublicUsers(req as object) as object
    base = ZStr(req.server)
    r = ZHttp("GET", ZEndpoint(base, ["Users", "Public"]), AuthHeaders(""), invalid, 8000)
    users = []
    if r.ok and ZIsArray(r.json) then
        for each u in r.json
            if ZIsMap(u) and ZStr(u.Id) <> "" then
                users.push({
                    id: u.Id,
                    name: ZStr(u.Name),
                    hasPassword: ZBool(u.HasPassword),
                    image: ZUserImageUrl(base, u.Id, u.PrimaryImageTag)
                })
            end if
        end for
    end if
    qc = ZHttp("GET", ZEndpoint(base, ["QuickConnect", "Enabled"]), AuthHeaders(""), invalid, 8000)
    return { ok: true, users: users, quickConnect: qc.ok and qc.text.trim() = "true" }
end function

function SessionFrom(base as string, json as dynamic, req as object) as object
    if not ZIsMap(json) or not ZIsMap(json.User) or ZStr(json.AccessToken) = "" then return { ok: false, error: "invalid" }
    user = json.User
    policy = user.Policy
    return {
        ok: true,
        account: {
            server: base,
            serverId: ZStr(json.ServerId, ZStr(req.serverId)),
            serverName: ZStr(req.serverName),
            userId: user.Id,
            userName: ZStr(user.Name),
            imageTag: ZStr(user.PrimaryImageTag),
            isAdmin: ZIsMap(policy) and policy.IsAdministrator = true,
            token: json.AccessToken
        }
    }
end function

function CmdLogin(req as object) as object
    base = ZStr(req.server)
    body = { Username: ZStr(req.username), Pw: ZStr(req.password) }
    r = ZHttp("POST", ZEndpoint(base, ["Users", "AuthenticateByName"]), AuthHeaders(""), body)
    if not r.ok then
        if r.status = 401 or r.status = 400 then return { ok: false, error: "credentials" }
        return Fail(r)
    end if
    return SessionFrom(base, r.json, req)
end function

function CmdQuickConnectInitiate(req as object) as object
    base = ZStr(req.server)
    r = ZHttp("POST", ZEndpoint(base, ["QuickConnect", "Initiate"]), AuthHeaders(""))
    if not r.ok or not ZIsMap(r.json) then return Fail(r)
    return { ok: true, secret: ZStr(r.json.Secret), code: ZStr(r.json.Code) }
end function

function CmdQuickConnectPoll(req as object) as object
    base = ZStr(req.server)
    r = ZHttp("GET", ZEndpoint(base, ["QuickConnect", "Connect"], { secret: req.secret }), AuthHeaders(""), invalid, 8000)
    if not r.ok or not ZIsMap(r.json) then return Fail(r)
    if r.json.Authenticated <> true then return { ok: true, authenticated: false }
    done = ZHttp("POST", ZEndpoint(base, ["Users", "AuthenticateWithQuickConnect"]), AuthHeaders(""), { Secret: req.secret })
    if not done.ok then return Fail(done)
    result = SessionFrom(base, done.json, req)
    result.authenticated = result.ok
    return result
end function

' Confirms a saved account still works and refreshes its name and photo.
function CmdValidate(req as object) as object
    r = Api("GET", ["Users", "Me"])
    if not r.ok then return Fail(r)
    policy = r.json.Policy
    return {
        ok: true,
        userName: ZStr(r.json.Name),
        imageTag: ZStr(r.json.PrimaryImageTag),
        isAdmin: ZIsMap(policy) and policy.IsAdministrator = true
    }
end function

function CmdLogout(req as object) as object
    r = Api("POST", ["Sessions", "Logout"])
    return { ok: r.ok }
end function

' MARK: Home

' Optional Zorofin modules on this server (plugin first, older adapter next).
function Capabilities() as object
    for each path in [["Zorofin", "Capabilities"], ["support", "capabilities"]]
        r = Api("GET", path, invalid, invalid, true)
        if r.ok and ZIsMap(r.json) and ZIsMap(r.json.features) then
            features = {}
            for each key in r.json.features
                f = r.json.features[key]
                if ZIsMap(f) and ZBool(f.enabled) then features[key] = Int(ZNum(f.version, 1))
            end for
            return features
        end if
        if r.status <> 404 then exit for
    end for
    return {}
end function

function CmdViews(req as object) as object
    r = Api("GET", ["UserViews"], { userId: ViewerId() })
    if not r.ok then return Fail(r)
    content = CreateObject("roSGNode", "ContentNode")
    NodesFrom(r.json.Items, content)
    m.top.content = content
    return { ok: true, count: content.getChildCount() }
end function

function CmdHome(req as object) as object
    uid = ViewerId()
    features = Capabilities()
    root = CreateObject("roSGNode", "ContentNode")
    base = ServerBase()

    ' Library views drive the tab bar and the "Recently added" rows.
    views = Api("GET", ["UserViews"], { userId: uid })
    if not views.ok then return Fail(views)
    viewList = []
    if ZIsArray(views.json.Items) then viewList = views.json.Items

    ' Banner candidates.
    banner = invalid
    pool = Api("GET", ["Items"], {
        userId: uid, recursive: true, includeItemTypes: "Movie,Series", limit: 12,
        sortBy: "CommunityRating,SortName", sortOrder: "Descending",
        fields: "Overview,Genres,MediaStreams,ProductionYear", enableUserData: true,
        enableImageTypes: "Primary,Backdrop,Logo,Thumb", imageTypeLimit: 1,
        excludeLocationTypes: "Virtual", isPlaceHolder: false
    })
    if pool.ok and ZIsArray(pool.json.Items) then
        pick = ZPickBanner(pool.json.Items)
        if pick <> invalid then banner = ZItemNode(pick, base)
    end if

    usedServerFeed = false
    if features.homeSections <> invalid then
        r = Api("GET", ["Zorofin", "Home", "Sections"], invalid, invalid, true)
        rows = invalid
        if r.ok then rows = ZParseHomeFeed(r.json)
        if rows <> invalid and rows.count() > 0 then
            usedServerFeed = true
            for each section in rows
                landscape = section.id = "continue-watching"
                row = MakeRow(section.title, section.id, landscape)
                for each card in section.cards
                    node = ZItemNode(card.item, base)
                    split = ZSplitBadges(card.badges)
                    if split.quality.count() > 0 then node.badges = split.quality
                    node.contextBadges = split.context
                    if card.subtitle <> "" then node.caption = card.subtitle
                    row.appendChild(node)
                end for
                root.appendChild(row)
            end for
        end if
    end if

    if not usedServerFeed then
        BuildClientHome(root, uid, viewList, features)
    end if

    ' The banner travels as the first child row, id "banner".
    if banner <> invalid then
        bannerRow = MakeRow("", "banner", true)
        bannerRow.appendChild(banner)
        root.insertChild(bannerRow, 0)
    end if
    m.top.content = root
    nav = []
    for each v in viewList
        nav.push({ id: v.Id, name: ZStr(v.Name), collectionType: ZStr(v.CollectionType) })
    end for
    return { ok: true, views: nav, features: features, hasBanner: banner <> invalid, serverFeed: usedServerFeed }
end function

' Home without the plugin: Continue Watching, the optional legacy server rows,
' then recently added per library.
sub BuildClientHome(root as object, uid as string, viewList as object, features as object)
    base = ServerBase()
    resume = Api("GET", ["UserItems", "Resume"], { userId: uid, limit: 20, mediaTypes: "Video", fields: ZItemFields(), imageTypeLimit: 1, enableImageTypes: "Primary,Backdrop,Thumb" })
    nextUp = Api("GET", ["Shows", "NextUp"], { userId: uid, limit: 20, fields: ZItemFields(), imageTypeLimit: 1, enableImageTypes: "Primary,Backdrop,Thumb" })
    resumeItems = []
    nextItems = []
    if resume.ok and ZIsArray(resume.json.Items) then resumeItems = resume.json.Items
    if nextUp.ok and ZIsArray(nextUp.json.Items) then nextItems = nextUp.json.Items
    cw = ZContinueWatching(resumeItems, nextItems)
    if cw.count() > 0 then
        row = MakeRow("Continue Watching", "continue-watching", true)
        NodesFrom(cw, row)
        root.appendChild(row)
    end if

    version = features.homeRows
    if version <> invalid then
        path = ["support", "home", "rows"]
        if version >= 2 then path = ["Zorofin", "Home", "Rows"]
        r = Api("GET", path, invalid, invalid, true)
        rows = invalid
        if r.ok then rows = ZParseHomeFeed(r.json)
        if rows <> invalid then
            for each section in rows
                row = MakeRow(section.title, section.id, false)
                for each card in section.cards
                    node = ZItemNode(card.item, base)
                    split = ZSplitBadges(card.badges)
                    if split.quality.count() > 0 then node.badges = split.quality
                    node.contextBadges = split.context
                    if card.subtitle <> "" then node.caption = card.subtitle
                    row.appendChild(node)
                end for
                root.appendChild(row)
            end for
        end if
    end if

    ' Apple TV Home: the newest movies and shows across every library.
    for each shelf in [{ title: "Recently Added Movies", types: "Movie", id: "latest-movies" }, { title: "Recently Added Shows", types: "Series", id: "latest-shows" }]
        latest = Api("GET", ["Items"], {
            userId: uid, recursive: true, includeItemTypes: shelf.types, limit: 30,
            sortBy: "DateCreated,SortName", sortOrder: "Descending", fields: ZItemFields(),
            enableImageTypes: "Primary,Backdrop,Logo,Thumb", imageTypeLimit: 1
        })
        if latest.ok and ZIsArray(latest.json.Items) and latest.json.Items.count() > 0 then
            row = MakeRow(shelf.title, shelf.id, false)
            NodesFrom(latest.json.Items, row)
            root.appendChild(row)
        end if
    end for
end sub

' MARK: Library

function CmdItems(req as object) as object
    query = {
        userId: ViewerId(),
        recursive: true,
        startIndex: Int(ZNum(req.startIndex, 0)),
        limit: Int(ZClamp(ZNum(req.limit, 60), 1, 200)),
        fields: ZItemFields(),
        enableImageTypes: "Primary,Backdrop,Thumb",
        imageTypeLimit: 1,
        enableTotalRecordCount: true,
        sortBy: ZStr(req.sortBy, "SortName"),
        sortOrder: ZStr(req.sortOrder, "Ascending")
    }
    if ZStr(req.parentId) <> "" then query.parentId = req.parentId
    if ZStr(req.types) <> "" then query.includeItemTypes = req.types
    if req.favorites = true then query.filters = "IsFavorite"
    if req.unplayed = true then query.isPlayed = false
    if ZStr(req.genre) <> "" then query.genres = req.genre
    r = Api("GET", ["Items"], query)
    if not r.ok then return Fail(r)
    content = CreateObject("roSGNode", "ContentNode")
    NodesFrom(r.json.Items, content)
    m.top.content = content
    return { ok: true, total: Int(ZNum(r.json.TotalRecordCount, 0)), startIndex: query.startIndex }
end function

' MARK: Details

function CmdItem(req as object) as object
    uid = ViewerId()
    id = ZStr(req.id)
    r = Api("GET", ["Items", id], { userId: uid, fields: "Overview,Genres,Taglines,People,MediaSources,MediaStreams,ProductionYear,Studios,ChildCount" })
    if not r.ok then return Fail(r)
    json = r.json
    base = ServerBase()
    root = CreateObject("roSGNode", "ContentNode")
    item = ZItemNode(json, base)
    kind = ZStr(json.Type)

    detail = {
        ok: true,
        id: id,
        type: kind,
        tagline: ZStr(ZFirst(json.Taglines)),
        genres: json.Genres,
        endsAt: "",
        resumeId: "",
        resumeLabel: "",
        resumePosition: 0,
        nextLabel: "",
        seasonId: ""
    }
    ' The file the Play button would start: the title itself, or for a show
    ' its next episode (Apple's "playable"); its quality and tracks show here.
    playable = json
    if kind = "Series" or kind = "Season" then
        seriesId = id
        if kind = "Season" then seriesId = ZStr(json.SeriesId)
        nextUp = Api("GET", ["Shows", "NextUp"], { userId: uid, seriesId: seriesId, limit: 1, fields: ZItemFields(), enableResumable: true })
        n = invalid
        if nextUp.ok and ZIsArray(nextUp.json.Items) and nextUp.json.Items.count() > 0 then n = nextUp.json.Items[0]
        if n <> invalid and kind = "Season" and ZStr(n.SeasonId) <> id then n = invalid
        if n = invalid then
            ' Nothing in progress: the first episode (of this season).
            query = { userId: uid, limit: 1, fields: ZItemFields(), isMissing: false, sortBy: "ParentIndexNumber,IndexNumber" }
            if kind = "Season" then query.seasonId = id
            first = Api("GET", ["Shows", seriesId, "Episodes"], query)
            if first.ok and ZIsArray(first.json.Items) then
                for each e in first.json.Items
                    if n = invalid and (kind = "Season" or ZNum(e.ParentIndexNumber, 0) > 0) then n = e
                end for
                if n = invalid and first.json.Items.count() > 0 then n = first.json.Items[0]
            end if
        end if
        playable = invalid
        if n <> invalid then
            full = Api("GET", ["Items", ZStr(n.Id)], { userId: uid, fields: "MediaSources,MediaStreams" })
            playable = n
            if full.ok and ZIsMap(full.json) then playable = full.json
            detail.resumeId = ZStr(n.Id)
            detail.resumeLabel = ZEpisodeLabel(n.ParentIndexNumber, n.IndexNumber)
            detail.resumeSeasonId = ZStr(n.SeasonId)
            detail.resumePosition = ZNum(ZGet(n, "UserData", "PlaybackPositionTicks"), 0)
            detail.nextLabel = "Next episode · " + detail.resumeLabel
        end if
        if kind = "Season" then detail.resumeSeasonId = id
    end if
    quality = ZQuality(playable)
    detail.badges = quality.badges
    detail.facts = quality.facts
    detail.audioTracks = StreamList(playable, "Audio")
    detail.subtitleTracks = StreamList(playable, "Subtitle")

    ' Seasons for the season picker (shows, seasons and episodes).
    seriesId = ""
    if kind = "Series" then seriesId = id
    if kind = "Season" or kind = "Episode" then seriesId = ZStr(json.SeriesId)
    if seriesId <> "" then
        seasons = Api("GET", ["Shows", seriesId, "Seasons"], { userId: uid, isMissing: false, fields: "ChildCount", enableImageTypes: "Primary", imageTypeLimit: 1 })
        seasonsRow = MakeRow("Seasons", "seasons")
        if seasons.ok then NodesFrom(seasons.json.Items, seasonsRow)
        root.appendChild(seasonsRow)
        detail.seriesId = seriesId
        detail.seasonId = ZStr(detail.resumeSeasonId)
        if kind = "Episode" then detail.seasonId = ZStr(json.SeasonId)
        if detail.seasonId = "" and seasonsRow.getChildCount() > 0 then
            ' Specials last: the first numbered season opens first.
            for i = 0 to seasonsRow.getChildCount() - 1
                s = seasonsRow.getChild(i)
                if detail.seasonId = "" and s.episodeIndex > 0 then detail.seasonId = s.id
            end for
            if detail.seasonId = "" then detail.seasonId = seasonsRow.getChild(0).id
        end if
        detail.resumeSeasonId = detail.seasonId
    end if

    ' Cast & Crew with photos, like Apple's person cards.
    if ZIsArray(json.People) and json.People.count() > 0 then
        people = MakeRow("Cast & Crew", "people")
        for each p in json.People
            if ZIsMap(p) and ZStr(p.Id) <> "" and people.getChildCount() < 24 then
                node = CreateObject("roSGNode", "ZItem")
                node.id = ZStr(p.Id)
                node.itemType = "Person"
                node.title = ZStr(p.Name)
                node.caption = ZStr(p.Role, ZStr(p.Type))
                if ZStr(p.PrimaryImageTag) <> "" then
                    node.HDPosterUrl = ZImageUrl(base, p.Id, "Primary", p.PrimaryImageTag, 240)
                    node.FHDPosterUrl = node.HDPosterUrl
                end if
                people.appendChild(node)
            end if
        end for
        if people.getChildCount() > 0 then root.appendChild(people)
    end if

    if kind <> "TvChannel" and kind <> "Program" then
        similar = Api("GET", ["Items", id, "Similar"], { userId: uid, limit: 12, fields: ZItemFields() })
        if similar.ok then
            moreRow = MakeRow("More Like This", "similar", true)
            NodesFrom(similar.json.Items, moreRow)
            if moreRow.getChildCount() > 0 then root.appendChild(moreRow)
        end if
    end if

    root.insertChild(item, 0)
    m.top.content = root
    return detail
end function

function StreamList(json as dynamic, kind as string) as object
    out = []
    if not ZIsMap(json) then return out
    streams = json.MediaStreams
    if not ZIsArray(streams) and ZIsArray(json.MediaSources) and json.MediaSources.count() > 0 then streams = json.MediaSources[0].MediaStreams
    if not ZIsArray(streams) then return out
    for each s in streams
        if ZIsMap(s) and s.Type = kind then
            title = ZStr(s.DisplayTitle, ZStr(s.Title, ZStr(s.Language, "Track")))
            out.push({ index: Int(ZNum(s.Index, -1)), title: title, language: ZStr(s.Language), isDefault: ZBool(s.IsDefault), isExternal: ZBool(s.IsExternal), codec: ZStr(s.Codec) })
        end if
    end for
    return out
end function

function CmdEpisodes(req as object) as object
    r = Api("GET", ["Shows", ZStr(req.seriesId), "Episodes"], {
        userId: ViewerId(), seasonId: req.seasonId, fields: ZItemFields(), isMissing: false,
        enableImageTypes: "Primary,Thumb,Backdrop", imageTypeLimit: 1,
        sortBy: "ParentIndexNumber,IndexNumber,SortName"
    })
    if not r.ok then return Fail(r)
    content = CreateObject("roSGNode", "ContentNode")
    NodesFrom(r.json.Items, content)
    m.top.content = content
    return { ok: true, seasonId: req.seasonId, count: content.getChildCount() }
end function

'' Seasons of a series for the player's Seasons & episodes panel.
function CmdSeasons(req as object) as object
    r = Api("GET", ["Shows", ZStr(req.seriesId), "Seasons"], { userId: ViewerId(), isMissing: false, enableImages: false })
    if not r.ok then return Fail(r)
    seasons = []
    if ZIsArray(r.json.Items) then
        for each it in r.json.Items
            seasons.push({ id: ZStr(it.Id), name: ZStr(it.Name), index: Int(ZNum(it.IndexNumber, -1)) })
        end for
    end if
    return { ok: true, seriesId: req.seriesId, seasons: seasons }
end function

' MARK: Search

function CmdSearch(req as object) as object
    term = ZStr(req.term).trim()
    root = CreateObject("roSGNode", "ContentNode")
    if req.recommend = true then return CmdSearchPicks(root)
    if Len(term) < 2 then
        m.top.content = root
        return { ok: true, term: term }
    end if
    if Len(term) > 256 then term = Left(term, 256)
    groups = [
        { title: "Movies", types: "Movie" },
        { title: "Shows", types: "Series" },
        { title: "Episodes", types: "Episode" },
        { title: "Channels", types: "TvChannel" }
    ]
    for each g in groups
        r = Api("GET", ["Items"], {
            userId: ViewerId(), recursive: true, searchTerm: term, includeItemTypes: g.types,
            limit: 24, fields: ZItemFields(), enableImageTypes: "Primary,Backdrop,Thumb", imageTypeLimit: 1
        })
        if not r.ok and r.error = "unauthorized" then return Fail(r)
        if r.ok then
            row = MakeRow(g.title, "search-" + LCase(g.title), g.types = "Episode" or g.types = "TvChannel")
            NodesFrom(r.json.Items, row)
            if row.getChildCount() > 0 then root.appendChild(row)
        end if
    end for
    m.top.content = root
    return { ok: true, term: term }
end function

'' Recommended titles for an empty search (Apple searchRecommendations): the
' newest 30 movies and 30 shows, ranked by ZSearchPicks, in two rows of 12.
function CmdSearchPicks(root as object) as object
    pool = []
    for each kind in ["Movie", "Series"]
        r = Api("GET", ["Items"], {
            userId: ViewerId(), recursive: true, includeItemTypes: kind, limit: 30,
            sortBy: "DateCreated,SortName", sortOrder: "Descending", fields: ZItemFields(),
            enableImageTypes: "Primary,Backdrop,Thumb", imageTypeLimit: 1
        })
        if not r.ok and r.error = "unauthorized" then return Fail(r)
        if r.ok and ZIsArray(r.json.Items) then pool.append(r.json.Items)
    end for
    picks = ZSearchPicks(pool)
    if picks.count() > 0 then
        first = MakeRow("Recommended", "search-picks")
        second = MakeRow("", "search-picks-2")
        for i = 0 to picks.count() - 1
            if i < 12 then NodesFrom([picks[i]], first) else NodesFrom([picks[i]], second)
        end for
        root.appendChild(first)
        if second.getChildCount() > 0 then root.appendChild(second)
    end if
    m.top.content = root
    return { ok: true, term: "", recommend: true }
end function

' Title suggestions while typing, most relevant first (Search/Hints).
function CmdSearchHints(req as object) as object
    term = ZStr(req.term).trim()
    if Len(term) < 2 then return { ok: true, term: term, hints: [] }
    r = Api("GET", ["Search", "Hints"], {
        userId: ViewerId(), searchTerm: Left(term, 256), limit: 6,
        includeItemTypes: "Movie,Series,Episode,TvChannel"
    })
    if not r.ok then return Fail(r)
    hints = []
    if ZIsArray(r.json.SearchHints) then
        for each h in r.json.SearchHints
            kind = ZStr(h.Type)
            detail = ZKindName(kind)
            if kind = "Episode" then detail = ZJoin([ZStr(h.Series), ZEpisodeLabel(h.ParentIndexNumber, h.IndexNumber)], " · ")
            if (kind = "Movie" or kind = "Series") and ZNum(h.ProductionYear, 0) > 0 then detail = detail + " · " + Int(h.ProductionYear).toStr()
            hints.push({ id: ZStr(h.Id), name: ZStr(h.Name), kind: kind, detail: detail })
        end for
    end if
    return { ok: true, term: term, hints: hints }
end function

' MARK: Live TV

' Every channel for the grid guide, in channel-number order (Apple
' guideChannels). Pages of 200, at most 1,000 channels.
function CmdGuideChannels(req as object) as object
    base = ServerBase()
    channels = []
    start = 0
    for page = 1 to 5
        r = Api("GET", ["LiveTv", "Channels"], {
            userId: ViewerId(), startIndex: start, limit: 200,
            sortBy: "ChannelNumber,SortName", sortOrder: "Ascending", enableFavoriteSorting: false,
            enableUserData: true, addCurrentProgram: req.withProgram = true, enableImages: true, imageTypeLimit: 1,
            enableTotalRecordCount: true
        })
        if not r.ok then
            if channels.count() > 0 then exit for
            return Fail(r)
        end if
        items = r.json.Items
        if not ZIsArray(items) then items = []
        for each c in items
            tag = invalid
            if ZIsMap(c.ImageTags) then tag = c.ImageTags.Primary
            program = ""
            if ZIsMap(c.CurrentProgram) and ZIsoToSeconds(c.CurrentProgram.EndDate) > ZNowSeconds() then program = ZStr(c.CurrentProgram.Name)
            channels.push({
                id: ZStr(c.Id), name: ZStr(c.Name), number: ZStr(c.ChannelNumber),
                favorite: ZBool(ZGet(c, "UserData", "IsFavorite")),
                logo: ZImageUrl(base, c.Id, "Primary", tag, 128), program: program
            })
        end for
        start = start + items.count()
        total = Int(ZNum(r.json.TotalRecordCount, 0))
        if items.count() < 200 or start >= total then exit for
    end for
    return { ok: true, channels: channels }
end function

' Listings for up to 40 channels across one guide window (Apple
' guidePrograms). Bounded paging; never tunes or reports playback.
function CmdGuidePrograms(req as object) as object
    ids = req.channelIds
    if not ZIsArray(ids) or ids.count() = 0 or ids.count() > 40 then return { ok: false, error: "invalid" }
    wanted = {}
    for each id in ids
        wanted[ZStr(id)] = true
    end for
    first = CreateObject("roDateTime")
    first.FromSeconds(Int(ZNum(req.start, 0)))
    last = CreateObject("roDateTime")
    last.FromSeconds(Int(ZNum(req.finish, 0)))
    programs = []
    seen = {}
    offset = 0
    for page = 1 to 20
        r = Api("GET", ["LiveTv", "Programs"], {
            userId: ViewerId(), channelIds: ZJoin(ids, ","), minEndDate: first.ToISOString(),
            maxStartDate: last.ToISOString(), startIndex: offset, limit: 200,
            sortBy: "StartDate,SortName", sortOrder: "Ascending", enableTotalRecordCount: true,
            enableImages: false, fields: "Overview,Genres"
        })
        if not r.ok then return Fail(r)
        items = r.json.Items
        if not ZIsArray(items) then items = []
        for each p in items
            key = ZStr(p.Id) + "|" + ZStr(p.ChannelId) + "|" + ZStr(p.StartDate)
            if not seen.doesExist(key) and wanted.doesExist(ZStr(p.ChannelId)) then
                seen[key] = true
                genres = []
                if ZIsArray(p.Genres) then genres = p.Genres
                programs.push({
                    id: ZStr(p.Id), name: ZStr(p.Name), channelId: ZStr(p.ChannelId),
                    start: ZIsoToSeconds(p.StartDate), finish: ZIsoToSeconds(p.EndDate),
                    episodeTitle: ZStr(p.EpisodeTitle), overview: ZStripTags(p.Overview),
                    genres: genres, isLive: ZBool(p.IsLive), isNew: ZBool(p.IsPremiere) or ZBool(p.IsNew)
                })
            end if
        end for
        offset = offset + items.count()
        total = Int(ZNum(r.json.TotalRecordCount, -1))
        if items.count() = 0 or (total >= 0 and offset >= total) or (total < 0 and items.count() < 200) then
            return { ok: true, channelIds: ids, start: req.start, programs: programs }
        end if
    end for
    ' Incomplete paging is reported rather than shown as fact.
    return { ok: false, error: "invalid", channelIds: ids, start: req.start }
end function

' MARK: Playback

function CmdPlayback(req as object) as object
    uid = ViewerId()
    id = ZStr(req.id)
    info = Api("GET", ["Items", id], { userId: uid, fields: "MediaSources,MediaStreams,Overview" })
    if not info.ok then return Fail(info)
    json = info.json
    kind = ZStr(json.Type)
    isLive = kind = "TvChannel"
    settings = req.settings
    if not ZIsMap(settings) then settings = {}
    device = ZDeviceProfile(Int(ZNum(settings.maxBitrate, 0)))

    body = {
        UserId: uid,
        DeviceProfile: device.profile,
        MaxStreamingBitrate: device.maxBitrate,
        StartTimeTicks: ZNum(req.startTicks, 0),
        EnableDirectPlay: req.forceTranscode <> true,
        EnableDirectStream: true,
        EnableTranscoding: true,
        AllowVideoStreamCopy: true,
        AllowAudioStreamCopy: true,
        AutoOpenLiveStream: isLive,
        IsPlayback: true
    }
    if ZStr(req.mediaSourceId) <> "" then body.MediaSourceId = req.mediaSourceId
    if req.audioIndex <> invalid and req.audioIndex >= 0 then body.AudioStreamIndex = req.audioIndex
    if req.subtitleIndex <> invalid then body.SubtitleStreamIndex = req.subtitleIndex

    r = Api("POST", ["Items", id, "PlaybackInfo"], { userId: uid }, body)
    if not r.ok then return Fail(r)
    sources = r.json.MediaSources
    if not ZIsArray(sources) or sources.count() = 0 then return { ok: false, error: "unplayable" }
    source = sources[0]
    if ZStr(r.json.ErrorCode) <> "" then return { ok: false, error: "unplayable", message: r.json.ErrorCode }
    token = ZStr(m.session.token)
    base = ServerBase()
    playSession = ZStr(r.json.PlaySessionId)

    url = ""
    format = ""
    method = ""
    container = LCase(ZStr(source.Container))
    if source.SupportsDirectPlay = true and req.forceTranscode <> true and not isLive and (container = "mp4" or container = "m4v" or container = "mov" or container = "mkv" or Instr(1, container, "mp4") > 0) then
        url = ZEndpoint(base, ["Videos", id, "stream"], { static: true, mediaSourceId: source.Id, PlaySessionId: playSession, ApiKey: token })
        format = "mp4"
        if container = "mkv" then format = "mkv"
        method = "DirectPlay"
    else if ZStr(source.TranscodingUrl) <> "" then
        url = ZMediaUrl(base, source.TranscodingUrl, token)
        format = "hls"
        method = "Transcode"
        if source.SupportsDirectStream = true then method = "DirectStream"
        if Instr(1, LCase(source.TranscodingUrl), "videocodec=copy") = 0 and Instr(1, LCase(url), "/master.m3u8") > 0 and source.SupportsDirectStream <> true then method = "Transcode"
    end if
    if url = "" then return { ok: false, error: "unplayable" }

    ' External text subtitles the Roku renders itself.
    subtitles = []
    audio = []
    streams = source.MediaStreams
    if ZIsArray(streams) then
        for each s in streams
            if ZIsMap(s) and s.Type = "Subtitle" then
                entry = { index: Int(ZNum(s.Index, -1)), title: ZStr(s.DisplayTitle, ZStr(s.Language, "Subtitles")), language: ZStr(s.Language, "und"), url: "", method: ZStr(s.DeliveryMethod), isDefault: ZBool(s.IsDefault), forced: ZBool(s.IsForced) }
                if entry.method = "External" and ZStr(s.DeliveryUrl) <> "" then entry.url = ZMediaUrl(base, s.DeliveryUrl, token)
                subtitles.push(entry)
            else if ZIsMap(s) and s.Type = "Audio" then
                audio.push({ index: Int(ZNum(s.Index, -1)), title: ZStr(s.DisplayTitle, ZStr(s.Language, "Audio")), language: ZStr(s.Language), isDefault: ZBool(s.IsDefault) })
            end if
        end for
    end if

    ' Intro and credits markers (Jellyfin media segments), when the server has them.
    segments = []
    if not isLive then
        seg = Api("GET", ["MediaSegments", id], { includeSegmentTypes: "Intro,Outro" })
        if seg.ok and ZIsMap(seg.json) and ZIsArray(seg.json.Items) then
            for each s in seg.json.Items
                segments.push({ type: ZStr(s.Type), start: ZTicksToSeconds(s.StartTicks), finish: ZTicksToSeconds(s.EndTicks) })
            end for
        end if
    end if

    title = ZStr(json.Name)
    secondary = ""
    if kind = "Episode" then
        secondary = ZJoin([ZStr(json.SeriesName), ZEpisodeLabel(json.ParentIndexNumber, json.IndexNumber)], " · ")
    else if kind = "TvChannel" and ZIsMap(json.CurrentProgram) then
        secondary = ZStr(json.CurrentProgram.Name)
    end if

    audioIndex = req.audioIndex
    if audioIndex = invalid or audioIndex < 0 then audioIndex = Int(ZNum(source.DefaultAudioStreamIndex, -1))
    subtitleIndex = req.subtitleIndex
    if subtitleIndex = invalid then subtitleIndex = Int(ZNum(source.DefaultSubtitleStreamIndex, -1))

    return {
        ok: true,
        id: id,
        type: kind,
        title: title,
        secondary: secondary,
        seriesId: ZStr(json.SeriesId),
        isLive: isLive,
        url: url,
        streamFormat: format,
        playMethod: method,
        playSessionId: playSession,
        mediaSourceId: ZStr(source.Id),
        liveStreamId: ZStr(source.LiveStreamId),
        runtime: ZTicksToSeconds(ZNum(source.RunTimeTicks, ZNum(json.RunTimeTicks, 0))),
        startSeconds: ZTicksToSeconds(req.startTicks),
        audioIndex: audioIndex,
        subtitleIndex: subtitleIndex,
        audioTracks: audio,
        subtitles: subtitles,
        segments: segments,
        backdrop: ZItemNode(json, base).backdropUrl,
        maxBitrate: device.maxBitrate,
        streamBitrate: StreamBitrate(source, method),
        seriesName: ZStr(json.SeriesName),
        seasonId: ZStr(json.SeasonId),
        sourceBadges: ZQuality(json, audioIndex).badges
    }
end function

' Bits per second the server sends: the file's own rate when it plays as
' is, otherwise the video and audio targets in the transcoding URL.
function StreamBitrate(source as object, method as string) as integer
    original = Int(ZNum(source.Bitrate, 0))
    if method = "DirectPlay" then return original
    query = LCase(ZStr(source.TranscodingUrl))
    total = 0
    for each name in ["videobitrate=", "audiobitrate="]
        at = Instr(1, query, name)
        if at > 0 then
            rest = Mid(query, at + Len(name))
            amp = Instr(1, rest, "&")
            if amp > 0 then rest = Left(rest, amp - 1)
            total = total + Int(Val(rest))
        end if
    end for
    if total <= 0 then return original
    if original > 0 and original < total then return original
    return total
end function

' Sessions/Playing, /Progress and /Stopped.
function CmdReport(req as object) as object
    body = {
        ItemId: req.id,
        MediaSourceId: req.mediaSourceId,
        PlaySessionId: req.playSessionId,
        PositionTicks: ZSecondsToTicks(req.position),
        IsPaused: req.paused = true,
        CanSeek: req.isLive <> true,
        PlayMethod: ZStr(req.playMethod, "DirectPlay"),
        EventName: ZStr(req.eventName, "timeupdate")
    }
    if ZStr(req.liveStreamId) <> "" then body.LiveStreamId = req.liveStreamId
    if req.audioIndex <> invalid and req.audioIndex >= 0 then body.AudioStreamIndex = req.audioIndex
    if req.subtitleIndex <> invalid then body.SubtitleStreamIndex = req.subtitleIndex
    path = ["Sessions", "Playing"]
    if req.event = "progress" then path = ["Sessions", "Playing", "Progress"]
    if req.event = "stop" then path = ["Sessions", "Playing", "Stopped"]
    r = Api("POST", path, invalid, body)
    return { ok: r.ok, event: req.event }
end function

function CmdNextEpisode(req as object) as object
    if ZStr(req.seriesId) = "" then return { ok: true, next: invalid }
    r = Api("GET", ["Shows", req.seriesId, "Episodes"], { userId: ViewerId(), startItemId: req.id, limit: 2, fields: "Overview", isMissing: false, enableImageTypes: "Primary,Thumb", imageTypeLimit: 1 })
    if not r.ok then return Fail(r)
    items = r.json.Items
    if ZIsArray(items) then
        for each e in items
            if ZStr(e.Id) <> ZStr(req.id) then
                return { ok: true, next: { id: e.Id, title: ZStr(e.Name), label: ZEpisodeLabel(e.ParentIndexNumber, e.IndexNumber), image: ZItemNode(e, ServerBase()).landscapeUrl } }
            end if
        end for
    end if
    return { ok: true, next: invalid }
end function

function CmdSetPlayed(req as object) as object
    method = "DELETE"
    if req.value = true then method = "POST"
    r = Api(method, ["UserPlayedItems", ZStr(req.id)], { userId: ViewerId() })
    return { ok: r.ok, id: req.id, value: req.value, error: r.error }
end function

function CmdSetFavorite(req as object) as object
    method = "DELETE"
    if req.value = true then method = "POST"
    r = Api(method, ["UserFavoriteItems", ZStr(req.id)], { userId: ViewerId() })
    return { ok: r.ok, id: req.id, value: req.value, error: r.error }
end function

' Deep links: find what a contentId is so the scene can open or play it.
function CmdResolve(req as object) as object
    r = Api("GET", ["Items", ZStr(req.id)], { userId: ViewerId() })
    if not r.ok then return Fail(r)
    return { ok: true, id: r.json.Id, type: ZStr(r.json.Type), position: ZNum(ZGet(r.json, "UserData", "PlaybackPositionTicks"), 0), mediaType: req.mediaType }
end function

' MARK: Live TV streams (companion liveTvStreams module, version 1)

function CmdLiveStreams(req as object) as object
    query = { deviceId: ZStr(m.session.deviceId) }
    if ZStr(req.channelId) <> "" then query.channelId = ZStr(req.channelId)
    r = Api("GET", ["Zorofin", "Companion", "liveTvStreams", "status"], query, invalid, true)
    if not r.ok then return Fail(r)
    status = ZLtsParse(r.json)
    if status = invalid then return { ok: false, error: "invalid" }
    return { ok: true, channelId: ZStr(req.channelId), status: status }
end function

' MARK: Support (Zorofin support module) and Quick Connect for other devices

function ValidTicket(id as dynamic) as boolean
    re = CreateObject("roRegex", "^T[a-z0-9]{6,20}$", "")
    return re.IsMatch(ZStr(id))
end function

' Replies from the server's support agent (Apple supportReplies).
function CmdSupportReplies(req as object) as object
    r = Api("GET", ["support", "notifications"], invalid, invalid, true)
    if not r.ok then return Fail(r)
    if not ZIsMap(r.json) or not ZIsArray(r.json.notifications) then return { ok: false, error: "invalid" }
    replies = []
    seen = {}
    for each n in r.json.notifications
        if not ZIsMap(n) or not ValidTicket(n.id) or seen[n.id] = true then return { ok: false, error: "invalid" }
        seen[n.id] = true
        replies.push({
            id: n.id, status: ZStr(n.status), issueType: ZStr(n.issueType),
            affectedMedia: ZStr(n.affectedMedia), message: ZStr(n.message), updatedAt: ZStr(n.updatedAt)
        })
    end for
    return { ok: true, replies: replies }
end function

' One POST only: a lost receipt must never create a duplicate ticket.
function CmdSubmitSupport(req as object) as object
    body = { issueType: ZStr(req.issueType).trim(), description: ZStr(req.description).trim(), affectedMedia: ZStr(req.affectedMedia).trim() }
    if body.issueType = "" or Len(body.issueType) > 64 or body.description = "" or Len(body.description) > 1500 or Len(body.affectedMedia) > 200 then
        return { ok: false, error: "invalidReport" }
    end if
    r = Api("POST", ["support", "ticket"], invalid, body, true)
    if r.status = 202 and ZIsMap(r.json) and ValidTicket(r.json.ticketId) then return { ok: true, ticketId: r.json.ticketId }
    if r.status = 401 or r.status = 403 or r.status = 400 or r.status = 404 or r.status = 413 or r.status = 429 then
        return { ok: false, error: "rejected" }
    end if
    return { ok: false, error: "unknown" }
end function

' Signs another device into this account (no userId override).
function CmdAuthorizeQuickConnect(req as object) as object
    code = ZStr(req.code).trim()
    re = CreateObject("roRegex", "^[0-9]{6}$", "")
    if not re.IsMatch(code) then return { ok: false, error: "code" }
    r = Api("POST", ["QuickConnect", "Authorize"], { code: code })
    if not r.ok then return Fail(r)
    return { ok: true, accepted: LCase(r.text.trim()) = "true" }
end function

' MARK: Account settings (Apple NativeSettings: Users/Me and Users/Configuration)

function ViewerSnapshot() as object
    r = Api("GET", ["Users", "Me"])
    if not r.ok then return Fail(r)
    u = r.json
    if not ZIsMap(u) or LCase(ZStr(u.Id)) <> LCase(ViewerId()) or not ZIsMap(u.Configuration) then return { ok: false, error: "invalid" }
    canEdit = true
    if ZIsMap(u.Policy) and u.Policy.EnableUserPreferenceAccess = false then canEdit = false
    return { ok: true, name: ZStr(u.Name), hasPassword: u.HasPassword <> false, canEdit: canEdit, configuration: u.Configuration }
end function

function CmdViewerSettings(req as object) as object
    snap = ViewerSnapshot()
    if not snap.ok then return snap
    c = snap.configuration
    return {
        ok: true, name: snap.name, canEdit: snap.canEdit, hasPassword: snap.hasPassword,
        values: {
            AudioLanguagePreference: ZStr(c.AudioLanguagePreference),
            PlayDefaultAudioTrack: c.PlayDefaultAudioTrack <> false,
            RememberAudioSelections: c.RememberAudioSelections <> false,
            EnableNextEpisodeAutoPlay: c.EnableNextEpisodeAutoPlay = true,
            SubtitleLanguagePreference: ZStr(c.SubtitleLanguagePreference),
            SubtitleMode: ZStr(c.SubtitleMode, "Default"),
            RememberSubtitleSelections: c.RememberSubtitleSelections <> false
        }
    }
end function

' Merges only the edited fields into a fresh snapshot, so settings changed
' elsewhere survive, then reads back to confirm (as the Apple app does).
function CmdSaveViewerSettings(req as object) as object
    changes = req.changes
    if not ZIsMap(changes) then return { ok: false, error: "invalid" }
    langRe = CreateObject("roRegex", "^[A-Za-z]{2,3}(-[A-Za-z]{2,4})?$", "")
    for each key in changes
        value = changes[key]
        if key = "PlayDefaultAudioTrack" or key = "RememberAudioSelections" or key = "RememberSubtitleSelections" or key = "EnableNextEpisodeAutoPlay" then
            if type(value) <> "roBoolean" and type(value) <> "Boolean" then return { ok: false, error: "invalid" }
        else if key = "AudioLanguagePreference" or key = "SubtitleLanguagePreference" then
            if Len(ZStr(value)) > 12 or (ZStr(value) <> "" and not langRe.isMatch(ZStr(value))) then return { ok: false, error: "invalid" }
        else if key = "SubtitleMode" then
            if not ZContains(["Default", "Always", "OnlyForced", "None", "Smart"], ZStr(value)) then return { ok: false, error: "invalid" }
        else
            return { ok: false, error: "invalid" }
        end if
    end for
    snap = ViewerSnapshot()
    if not snap.ok then return snap
    if not snap.canEdit then return { ok: false, error: "forbidden" }
    config = snap.configuration
    for each key in changes
        config[key] = changes[key]
    end for
    r = Api("POST", ["Users", "Configuration"], { userId: ViewerId() }, config)
    if not r.ok then return Fail(r)
    after = CmdViewerSettings({})
    if not after.ok then return { ok: false, error: "unconfirmed" }
    for each key in changes
        if after.values[key] <> changes[key] then return { ok: false, error: "unconfirmed" }
    end for
    return after
end function

function CmdLanguages(req as object) as object
    r = Api("GET", ["Localization", "Cultures"])
    if not r.ok then return Fail(r)
    out = []
    seen = {}
    if ZIsArray(r.json) then
        for each c in r.json
            code = ZStr(c.ThreeLetterISOLanguageName, ZStr(c.TwoLetterISOLanguageName))
            name = ZStr(c.DisplayName)
            if code <> "" and name <> "" and seen[code] = invalid then
                seen[code] = true
                out.push({ id: code, name: name })
            end if
        end for
    end if
    out.sortBy("name", "i")
    return { ok: true, languages: out }
end function

function CmdChangePassword(req as object) as object
    current = ZStr(req.current)
    newValue = ZStr(req.newPassword)
    if newValue = "" or Len(newValue) > 1024 or Len(current) > 1024 then return { ok: false, error: "invalid" }
    snap = ViewerSnapshot()
    if not snap.ok then return snap
    if not snap.canEdit then return { ok: false, error: "forbidden" }
    r = Api("POST", ["Users", "Password"], { userId: ViewerId() }, { CurrentPw: current, NewPw: newValue, ResetPassword: false })
    if not r.ok then return Fail(r)
    return { ok: true }
end function
