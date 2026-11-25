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
        playbackProblem: CmdPlaybackProblem,
        ping: CmdPing,
        nextEpisode: CmdNextEpisode,
        setPlayed: CmdSetPlayed,
        setFavorite: CmdSetFavorite,
        resolve: CmdResolve,
        liveStreams: CmdLiveStreams,
        liveNow: CmdLiveNow,
        looks: CmdLooks,
        extras: CmdExtras,
        calendar: CmdCalendar,
        catchUp: CmdCatchUp,
        catchUpAct: CmdCatchUpAct,
        pick: CmdPick,
        trailer: CmdTrailer,
        supportReplies: CmdSupportReplies,
        inbox: CmdInbox,
        requestBrowse: CmdRequestBrowse,
        requestChoice: CmdRequestChoice,
        notificationReadsWrite: CmdNotificationReadsWrite,
        submitSupport: CmdSubmitSupport,
        authorizeQuickConnect: CmdAuthorizeQuickConnect,
        viewerSettings: CmdViewerSettings,
        saveViewerSettings: CmdSaveViewerSettings,
        languages: CmdLanguages,
        changePassword: CmdChangePassword
    }
    if cmd = "requestBrowse" or cmd = "requestChoice" then
        if req.scope = "" or req.scope <> ZNotificationScope(m.session) or not ZContains([1, 2], req.version) or req.version <> m.global.features.requests then
            m.top.response = { ok: false, error: "stale" }
            return
        end if
    end if
    handler = handlers[cmd]
    if handler = invalid then
        m.top.response = { ok: false, error: "invalid", cmd: cmd }
        return
    end if
    if cmd = "inbox" or cmd = "notificationReadsWrite" then
        if ZStr(req.scope) = "" or ZStr(req.scope) <> ZNotificationScope(m.session) then
            m.top.response = { ok: false, scope: ZStr(req.scope), error: "stale" }
            return
        end if
    end if
    result = handler(req)
    if result = invalid then result = { ok: false, error: "invalid" }
    result.cmd = cmd
    if cmd = "inbox" or cmd = "notificationReadsWrite" then result.scope = ZNotificationScope(m.session)
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
function Api(method as string, path as object, query = invalid as dynamic, body = invalid as dynamic, extension = false as boolean, timeoutMs = 20000 as integer) as object
    url = ZEndpoint(ServerBase(), path, query)
    headers = AuthHeaders()
    if extension then headers["X-Jellyfin-Token"] = ZStr(m.session.token)
    return ZHttp(method, url, headers, body, timeoutMs)
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
    cachePath = HomeSnapshotPath()
    if req.cold = true then ReadHomeSnapshot(cachePath)
    uid = ViewerId()
    features = Capabilities()
    root = CreateObject("roSGNode", "ContentNode")
    base = ServerBase()

    ' Library views drive the tab bar and the "Recently added" rows.
    views = Api("GET", ["UserViews"], { userId: uid })
    if not views.ok then
        if cachePath <> "" and (views.status = 401 or views.status = 403) then DeleteFile(cachePath)
        return Fail(views)
    end if
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
                ' Wide cards for Continue Watching and live sports, as on the
                ' other apps: channel art is 16:9 and a game shows two crests.
                landscape = section.id = "continue-watching" or section.id = "sports"
                row = MakeRow(section.title, section.id, landscape)
                for each card in section.cards
                    node = ZItemNode(card.item, base)
                    if section.id = "sports" and card.game <> invalid then
                        ' Crests are public files on the viewer's own server: no token.
                        node.game = {
                            title: card.game.title, status: card.game.status,
                            crests: [ZEndpoint(base, card.game.crests[0].split("/")), ZEndpoint(base, card.game.crests[1].split("/"))]
                        }
                    end if
                    split = ZSplitBadges(card.badges)
                    if split.quality.count() > 0 then node.badges = split.quality
                    node.contextBadges = split.context
                    ' One line under the title, as on Apple: a short movie's
                    ' length or a live card's program, else the row's badge.
                    label = ""
                    if section.id = "short-movies" or section.id = "sports" then
                        label = card.subtitle
                    else if split.context.count() > 0 then
                        label = split.context[0]
                    end if
                    if label <> "" then node.caption = label
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
    SaveProfileSpotlight(root)
    WriteHomeSnapshot(cachePath, root)
    m.top.content = root
    nav = []
    for each v in viewList
        nav.push({ id: v.Id, name: ZStr(v.Name), collectionType: ZStr(v.CollectionType) })
    end for
    return { ok: true, views: nav, features: features, hasBanner: banner <> invalid, serverFeed: usedServerFeed }
