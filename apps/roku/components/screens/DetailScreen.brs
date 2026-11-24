' Title details, following the Apple TV DetailView (apps/apple/App/DetailView.swift).
' The overview section holds artwork and the heading column; the sections
' under it (genres, seasons and episodes, cast, more like this) scroll as one
' page with Page.brs. Selecting an episode opens its details, like Apple TV;
' the Play key on a card starts it directly.

sub init()
    m.page = m.top.findNode("page")
    m.page.id = "page"
    m.overview = m.top.findNode("overview")
    m.column = m.top.findNode("column")
    m.art = m.top.findNode("art")
    m.actions = m.top.findNode("actions")
    m.status = m.top.findNode("status")
    m.status.font = ZFont(28)
    m.top.findNode("kind").font = ZFont(16, "semibold")
    m.top.findNode("title").font = ZFont(46, "bold")
    m.top.findNode("episodeLabel").font = ZFont(26)
    m.top.findNode("ratingText").font = ZFont(22)
    m.top.findNode("nextLabel").font = ZFont(18)
    m.top.findNode("tagline").font = ZFont(26, "semibold")
    m.top.findNode("synopsis").font = ZFont(24)
    m.top.findNode("liveText").font = ZFont(22)
    m.actions.spacing = 16
    m.actions.observeField("selected", "onAction")
    ZPageInit(m.page, 140)
    m.item = invalid
    m.detail = invalid
    m.autoplayed = false
    m.audioIndex = invalid
    m.subtitleIndex = invalid
    m.episodesShelf = invalid
    m.seasonBar = invalid
    m.liveStatus = invalid
    m.liveJoin = invalid
    m.streamsTimer = m.top.findNode("streamsTimer")
    m.streamsTimer.observeField("fire", "loadStreams")
    m.top.observeField("visible", "watchStreams")
end sub

sub load()
    m.status.text = "Loading…"
    m.page.visible = false
    requestItem()
end sub

sub requestItem()
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "item", id: m.top.itemId }
    task.observeField("response", "onItem")
    task.control = "RUN"
    m.task = task
end sub

sub onResumed()
    ' Progress and Next Up change after playback; refresh quietly.
    if m.top.itemId <> "" then requestItem()
end sub

sub onItem(event as object)
    r = event.getData()
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        if m.item = invalid then m.status.text = ZErrorText(r.error)
        return
    end if
    m.status.text = ""
    m.page.visible = true
    content = m.task.content
    m.item = content.getChild(0)
    m.detail = r
    m.rows = {}
    for i = 1 to content.getChildCount() - 1
        row = content.getChild(i)
        m.rows[row.id] = row
    end for
    hadFocus = m.top.isInFocusChain()
    keep = focusKey()
    render()
    if hadFocus then restoreFocus(keep)
    watchStreams()
    if m.top.autoplay and not m.autoplayed then
        m.autoplayed = true
        doAction("play")
    end if
end sub

' MARK: Layout