end function

'' Remembers what this profile was watching, for the Who's watching backdrop.
' Roku never fetches other profiles' history; each refreshes on its own Home.
sub SaveProfileSpotlight(root as object)
    s = m.session
    if s = invalid or ZStr(s.userId) = "" then return
    key = "spotlight:" + LCase(ZStr(s.serverId) + ":" + ZStr(s.userId))
    cards = []
    for i = 0 to root.getChildCount() - 1
        row = root.getChild(i)
        if row <> invalid and row.id = "continue-watching" then
            for j = 0 to row.getChildCount() - 1
                if j >= 6 then exit for
                cards.push(row.getChild(j).getFields())
            end for
            exit for
        end if
    end for
    spot = ZProfileSpotlight(cards)
    sec = CreateObject("roRegistrySection", "zorofin")
    if spot = invalid then
        sec.Delete(key)
    else
        sec.Write(key, FormatJson(spot))
    end if
    sec.Flush()
end sub

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
    info = Api("GET", ["Items", id], { userId: uid, fields: "MediaSources,MediaStreams,Overview,Chapters" })
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
        chapters: ZChapters(json),
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

' One playback problem for the server owner (Zorofin plugin). 404 means the
' owner turned collection off and 429 that this viewer sent enough: both
' tell the app to stay quiet for the rest of the run.
function CmdPlaybackProblem(req as object) as object
    r = Api("POST", ["Zorofin", "PlaybackReports"], invalid, req.body, true, 8000)
    return { ok: r.ok, refused: r.status = 404 or r.status = 429 }
end function

' Whether the server answers at all. The player asks after a stream breaks,
' to tell a dropped connection from a stream that cannot play.
function CmdPing(req as object) as object
    r = Api("GET", ["System", "Info", "Public"], invalid, invalid, false, 4000)
    return { ok: true, reachable: r.status > 0 }
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
    action = ZDeepLinkAction(req.mediaType)
    id = ZDeepLinkId(req.id)
    if action = "invalid" or id = "" then return { ok: false, error: "invalid" }
    r = Api("GET", ["Items", id], { userId: ViewerId() })
    if not r.ok then return Fail(r)
    item = r.json
    kind = ZStr(item.Type)
    ' Series and season links play the smart bookmark (Roku certification);
    ' with no episodes to play they open the show's details.
    if kind = "Series" or kind = "Season" then
        episode = BookmarkEpisode(item)
        if episode <> invalid then item = episode
    end if
    ' Folders and other items a link can't open count as invalid links
    ' (Jellyfin answers the all-zero id with the user's root folder).
    if ZDeepLinkTarget(item.Type) = "" then return { ok: false, error: "invalid" }
    return { ok: true, id: ZStr(item.Id), type: ZStr(item.Type), position: ZNum(ZGet(item, "UserData", "PlaybackPositionTicks"), 0), mediaType: ZStr(req.mediaType) }
end function

function BookmarkEpisode(item as object) as dynamic
    seriesId = ZStr(item.Id)
    query = { userId: ViewerId(), fields: "UserData", enableUserData: true }
    if item.Type = "Season" then
        seriesId = ZStr(item.SeriesId)
        query.seasonId = ZStr(item.Id)
    else
        ' Next up already accounts for watched and in-progress episodes.
        n = Api("GET", ["Shows", "NextUp"], { userId: ViewerId(), seriesId: seriesId, limit: 1, enableResumable: true, enableRewatching: false, fields: "UserData" })
        if n.ok and ZIsArray(n.json.Items) and n.json.Items.count() > 0 then return n.json.Items[0]
    end if
    if seriesId = "" then return invalid
    r = Api("GET", ["Shows", seriesId, "Episodes"], query)
    if not r.ok then return invalid
    return ZBookmarkEpisode(r.json.Items)
end function

' MARK: Calendar and Catch Up (plugin extras)

function CmdExtras(req as object) as object
    r = Api("GET", ["Zorofin", "Extras"], invalid, invalid, true, 8000)
    if not r.ok then return { ok: true, extras: ZParseExtras(invalid) }
    return { ok: true, extras: ZParseExtras(r.json) }
end function

' Four weeks from today as shelves, one per local day (including empty dates). Titles already on the
' server open their details; the rest are announcements only.
function CmdCalendar(req as object) as object
    offset = ZGuideLocalOffset()
    now = ZNowSeconds()
    r = Api("GET", ["Zorofin", "Arr", "Calendar"], { start: ZCalendarKey(now, offset), days: 28 }, invalid, true)
    if not r.ok then return Fail(r)
    items = invalid
    if ZIsMap(r.json) then items = r.json.items
    filter = ZStr(req.filter, "all")
    root = CreateObject("roSGNode", "ContentNode")
    eventCount = 0
    for each group in ZCalendarGroups(items, now, offset, filter, 28)
        row = MakeRow(group.label, "day-" + group.day, false)
        for each e in group.events
            node = CreateObject("roSGNode", "ZItem")
            node.id = ZStr(e.itemId)
            node.itemType = "Movie"
            if e.kind = "episode" then node.itemType = "Series"
            node.title = ZStr(e.title)
            node.caption = ZCalendarCaption(e, offset)
            poster = ZStr(e.posterUrl)
            if Left(LCase(poster), 8) <> "https://" then poster = ""
            node.HDPosterUrl = poster
            node.FHDPosterUrl = poster
            badges = []
            badge = ZCalendarBadge(e)
            if badge <> "" then badges.push(badge)
            if e.hasFile = true then badges.push("On the server")
            node.badges = badges
            row.appendChild(node)
        end for
        eventCount = eventCount + group.events.count()
        root.appendChild(row)
    end for
    m.top.content = root
    return { ok: true, days: root.getChildCount(), events: eventCount }
end function

' Sixty random unplayed titles with a plot, minus liked and skipped ones.
function CmdCatchUp(req as object) as object
    kinds = ZStr(req.kinds, "Movie,Series")
    r = Api("GET", ["Items"], {
        userId: ViewerId(), includeItemTypes: kinds, recursive: true, sortBy: "Random",
        limit: 60, hasOverview: true, imageTypeLimit: 1, enableImageTypes: "Backdrop,Logo,Primary",
        excludeLocationTypes: "Virtual", enableUserData: true,
        fields: "Overview,ProductionYear,OfficialRating,CommunityRating,RunTimeTicks,ChildCount,Genres"
    })
    if not r.ok then return Fail(r)
    skips = []
    if ZIsArray(req.skips) then skips = req.skips
    base = ServerBase()
    root = CreateObject("roSGNode", "ContentNode")
    taste = Api("GET", ["Zorofin", "Companion", "recommendations", "taste"], invalid, invalid, true)
    liked = {}
    if taste.ok then
        liked = ZTasteSet(taste.json)
        if liked = invalid then return { ok: false, error: "invalid" }
    else if taste.status <> 403 and taste.status <> 404 then
        return Fail(taste)
    end if
    for each json in ZCatchUpQueue(r.json.Items, skips, liked)
        node = ZItemNode(json, base)
        ' The metadata line already shows the year; the caption is seasons only.
        node.caption = ""
        if json.Type = "Series" then
            seasons = Int(ZNum(json.ChildCount, 0))
            if seasons = 1 then node.caption = "1 season" else if seasons > 1 then node.caption = seasons.toStr() + " seasons"
        end if
        root.appendChild(node)
    end for
    m.top.content = root
    return { ok: true, count: root.getChildCount(), canLike: taste.ok }