sub render()
    renderOverview()
    sections = [{ id: "overview", node: m.overview, focus: m.actions, height: m.overviewHeight }]

    genres = m.detail.genres
    if ZIsArray(genres) and genres.count() > 0 then
        panel = genresPanel(genres)
        sections.push({ id: "genres", node: panel, focus: invalid, height: 64 })
    end if

    m.seasonBar = invalid
    m.episodesShelf = invalid
    seasons = m.rows.seasons
    if seasons <> invalid and ZStr(m.detail.seriesId) <> "" then
        heading = seasonHeading(seasons)
        sections.push({ id: "seasons", node: heading, focus: m.seasonBar, height: m.seasonHeadingHeight })
        shelf = CreateObject("roSGNode", "Shelf")
        shelf.landscape = true
        shelf.cardWidth = 380
        shelf.observeField("itemSelected", "onEpisodeSelected")
        m.episodesShelf = shelf
        ' Filled by loadEpisodes; an empty shelf takes no room until then.
        sections.push({ id: "episodes", node: shelf, focus: invalid, height: 0 })
    end if

    people = m.rows.people
    if people <> invalid and people.getChildCount() > 0 then
        shelf = CreateObject("roSGNode", "Shelf")
        shelf.title = "Cast & Crew"
        shelf.cardWidth = 180
        shelf.content = people
        sections.push({ id: "people", node: shelf, focus: shelf, height: shelf.height })
    end if

    similar = m.rows.similar
    if similar <> invalid and similar.getChildCount() > 0 then
        shelf = CreateObject("roSGNode", "Shelf")
        shelf.title = "More Like This"
        shelf.landscape = true
        shelf.content = similar
        shelf.observeField("itemSelected", "onCardSelected")
        sections.push({ id: "similar", node: shelf, focus: shelf, height: shelf.height })
    end if

    ' Rebuild the page: the overview stays, everything else is replaced.
    for i = m.page.getChildCount() - 1 to 0 step -1
        child = m.page.getChild(i)
        if not child.isSameNode(m.overview) then m.page.removeChild(child)
    end for
    for each s in sections
        if not s.node.isSameNode(m.overview) then m.page.appendChild(s.node)
    end for
    ZPageSet(sections, 28)
    if m.episodesShelf <> invalid and ZStr(m.detail.seasonId) <> "" then loadEpisodes(m.detail.seasonId)
end sub

sub renderOverview()
    it = m.item
    d = m.detail
    landscape = it.itemType = "Episode" or it.itemType = "TvChannel"
    artW = 300
    artH = 450
    uri = it.HDPosterUrl
    if landscape then
        artW = 460
        artH = 259
        if it.landscapeUrl <> "" then uri = it.landscapeUrl
    end if
    m.art.width = artW
    m.art.height = artH
    m.art.loadWidth = artW
    m.art.loadHeight = artH
    m.art.translation = [96, 8]
    m.art.uri = uri
    corners = m.top.findNode("artCorners")
    corners.width = artW
    corners.height = artH
    corners.translation = [96, 8]

    x = 96 + artW + 48
    colW = 1920 - 96 - x
    m.column.translation = [x, 0]
    y = 0

    ' Heading (Apple spacing 18).
    kind = m.top.findNode("kind")
    kind.text = UCase(ZKindName(it.itemType))
    kind.translation = [24, 0]
    m.top.findNode("kindDot").translation = [0, 5]
    y = 24 + 18

    title = m.top.findNode("title")
    title.width = colW
    title.text = it.title
    title.translation = [0, y]
    y = y + LabelHeight(title, 56) + 18

    episodeLabel = m.top.findNode("episodeLabel")
    episodeLabel.visible = it.itemType = "Episode"
    if episodeLabel.visible then
        episodeLabel.text = ZEpisodeLabel(it.seasonIndex, it.episodeIndex)
        episodeLabel.translation = [0, y]
        y = y + 32 + 18
    end if

    meta = m.top.findNode("meta")
    ZMetadataLine(meta, it, 22)
    meta.translation = [0, y]
    if meta.getChildCount() > 0 then y = y + 32 + 18

    rating = m.top.findNode("rating")
    rating.visible = it.communityRating > 0
    if rating.visible then
        m.top.findNode("ratingText").text = ZOneDecimalText(it.communityRating)
        rating.translation = [0, y]
        y = y + 30 + 18
    end if
    y = y - 18 + 24

    ' Quality (the file Play would start) and, for shows, which episode.
    nextLabel = m.top.findNode("nextLabel")
    nextLabel.visible = ZStr(d.nextLabel) <> "" and d.badges.count() > 0
    if nextLabel.visible then
        nextLabel.text = d.nextLabel
        nextLabel.translation = [0, y]
        y = y + 26 + 8
    end if
    badges = m.top.findNode("badges")
    h = BadgeChips(badges, d.badges, colW)
    badges.translation = [0, y]
    if h > 0 then
        y = y + h + 24
    else if nextLabel.visible then
        y = y - 8 + 24
    end if

    buildActions()
    m.actions.translation = [0, y]
    y = y + 60 + 24

    live = m.top.findNode("liveLine")
    live.translation = [0, y]
    if live.visible then y = y + 36 + 24

    tagline = m.top.findNode("tagline")
    tagline.width = ZMin(colW, 1100)
    tagline.text = ZStr(d.tagline)
    tagline.visible = tagline.text <> ""
    if tagline.visible then
        tagline.translation = [0, y]
        y = y + LabelHeight(tagline, 34) + 24
    end if
    synopsis = m.top.findNode("synopsis")
    synopsis.width = ZMin(colW, 1100)
    synopsis.text = ZStripTags(it.description)
    synopsis.visible = synopsis.text <> ""
    if synopsis.visible then
        synopsis.translation = [0, y]
        y = y + LabelHeight(synopsis, 34) + 24
    end if
    y = y - 24
    m.overviewHeight = ZMax(y, artH + 8)
end sub

' Measured height of a wrapping label (estimated when the Roku can't say).
function LabelHeight(label as object, lineHeight as integer) as integer
    r = label.localBoundingRect()
    if r <> invalid and r.height > 0 then return Int(r.height)
    lines = Int(ZTextWidth(label.text, label.font) / label.width) + 1
    if label.maxLines > 0 and lines > label.maxLines then lines = label.maxLines
    return lines * lineHeight
end function

' Apple's quality chips: 18 pt semibold, panel fill, 1 px border, 5 px
' corners, wrapping onto a second line when needed. Returns the height.
function BadgeChips(group as object, values as object, maxWidth as integer) as integer
    group.removeChildrenIndex(group.getChildCount(), 0)
    if values = invalid or values.count() = 0 then return 0
    font = ZFont(18, "semibold")
    theme = ZTheme()
    x = 0
    y = 0
    h = 32
    for each text in values
        w = ZTextWidth(text, font) + 16
        if x > 0 and x + w > maxWidth then
            x = 0
            y = y + h + 7
        end if
        border = ZPoster("pkg:/images/badge.9.png", w, h, x, y)
        border.blendColor = theme.border
        fill = ZPoster("pkg:/images/badge.9.png", w - 2, h - 2, x + 1, y + 1)
        fill.blendColor = theme.panel
        label = CreateObject("roSGNode", "Label")
        label.font = font
        label.text = text
        label.color = theme.text
        label.width = w
        label.height = h
        label.horizAlign = "center"
        label.vertAlign = "center"
        label.translation = [x, y]
        group.appendChild(border)
        group.appendChild(fill)
        group.appendChild(label)
        x = x + w + 7
    end for
    return y + h
end function

function genresPanel(genres as object) as object
    theme = ZTheme()
    group = CreateObject("roSGNode", "Group")
    group.translation = [96, 0]
    bg = ZPoster("pkg:/images/panel20.9.png", 1728, 64)
    bg.blendColor = theme.panel
    group.appendChild(bg)
    font = ZFont(22)
    label = CreateObject("roSGNode", "Label")
    label.font = font
    label.text = "Genres"
    label.color = theme.muted
    label.height = 64
    label.vertAlign = "center"
    label.translation = [20, 0]
    group.appendChild(label)
    value = CreateObject("roSGNode", "Label")
    value.font = font
    value.text = ZJoin(genres, ", ")
    value.color = theme.jade
    value.height = 64
    value.vertAlign = "center"
    x = 20 + ZTextWidth("Genres", font) + 20
    value.width = 1728 - x - 20
    value.translation = [x, 0]
    group.appendChild(value)
    return group
end function