end function

function CmdCatchUpAct(req as object) as object
    id = ZStr(req.id)
    action = ZStr(req.action)
    if action = "like" then
        r = Api("POST", ["Zorofin", "Companion", "recommendations", "taste"], invalid, { itemId: id, action: action }, true)
        if not r.ok then return Fail(r)
        liked = ZTasteSet(r.json)
        if liked = invalid then return { ok: false, error: "invalid" }
        return { ok: liked.doesExist(LCase(id.replace("-", ""))), action: action }
    end if
    if action <> "skip" then return { ok: false, error: "invalid" }
    Api("POST", ["Zorofin", "Extras", "CatchUp", "Log"], invalid, { itemId: id, action: action }, true, 6000)
    return { ok: true, id: id, action: action }
end function

' MARK: Pick Together (TV host)

' One call for the TV host: create (display: true), state (since version),
' host actions (start, next-round, end). Returns the parsed session, or
' { unchanged: true }, or a short error with ended: true when the group is gone.
' A refused companion call is never a signed-out session.
function CmdPick(req as object) as object
    action = ZStr(req.action)
    root = ["Zorofin", "Companion", "pickTogether"]
    id = ZStr(req.id)
    seat = ZStr(req.seat)
    if action = "create" then
        kind = ZStr(req.kind)
        if kind <> "movie" and kind <> "series" then return { ok: false, error: "invalid" }
        r = Api("POST", root.concat(["sessions"]), invalid, { kind: kind, display: true }, true, 15000)
    else
        if Len(id) <> 32 then return { ok: true, failed: ZPickError(404) }
        query = {}
        if seat <> "" then query.seat = seat
        if action = "state" then
            if req.since <> invalid then query.since = ZStr(req.since)
            r = Api("GET", root.concat(["sessions", id]), query, invalid, true, 15000)
        else if ZContains(["start", "next-round", "end"], action) then
            body = {}
            if seat <> "" then body.seat = seat
            r = Api("POST", root.concat(["sessions", id, action]), invalid, body, true, 15000)
        else
            return { ok: false, error: "invalid" }
        end if
    end if
    if not r.ok then return { ok: true, failed: ZPickError(r.status) }
    if ZIsMap(r.json) and ZBool(r.json.unchanged) then return { ok: true, unchanged: true }
    session = ZPickSession(r.json)
    if session = invalid then return { ok: true, failed: { text: "The server sent something unexpected. Try again.", ended: false } }
    return { ok: true, session: session }
end function

' Home trailer previews: the first direct-play local trailer of a movie or
' show, or no url. Never reported as playback.
function CmdTrailer(req as object) as object
    id = ZStr(req.id)
    if id = "" then return { ok: true, url: "" }
    r = Api("GET", ["Items", id, "LocalTrailers"], { userId: ViewerId() }, invalid, false, 8000)
    if not r.ok or not ZIsArray(r.json) or r.json.count() = 0 then return { ok: true, id: id, url: "" }
    trailer = r.json[0]
    sources = trailer.MediaSources
    if not ZIsArray(sources) or sources.count() = 0 then
        full = Api("GET", ["Items", ZStr(trailer.Id)], { userId: ViewerId(), fields: "MediaSources" }, invalid, false, 8000)
        if not full.ok or not ZIsMap(full.json) then return { ok: true, id: id, url: "" }
        trailer = full.json
        sources = trailer.MediaSources
    end if
    if not ZIsArray(sources) or sources.count() = 0 then return { ok: true, id: id, url: "" }
    source = sources[0]
    if not ZTrailerCompatible(source) then return { ok: true, id: id, url: "" }
    sourceId = ZStr(source.Id, ZStr(trailer.Id))
    url = ZEndpoint(ServerBase(), ["Videos", ZStr(trailer.Id), "stream.mp4"], { static: "true", mediaSourceId: sourceId, api_key: ZStr(m.session.token) })
    caption = invalid
    for each stream in source.MediaStreams
        if stream.Type = "Subtitle" and ZContains(["srt", "subrip", "vtt", "webvtt"], LCase(ZStr(stream.Codec))) and ZNum(stream.Index, -1) >= 0 then
            path = ["Videos", ZStr(trailer.Id), sourceId, "Subtitles", stream.Index.toStr(), "0", "Stream.vtt"]
            caption = { TrackName: ZEndpoint(ServerBase(), path, { api_key: ZStr(m.session.token) }), Language: ZStr(stream.Language, "und"), Description: "Trailer captions" }
            exit for
        end if
    end for
    return { ok: true, id: id, url: url, caption: caption }