' "Seasons & episodes", the season picker and, on an episode, View series.
function seasonHeading(seasons as object) as object
    group = CreateObject("roSGNode", "Group")
    title = CreateObject("roSGNode", "Label")
    title.font = ZFont(28, "bold")
    title.text = "Seasons & episodes"
    title.color = ZTheme().text
    title.translation = [96, 0]
    group.appendChild(title)
    bar = CreateObject("roSGNode", "ButtonBar")
    bar.buttonHeight = 56
    bar.fontSize = 24
    bar.spacing = 12
    bar.translation = [96, 52]
    bar.observeField("selected", "onSeasonBar")
    group.appendChild(bar)
    m.seasonBar = bar
    m.seasonList = seasons
    paintSeasonBar()
    m.seasonHeadingHeight = 52 + 56 + 4
    return group
end function

sub paintSeasonBar()
    if m.seasonBar = invalid then return
    name = "Choose season"
    for i = 0 to m.seasonList.getChildCount() - 1
        s = m.seasonList.getChild(i)
        if s.id = m.detail.seasonId then name = s.title
    end for
    buttons = []
    if m.seasonList.getChildCount() > 1 then
        buttons.push({ id: "season", text: name, icon: "chevron-down" })
    else
        buttons.push({ id: "season", text: name, disabled: true })
    end if
    if m.item.itemType = "Episode" and ZStr(m.item.seriesId) <> "" then
        buttons.push({ id: "series", text: "View series" })
    end if
    m.seasonBar.buttons = buttons
end sub

' MARK: Actions

sub buildActions()
    it = m.item
    d = m.detail
    theme = ZTheme()
    buttons = []
    showLike = it.itemType = "Series" or it.itemType = "Season"
    if it.itemType = "TvChannel" then
        buttons.push({ id: "play", text: "Watch live", icon: "play-filled", style: "primary", width: 260 })
    else
        resumeTicks = PlayableResume()
        label = "Play"
        if resumeTicks > 0 then
            label = "Resume"
        else if it.itemType = "Series" then
            label = "Play next episode"
        end if
        playable = not showLike or ZStr(d.resumeId) <> ""
        buttons.push({ id: "play", text: label, icon: "play-filled", style: "primary", width: 260, disabled: not playable })
        if it.favorite then
            buttons.push({ id: "favorite", icon: "heart-filled", style: "icon", tint: theme.jade })
        else
            buttons.push({ id: "favorite", icon: "heart", style: "icon" })
        end if
        if it.played then
            buttons.push({ id: "played", icon: "check-filled", style: "icon", tint: theme.jade })
        else
            buttons.push({ id: "played", icon: "check", style: "icon" })
        end if
        if resumeTicks > 0 then buttons.push({ id: "restart", icon: "restart", style: "icon" })
        if d.audioTracks.count() > 0 or d.subtitleTracks.count() > 0 then
            buttons.push({ id: "audio", icon: "audio", style: "icon", tint: theme.jade, disabled: d.audioTracks.count() = 0 })
            buttons.push({ id: "subtitles", icon: "subtitles", style: "icon", tint: theme.jade, disabled: d.subtitleTracks.count() = 0 })
        end if
        if ZStr(d.seriesId) <> "" then buttons.push({ id: "episodes", icon: "episodes", style: "icon" })
        if d.facts <> invalid and d.facts.count() > 0 then buttons.push({ id: "info", icon: "info", style: "icon" })
    end if
    if it.itemType = "TvChannel" and m.liveJoin <> invalid then
        buttons.push({ id: "join", text: "Watch " + m.liveJoin.channelName })
    end if
    focus = m.actions.focusIndex
    m.actions.buttons = buttons
    if focus < buttons.count() then m.actions.focusIndex = focus
end sub

' Resume point of the title Play would start.
function PlayableResume() as dynamic
    it = m.item
    if it.itemType = "Series" or it.itemType = "Season" then return ZNum(m.detail.resumePosition, 0)
    if it.played or it.progress >= 0.98 then return 0
    return it.positionTicks
end function

sub onAction(event as object)
    doAction(event.getData())
end sub

sub doAction(id as string)
    it = m.item
    d = m.detail
    if id = "play" then
        nav = { to: "player", id: it.id, startTicks: PlayableResume(), live: it.itemType = "TvChannel" }
        if it.itemType = "Series" or it.itemType = "Season" then
            if ZStr(d.resumeId) = "" then return
            nav.id = d.resumeId
        end if
        if m.audioIndex <> invalid then nav.audioIndex = m.audioIndex
        if m.subtitleIndex <> invalid then nav.subtitleIndex = m.subtitleIndex
        m.top.navigate = nav
    else if id = "restart" then
        nav = { to: "player", id: it.id, startTicks: 0 }
        if it.itemType = "Series" or it.itemType = "Season" then nav.id = d.resumeId
        if m.audioIndex <> invalid then nav.audioIndex = m.audioIndex
        if m.subtitleIndex <> invalid then nav.subtitleIndex = m.subtitleIndex
        m.top.navigate = nav
    else if id = "join" and m.liveJoin <> invalid then
        m.top.navigate = { to: "player", id: m.liveJoin.channelId, live: true }
    else if id = "played" then
        mutate("setPlayed", not it.played)
    else if id = "favorite" then
        mutate("setFavorite", not it.favorite)
    else if id = "audio" then
        options = [{ id: "auto", title: "Automatic", checked: m.audioIndex = invalid }]
        for each t in d.audioTracks
            options.push({ id: t.index.toStr(), title: t.title, checked: m.audioIndex <> invalid and m.audioIndex = t.index })
        end for
        pick("audio", "Audio", options)
    else if id = "subtitles" then
        options = [
            { id: "auto", title: "Automatic", checked: m.subtitleIndex = invalid },
            { id: "-1", title: "Off", checked: m.subtitleIndex <> invalid and m.subtitleIndex = -1 }
        ]
        for each t in d.subtitleTracks
            options.push({ id: t.index.toStr(), title: t.title, checked: m.subtitleIndex <> invalid and m.subtitleIndex = t.index })
        end for
        pick("subtitles", "Subtitles", options)
    else if id = "episodes" then
        i = -1
        for j = 0 to m.pageSections.count() - 1
            if m.pageSections[j].id = "seasons" then i = j
        end for
        if i >= 0 then ZPageFocus(i)
    else if id = "info" then
        options = []
        for each f in d.facts
            options.push({ id: f.title, title: f.title, subtitle: f.value })
        end for
        pick("info", "File details", options)
    end if
end sub

sub pick(kind as string, title as string, options as object)
    picker = CreateObject("roSGNode", "PickerDialog")
    picker.title = title
    picker.options = options
    picker.observeField("result", "onPicked")
    m.pickKind = kind
    m.pickReturn = m.top.focusedChild
    m.top.modal = true
    m.top.appendChild(picker)
    picker.focusIn = true
    m.picker = picker
end sub

sub onPicked(event as object)
    r = event.getData()
    m.top.removeChild(m.picker)
    m.picker = invalid
    m.top.modal = false
    chosen = invalid
    if r <> invalid and r.id <> invalid then chosen = r.id
    if chosen <> invalid then
        if m.pickKind = "audio" then
            if chosen = "auto" then m.audioIndex = invalid else m.audioIndex = chosen.toInt()
            m.top.toast = "Audio: " + PickedTitle(m.detail.audioTracks, m.audioIndex)
        else if m.pickKind = "subtitles" then
            if chosen = "auto" then
                m.subtitleIndex = invalid
            else
                m.subtitleIndex = chosen.toInt()
            end if
            if m.subtitleIndex <> invalid and m.subtitleIndex = -1 then
                m.top.toast = "Subtitles: Off"
            else
                m.top.toast = "Subtitles: " + PickedTitle(m.detail.subtitleTracks, m.subtitleIndex)
            end if
        else if m.pickKind = "season" then
            if chosen <> m.detail.seasonId then
                m.detail.seasonId = chosen
                paintSeasonBar()
                loadEpisodes(chosen)
            end if
        end if
    end if
    if m.pickKind = "season" and m.seasonBar <> invalid then
        m.seasonBar.setFocus(true)
    else
        m.actions.setFocus(true)
    end if