end function

' MARK: Server looks

' The companion's published web look (public file, no viewer data).
' A 404 means an older companion: the app keeps its own look.
function CmdLooks(req as object) as object
    base = ServerBase()
    if base = "" then return { ok: false, error: "invalid" }
    r = ZHttp("GET", ZLooksUrl(base), {}, invalid, 6000)
    if r.status = 404 then return { ok: true, looks: { accent: "", cardScale: 0.0 }, server: base }
    if not r.ok then return Fail(r)
    looks = ZParseLooks(r.json)
    if looks = invalid then looks = { accent: "", cardScale: 0.0 }
    return { ok: true, looks: looks, server: base }
end function

' MARK: Live now (playable guide events + companion settings)

function CmdLiveNow(req as object) as object
    base = ServerBase()
    feed = invalid
    scoresStatus = 0
    if req.sports = true and req.scores <> false then
        s = Api("GET", ["Zorofin", "Companion", "sportsEvents", "live"], { window: "today" }, invalid, true, 4000)
        scoresStatus = s.status
        if s.ok then
            feed = ZLiveParseFeed(s.json)
            if feed = invalid and req.programs <> true then return { ok: false, error: "invalid" }
        else if s.status = 401 or (req.programs <> true and s.status <> 404 and s.status <> 403) then
            return Fail(s)
        end if
    end if
    channels = []
    start = 0
    for page = 1 to 20
        r = Api("GET", ["LiveTv", "Channels"], {
            userId: ViewerId(), startIndex: start, limit: 200, addCurrentProgram: true,
            fields: "Overview,Genres", enableUserData: true, enableImages: true, imageTypeLimit: 1,
            enableImageTypes: "Primary,Thumb,Backdrop", enableTotalRecordCount: true
        })
        if not r.ok then return Fail(r)
        items = r.json.Items
        if not ZIsArray(items) then items = []
        channels.append(items)
        start = start + items.count()
        total = Int(ZNum(r.json.TotalRecordCount, 0))
        if items.count() < 200 or (total > 0 and start >= total) then exit for
    end for
    now = ZNowSeconds()
    events = ZLiveSelect(channels, now, feed = invalid)
    if feed <> invalid then events = ZLiveArrange(events, feed)
    ' Artwork is optional decoration after game selection. A missing events.json
    ' never removes a card. A matched fixture can supply its own photo or crests.
    art = invalid
    if events.count() > 0 then
        if ZIsMap(req.art) then
            art = req.art
        else
            a = ZHttp("GET", ZLiveArtUrl(base, "/live-tv-logos/art/events.json?v=" + Int(now / 300).toStr()), {}, invalid, 4000)
            art = { version: 0 }
            if a.ok and ZIsMap(a.json) and a.json.version = 2 and ZIsArray(a.json.events) then art = { version: 2, events: a.json.events }
        end if
        ZLiveApplyArtwork(events, art, false)
    end if
    byId = {}
    for each c in channels
        if ZIsMap(c) then byId[ZStr(c.Id)] = c
    end for
    repeatedArt = ZLiveRepeatedProgramArt(events, byId)
    row = MakeRow("Sports & live events", "live-now", true)
    for each e in events
        if feed = invalid and row.getChildCount() >= 20 then exit for
        c = byId[e.id]
        node = ZItemNode(c, base)
        node.itemType = "TvChannel"
        picture = ""
        logos = invalid
        if e.artwork <> invalid and e.artwork.image <> "" then
            picture = ZLiveArtUrl(base, e.artwork.image)
        else if e.artwork <> invalid and e.artwork.logos.count() = 2 then
            logos = [ZLiveArtUrl(base, e.artwork.logos[0]), ZLiveArtUrl(base, e.artwork.logos[1])]
        else
            image = ZLiveProgramImage(c, repeatedArt)
            if image <> invalid then picture = ZImageUrl(base, image.item, image.kind, image.tag, 480)
        end if
        node.landscapeUrl = picture
        node.HDPosterUrl = picture
        logoTag = ZGet(c, "ImageTags", "Primary")
        node.logoUrl = ZImageUrl(base, e.id, "Primary", logoTag, 240)
        node.live = {
            name: e.name, competition: e.competition, kind: e.kind, channel: e.channel, number: e.number,
            start: e.start, finish: e.finish, favoriteTeam: e.favoriteTeam, score: e.score, logos: logos
        }
        row.appendChild(node)
    end for
    if req.programs = true then
        programs = MakeRow("On now", "on-now", true)
        for each c in channels
            if programs.getChildCount() >= 100 then exit for
            p = c.CurrentProgram
            if not ZIsMap(p) then continue for
            start = ZIsoToSeconds(p.StartDate)
            finish = ZIsoToSeconds(p.EndDate)
            if start <= 0 or start > now or finish <= now then continue for
            id = ZStr(c.Id)
            if id = "" then continue for
            node = ZItemNode(c, base)
            node.itemType = "TvChannel"
            image = ZLiveProgramImage(c)
            picture = ""
            if image <> invalid then picture = ZImageUrl(base, image.item, image.kind, image.tag, 480)
            node.landscapeUrl = picture
            node.HDPosterUrl = picture
            node.logoUrl = ZImageUrl(base, id, "Primary", ZGet(c, "ImageTags", "Primary"), 240)
            node.live = { name: ZStr(p.Name, ZStr(c.Name)), channel: ZStr(c.Name), number: ZStr(c.ChannelNumber), start: start, finish: finish, onNow: true, isLive: p.IsLive = true }
            programs.appendChild(node)
        end for
        browse = CreateObject("roSGNode", "ContentNode")
        browse.appendChild(row)
        browse.appendChild(programs)
        m.top.content = browse
    else
        m.top.content = row
    end if
    source = "guide"
    if feed <> invalid then source = "companion"
    return { ok: true, count: row.getChildCount(), scoresStatus: scoresStatus, art: art, source: source }