end sub

function PickedTitle(tracks as object, index as dynamic) as string
    if index = invalid then return "Automatic"
    for each t in tracks
        if t.index = index then return t.title
    end for
    return "Automatic"
end function

sub onSeasonBar(event as object)
    id = event.getData()
    if id = "series" then
        m.top.navigate = { to: "detail", id: m.item.seriesId }
    else if id = "season" then
        options = []
        for i = 0 to m.seasonList.getChildCount() - 1
            s = m.seasonList.getChild(i)
            options.push({ id: s.id, title: s.title, checked: s.id = m.detail.seasonId })
        end for
        pick("season", "Season", options)
    end if
end sub

sub mutate(cmd as string, value as boolean)
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: cmd, id: m.item.id, value: value }
    task.observeField("response", "onMutated")
    task.control = "RUN"
    m.mutateTask = task
end sub

sub onMutated(event as object)
    r = event.getData()
    if not r.ok then
        m.top.toast = "Couldn't update that. " + ZErrorText(r.error)
        return
    end if
    if r.cmd = "setPlayed" then
        m.item.played = r.value
        if r.value then
            m.item.positionTicks = 0
            m.item.progress = 0
            m.top.toast = "Marked as watched"
        else
            m.top.toast = "Marked as unwatched"
        end if
    else
        m.item.favorite = r.value
        if r.value then m.top.toast = "Added to Favorites" else m.top.toast = "Removed from Favorites"
    end if
    buildActions()
end sub

' MARK: Episodes

sub loadEpisodes(seasonId as string)
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "episodes", seriesId: m.detail.seriesId, seasonId: seasonId }
    task.observeField("response", "onEpisodes")
    task.control = "RUN"
    m.episodesTask = task
end sub

sub onEpisodes(event as object)
    r = event.getData()
    shelf = m.episodesShelf
    if shelf = invalid or not r.ok or r.seasonId <> m.detail.seasonId then return
    episodes = m.episodesTask.content
    current = ""
    if m.item.itemType = "Episode" then current = m.item.id
    if current = "" then current = ZStr(m.detail.resumeId)
    focusIndex = 0
    for i = 0 to episodes.getChildCount() - 1
        e = episodes.getChild(i)
        prefix = ""
        if e.episodeIndex >= 0 then prefix = e.episodeIndex.toStr() + ". "
        e.title = prefix + e.title
        ' Episode cards show the episode, not the series name.
        e.seriesName = ""
        caption = ZRuntimeText(e.runtimeTicks)
        if e.id = current then
            focusIndex = i
            if m.item.itemType = "Episode" then caption = ZJoin([caption, "Current episode"], " · ")
        else if e.played then
            caption = ZJoin([caption, "Watched"], " · ")
        else if e.positionTicks > 0 then
            caption = ZJoin([caption, ZRemainingText(e.runtimeTicks, e.positionTicks)], " · ")
        end if
        if Left(caption, 3) = " · " then caption = Mid(caption, 4)
        e.caption = caption
    end for
    hadFocus = shelf.isInFocusChain()
    shelf.content = episodes
    shelf.jumpTo = focusIndex
    ' The shelf now has a height and can take focus.
    for i = 0 to m.pageSections.count() - 1
        s = m.pageSections[i]
        if s.id = "episodes" then
            s.height = shelf.height
            if episodes.getChildCount() > 0 then s.focus = shelf else s.focus = invalid
        end if
    end for
    ZPageSet(m.pageSections, 28)
    if hadFocus then shelf.setFocus(true)
end sub

sub onEpisodeSelected(event as object)
    item = event.getData()
    if item = invalid then return
    ' Apple TV opens the episode's page; the current one is already open.
    if m.item.itemType = "Episode" and item.id = m.item.id then
        ZPageFocus(0)
        return
    end if
    m.top.navigate = { to: "detail", id: item.id }