end function

' MARK: Live TV streams (companion liveTvStreams module, version 1)

function CmdLiveStreams(req as object) as object
    query = { deviceId: ZStr(m.session.deviceId) }
    if ZStr(req.channelId) <> "" then query.channelId = ZStr(req.channelId)
    route = ZLtsRoute(m.global.features)
    if route = "companion" then
        r = Api("GET", ["Zorofin", "Companion", "liveTvStreams", "status"], query, invalid, true)
        if not r.ok then return Fail(r)
        status = ZLtsParse(r.json)
    else if route = "legacy" then
        r = Api("GET", ["support", "live-tv", "status"], query, invalid, true)
        if not r.ok then return Fail(r)
        status = ZLtsParseLegacy(r.json, ZStr(req.channelId))
    else
        return { ok: false, error: "unsupported" }
    end if
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

' Read-only inbox refresh. Each result is tied to the session captured by this
' task; the UI must reject a response after an account/server switch.
function CmdInbox(req as object) as object
    features = req.features
    if not ZIsMap(features) then features = {}
    reads = invalid
    if ZNum(features.notificationReads, 0) = 1 then
        state = Api("GET", ["Zorofin", "Notifications", "Read"], invalid, invalid, true, 5000)
        if state.ok then reads = ZParseNotificationReads(state.json)
    end if
    replies = []
    repliesOk = true
    if ZNum(features.notifications, 0) = 1 then
        result = CmdSupportReplies({})
        repliesOk = result.ok = true
        if repliesOk then replies = result.replies
    end if
    notices = []
    version = Int(ZNum(features.requests, 0))
    requestsEnabled = ZNum(features.notificationReads, 0) = 1 and ZContains([1, 2], version)
    requestsOk = not requestsEnabled
    requestsComplete = false
    if requestsEnabled then
        result = InboxReadyRequests(version)
        requestsOk = result.ok = true
        requestsComplete = requestsOk
        if requestsOk then notices = result.notices
    end if
    return { ok: (ZNum(features.notifications, 0) = 1 and repliesOk) or requestsComplete, repliesOk: repliesOk, replies: replies, requestsOk: requestsOk, requestsComplete: requestsComplete, notices: notices, reads: reads }
end function

function InboxReadyRequests(version as integer) as object
    activityPath = ["Zorofin", "Requests", "activity"]
    titleBase = ["Zorofin", "Requests"]
    if version = 1 then
        activityPath = ["JellyfinEnhanced", "arr", "requests"]
        titleBase = ["JellyfinEnhanced", "jellyseerr"]
    end if
    candidates = []
    seen = {}
    for page = 0 to 1
        r = Api("GET", activityPath, { userOnly: true, take: 50, skip: page * 50, filter: "all" }, invalid, true, 5000)
        if not r.ok then return Fail(r)
        if not ZIsMap(r.json) or not ZIsArray(r.json.requests) then return { ok: false }
        if r.json.requests.count() > 50 or ZNum(r.json.totalPages, 1) > 10000 then return { ok: false }
        for each item in r.json.requests
            if ZIsMap(item) and ZNotificationRequestId(item.id) and ZContains([2, 5], Int(ZNum(item.requestStatus, 0))) then
                if ZContains(["movie", "tv"], ZStr(item.type)) and ZNum(item.tmdbId, 0) > 0 and seen[item.id.toStr()] <> true then
                    seen[item.id.toStr()] = true
                    candidates.push(item)
                end if
            end if
        end for
        if page + 1 >= ZNum(r.json.totalPages, 1) then exit for
    end for
    notices = []
    details = {}
    for each item in candidates
        key = item.type + ":" + ZStr(item.tmdbId)
        detail = details[key]
        if detail = invalid then
            path = []
            path.append(titleBase)
            path.append([item.type, ZStr(item.tmdbId)])
            r = Api("GET", path, invalid, invalid, true, 5000)
            if not r.ok then return Fail(r)
            if not ZIsMap(r.json) then return { ok: false }
            detail = r.json
            details[key] = detail
        end if
        notice = ZReadyRequest(item, detail)
        if notice <> invalid then notices.push(notice)
    end for
    return { ok: true, notices: notices }
end function

function CmdNotificationReadsWrite(req as object) as object
    if ZNum(req.version, 0) <> 1 then return { ok: false, error: "unsupported" }
    if not ZIsArray(req.requests) or not ZIsArray(req.replies) then return { ok: false, error: "invalid" }
    reads = invalid
    for each body in ZNotificationBatches(req.requests, req.replies, req.initialize = true)
        r = Api("POST", ["Zorofin", "Notifications", "Read"], invalid, body, true, 5000)
        if not r.ok then return Fail(r)
        reads = ZParseNotificationReads(r.json)
        if reads = invalid then return { ok: false, error: "invalid" }
    end for
    return { ok: true, reads: reads }
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