end sub

sub onCardSelected(event as object)
    item = event.getData()
    if item <> invalid then m.top.navigate = ZCardAction(item)
end sub

' MARK: Focus

function focusKey() as object
    if m.pageIndex < 0 or m.pageIndex >= m.pageSections.count() then return { id: "", index: 0 }
    s = m.pageSections[m.pageIndex]
    index = 0
    if s.node.hasField("focusIndex") then index = s.node.focusIndex
    return { id: s.id, index: index }
end function

sub restoreFocus(keep = invalid as dynamic)
    if type(keep) <> "roAssociativeArray" then keep = invalid
    if m.item = invalid then
        m.top.setFocus(true)
        return
    end if
    if m.picker <> invalid then
        m.picker.focusIn = true
        return
    end if
    index = m.pageIndex
    if keep <> invalid and keep.id <> "" then
        for i = 0 to m.pageSections.count() - 1
            if m.pageSections[i].id = keep.id then
                index = i
                if m.pageSections[i].node.hasField("jumpTo") then m.pageSections[i].node.jumpTo = keep.index
            end if
        end for
    end if
    if not ZPageFocusable(index) then index = 0
    ZPageFocus(index, false)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "down" then return ZPageMove(1)
    if key = "up" then return ZPageMove(-1)
    if key = "play" then
        item = invalid
        for each s in m.pageSections
            if s.node.isInFocusChain() and s.node.hasField("itemFocused") then item = s.node.itemFocused
        end for
        if item <> invalid and (item.itemType = "Episode" or item.itemType = "Movie") then
            start = item.positionTicks
            if item.played then start = 0
            m.top.navigate = { to: "player", id: item.id, startTicks: start }
            return true
        end if
        if m.actions.isInFocusChain() then
            doAction("play")
            return true
        end if
    end if
    return false
end function

' MARK: Live TV streams line (channels only, companion liveTvStreams module)

' One line under a channel's Play button: who's on this channel, or which
' channel is using the last stream, with "Watch ESPN" added to the buttons.
sub watchStreams()
    live = m.item <> invalid and m.item.itemType = "TvChannel" and ZNum(m.global.features.liveTvStreams, 0) = 1
    if live and m.top.visible then
        loadStreams()
        m.streamsTimer.control = "start"
    else
        m.streamsTimer.control = "stop"
    end if
end sub

sub loadStreams()
    if m.item = invalid then return
    if m.streamsTask <> invalid and m.streamsTask.state = "run" then return
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "liveStreams", channelId: m.item.id }
    task.observeField("response", "onStreams")
    task.control = "RUN"
    m.streamsTask = task
end sub

sub onStreams(event as object)
    r = event.getData()
    if m.item = invalid or ZStr(r.channelId) <> m.item.id then return
    line = ""
    join = invalid
    playing = false
    if r.ok then
        line = ZLtsChannelLine(r.status, m.item.id)
        playing = ZLtsStream(r.status, m.item.id) <> invalid
        blocked = ZLtsBlocked(r.status, m.item.id)
        if blocked <> invalid then join = blocked.join
    end if
    group = m.top.findNode("liveLine")
    wasVisible = group.visible
    group.visible = line <> ""
    m.top.findNode("liveText").text = line
    color = "0xE0B44AFF"
    if playing then color = "0x72E79BFF"
    m.top.findNode("liveDot").blendColor = color
    m.top.findNode("liveHalo").blendColor = Left(color, 8) + "33"
    joinChanged = (join = invalid) <> (m.liveJoin = invalid)
    if not joinChanged and join <> invalid and m.liveJoin <> invalid then joinChanged = join.channelId <> m.liveJoin.channelId
    m.liveJoin = join
    if joinChanged then buildActions()
    if wasVisible <> group.visible then
        renderOverview()
        m.pageSections[0].height = m.overviewHeight
        ZPageSet(m.pageSections, 28)
    end if
end sub
