sub init()
    m.top.findNode("statusIcon").blendColor = ZAccent()
    m.page = m.top.findNode("page")
    m.page.id = "page"
    m.statusGroup = m.top.findNode("statusGroup")
    m.retry = m.top.findNode("retry")
    m.top.findNode("statusTitle").font = ZFont(32, "semibold")
    m.top.findNode("statusDetail").font = ZFont(22)
    m.retry.buttons = [{ id: "retry", text: "Try again" }]
    m.retry.observeField("selected", "load")
    ZPageInit(m.page, 140)
    m.banner = invalid
    m.hero = invalid
    m.lastLoad = 0
    m.content = invalid
    m.rows = []
    m.liveRow = invalid
    m.liveShelf = invalid
    m.hasLiveTv = false
    m.liveTask = invalid
    m.liveLoaded = 0
    m.scoresUntil = 0
    m.liveFeatures = {}
    m.liveArt = invalid
    m.liveArtAt = 0
    ' Live now refreshes every minute while Home is on screen (scores move).
    m.liveTimer = CreateObject("roSGNode", "Timer")
    m.liveTimer.duration = 60
    m.liveTimer.repeat = true
    m.liveTimer.observeField("fire", "onLiveTimer")
    initPreview()
    load()
end sub

sub load()
    if m.content = invalid then showStatus("film", "Loading your library…", "", false)
    task = CreateObject("roSGNode", "JellyfinTask")
    m.task = task
    task.request = { cmd: "home", cold: m.content = invalid }
    task.observeField("cachedHome", "onCachedHome")
    task.observeField("response", "onHome")
    task.control = "RUN"
    m.task = task
    m.lastLoad = ZNowSeconds()
end sub

sub showStatus(icon as string, title as string, detail as string, retry as boolean)
    m.top.findNode("statusIcon").uri = "pkg:/images/icons/" + icon + ".png"
    m.top.findNode("statusTitle").text = title
    m.top.findNode("statusDetail").text = detail
    m.retry.visible = retry
    if retry then m.retry.translation = [Int((1920 - m.retry.totalWidth + 16) / 2), 600]
    m.statusGroup.visible = true
end sub

sub onCachedHome(event as object)
    if m.content <> invalid or not m.task.isSameNode(event.getRoSGNode()) then return
    content = event.getData()
    if content = invalid then return
    m.content = content
    m.rows = content.getChildren(-1, 0)
    m.statusGroup.visible = false
    hadFocus = m.top.isInFocusChain()
    build()
    if hadFocus then restoreFocus()
end sub

sub onHome(event as object)
    if not m.task.isSameNode(event.getRoSGNode()) then return
    r = event.getData()
    content = m.task.content
    if not r.ok then
        if r.status = 401 or r.status = 403 then
            m.content = invalid
            m.rows = []
            m.banner = invalid
            m.liveRow = invalid
            build()
        end if
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        if m.content = invalid then
            showStatus("film", "Library unavailable", ZErrorText(r.error), true)
            m.retry.setFocus(true)
        end if
        m.top.loaded = { views: [], features: {} }
        return
    end if
    m.statusGroup.visible = false
    ' The banner travels as the first row, id "banner".
    m.banner = invalid
    if content.getChildCount() > 0 and content.getChild(0).id = "banner" then
        bannerRow = content.getChild(0)
        if bannerRow.getChildCount() > 0 then m.banner = bannerRow.getChild(0)
        content.removeChildIndex(0)
    end if
    if content.getChildCount() = 0 and m.banner = invalid then
        showStatus("film", "Your library is ready for its first title", "Media added to your Jellyfin server will appear here.", false)
    end if
    hadFocus = m.top.isInFocusChain()
    keep = focusKey()
    m.content = content
    ' Snapshot first: a Shelf adopts its row, which removes it from content,
    ' so a later rebuild (Live now appearing) reuses this list.
    m.rows = []
    for i = 0 to content.getChildCount() - 1
        m.rows.push(content.getChild(i))
    end for
    build()
    if hadFocus then restoreFocus(keep)
    m.top.loaded = { views: r.views, features: r.features }
    m.hasLiveTv = false
    if r.views <> invalid then
        for each v in r.views
            if v.collectionType = "livetv" then m.hasLiveTv = true
        end for
    end if
    m.liveFeatures = r.features
    if m.hasLiveTv then
        loadLive()
        m.liveTimer.control = "start"
    else
        m.liveTimer.control = "stop"
        if m.liveShelf <> invalid then
            m.liveRow = invalid
            rebuild()
        end if
    end if
end sub

' MARK: Live now

sub loadLive()
    if m.liveTask <> invalid then return
    task = CreateObject("roSGNode", "JellyfinTask")
    ' No companion (404) or the sports module off (403): guide-only for ten minutes.
    req = { cmd: "liveNow", sports: ZNum(m.liveFeatures.sportsEvents, 0) = 1, scores: ZNowSeconds() >= m.scoresUntil }
    ' The artwork catalogue is reused for five minutes.
    if m.liveArt <> invalid and ZNowSeconds() - m.liveArtAt < 300 then req.art = m.liveArt
    task.request = req
    task.observeField("response", "onLive")
    task.control = "RUN"
    m.liveTask = task
    m.liveLoaded = ZNowSeconds()
end sub

sub onLiveTimer()
    ' Only while Home is attached and visible (screens detach when covered).
    if m.top.getParent() = invalid or not m.top.visible then return
    loadLive()
end sub

sub onLive(event as object)
    r = event.getData()
    row = m.liveTask.content
    m.liveTask = invalid
    if r = invalid or not r.ok then return
    if r.scoresStatus = 404 or r.scoresStatus = 403 then m.scoresUntil = ZNowSeconds() + 600
    if ZIsMap(r.art) and (m.liveArt = invalid or ZNowSeconds() - m.liveArtAt >= 300) then
        m.liveArt = r.art
        m.liveArtAt = ZNowSeconds()
    end if
    if row = invalid or row.getChildCount() = 0 then row = invalid
    if row <> invalid and m.liveShelf <> invalid then
        ' Same shelf: swap its cards in place and keep the viewer's card.
        index = m.liveShelf.focusIndex
        m.liveShelf.content = row
        m.liveRow = row
        if index > 0 then m.liveShelf.jumpTo = ZMin(index, row.getChildCount() - 1)
        return
    end if
    if row = invalid and m.liveShelf = invalid then return
    m.liveRow = row
    rebuild()
end sub

' Re-lays the page when the Live now row appears or goes away.
sub rebuild()
    if m.content = invalid and m.banner = invalid then return
    hadFocus = m.top.isInFocusChain()
    keep = focusKey()
    build()
    if hadFocus then restoreFocus(keep)
end sub

' Which shelf and card had focus, so a refresh keeps the viewer's place.
function focusKey() as object
    if m.pageIndex < 0 or m.pageIndex >= m.pageSections.count() then return { id: "", index: 0 }
    s = m.pageSections[m.pageIndex]
    index = 0
    if s.node.hasField("focusIndex") then index = s.node.focusIndex
    return { id: s.id, index: index }
end function

sub build()
    m.page.removeChildrenIndex(m.page.getChildCount(), 0)
    sections = []
    if m.banner <> invalid then
        hero = CreateObject("roSGNode", "HeroBanner")
        hero.translation = [96, 0]
        hero.item = m.banner
        hero.observeField("action", "onHeroAction")
        m.page.appendChild(hero)
        m.hero = hero
        sections.push({ id: "banner", node: hero, focus: hero, height: 480 })
    else
        m.hero = invalid
    end if
    m.liveShelf = invalid
    for each row in ZHomeDisplayRows(m.rows, m.liveRow)
        if row <> invalid and row.getChildCount() > 0 then
            shelf = CreateObject("roSGNode", "Shelf")
            shelf.landscape = row.hasField("landscape") and row.landscape = true
            if m.liveRow <> invalid and row.isSameNode(m.liveRow) then
                shelf.itemComponent = "LiveEventCard"
                m.liveShelf = shelf
            end if
            shelf.title = row.title
            shelf.content = row
            shelf.observeField("itemSelected", "onItemSelected")
            if not shelf.landscape then shelf.observeField("itemFocused", "onCardFocused")
            m.page.appendChild(shelf)
            sections.push({ id: row.id, node: shelf, focus: shelf, height: shelf.height })
        end if
    end for
    ZPageSet(sections)
end sub

sub restoreFocus(keep = invalid as dynamic)
    ' As the focusIn handler this receives the field event, not a key.
    if type(keep) <> "roAssociativeArray" then keep = invalid
    if m.retry.visible and m.statusGroup.visible then
        m.retry.setFocus(true)
        return
    end if
    if m.pageSections.count() = 0 then
        m.top.setFocus(true)
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
    if index < 0 or index >= m.pageSections.count() then index = 0
    ZPageFocus(index, false)
end sub

sub onResumed()
    ' Refresh Continue Watching after playback or details, at most every 20 s.
    if ZNowSeconds() - m.lastLoad >= 20 then load()
end sub

sub onHeroAction(event as object)
    b = m.banner
    if b = invalid then return
    action = event.getData()
    if action = "play" then
        if b.itemType = "Series" then
            m.top.navigate = { to: "detail", id: b.id, autoplay: true }
        else
            m.top.navigate = { to: "player", id: b.id, startTicks: b.positionTicks }
        end if
    else if action = "info" then
        m.top.navigate = { to: "detail", id: b.id }
    else if action = "favorite" then
        value = not m.hero.favorite
        m.hero.favorite = value
        b.favorite = value
        task = CreateObject("roSGNode", "JellyfinTask")
        task.request = { cmd: "setFavorite", id: b.id, value: value }
        task.observeField("response", "onFavorite")
        task.control = "RUN"
        m.favTask = task
    end if
end sub

sub onFavorite(event as object)
    r = event.getData()
    if not r.ok then
        m.hero.favorite = not r.value
        m.top.toast = "Couldn't update that. " + ZErrorText(r.error)
    end if
end sub

sub onItemSelected(event as object)
    stopPreview()
    item = event.getData()
    if item = invalid then return
    ' Every card opens details, Continue Watching included, so Resume is an
    ' explicit choice and the series is one step away. Play on the remote
    ' still starts a title directly (onKeyEvent).
    m.top.navigate = ZCardAction(item)
end sub

function focusedCard() as dynamic
    if m.pageIndex < 0 or m.pageIndex >= m.pageSections.count() then return invalid
    node = m.pageSections[m.pageIndex].node
    if node.subtype() <> "Shelf" then return invalid
    return node.itemFocused
end function

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "down" or key = "up" or key = "back" then stopPreview()
    if key = "down" then return ZPageMove(1)
    if key = "up" then return ZPageMove(-1)
    if key = "play" then
        stopPreview()
        item = focusedCard()
        if item <> invalid and item.itemType <> "Series" and item.itemType <> "Season" and not item.isFolder then
            m.top.navigate = { to: "player", id: item.id, startTicks: item.positionTicks, live: item.itemType = "TvChannel" }
            return true
        end if
    end if
    return false
end function

' MARK: Trailer previews (Apple TV Home, adapted to Roku)
'
' Rest on a movie or show poster for two seconds and its local trailer plays
' muted in a window just above that row (a Roku RowList can't widen one card).
' Moving, selecting or leaving Home stops it; it returns to the artwork after
' 30 seconds. Direct play only, never reported as playback.

sub initPreview()
    m.previewTimer = CreateObject("roSGNode", "Timer")
    m.previewTimer.duration = 2
    m.previewTimer.repeat = false
    m.previewTimer.observeField("fire", "onPreviewDwell")
    frame = CreateObject("roSGNode", "Rectangle")
    frame.width = 652
    frame.height = 372
    frame.color = ZTheme().panel
    frame.visible = false
    video = CreateObject("roSGNode", "Video")
    video.width = 640
    video.height = 360
    video.translation = [6, 6]
    video.enableUI = false
    video.mute = true
    video.observeField("state", "onPreviewState")
    video.observeField("position", "onPreviewPosition")
    frame.appendChild(video)
    m.top.appendChild(frame)
    m.previewFrame = frame
    m.preview = video
    m.previewItem = invalid
    m.previewShelf = invalid
    m.previewTask = invalid
    m.top.observeField("visible", "onHomeVisible")
end sub

sub onHomeVisible()
    if not m.top.visible then stopPreview()
end sub

sub stopPreview()
    if m.previewTimer = invalid then return
    m.previewTimer.control = "stop"
    m.previewTask = invalid
    if m.previewFrame.visible or m.preview.state = "playing" or m.preview.state = "buffering" then
        m.preview.control = "stop"
        m.preview.content = invalid
        m.previewFrame.visible = false
    end if
    m.previewItem = invalid
end sub

sub onCardFocused(event as object)
    item = event.getData()
    shelf = event.getRoSGNode()
    stopPreview()
    if item = invalid or not shelf.isInFocusChain() then return
    if item.itemType <> "Movie" and item.itemType <> "Series" then return
    if m.global.settings <> invalid and m.global.settings.autoplayPreviews = false then return
    m.previewItem = item
    m.previewShelf = shelf
    m.previewTimer.control = "start"
end sub

sub onPreviewDwell()
    item = m.previewItem
    if item = invalid or m.previewShelf = invalid or not m.previewShelf.isInFocusChain() then return
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "trailer", id: item.id }
    task.observeField("response", "onTrailer")
    task.control = "RUN"
    m.previewTask = task
end sub

sub onTrailer(event as object)
    r = event.getData()
    item = m.previewItem
    if m.previewTask = invalid or item = invalid or r = invalid or ZStr(r.id) <> item.id or ZStr(r.url) = "" then return
    m.previewTask = invalid
    shelf = m.previewShelf
    if shelf = invalid or not shelf.isInFocusChain() then return
    ' Just above the focused row's cards, on the right; below it when the
    ' row is near the top of the screen.
    y = m.page.translation[1] + shelf.translation[1] - 384
    if y < 140 then y = m.page.translation[1] + shelf.translation[1] + shelf.height + 8
    if y + 372 > 1070 then y = 1070 - 372
    m.previewFrame.translation = [1920 - 96 - 652, y]
    content = CreateObject("roSGNode", "ContentNode")
    content.url = r.url
    content.streamFormat = "mp4"
    if r.caption <> invalid then content.subtitleTracks = [r.caption]
    m.preview.content = content
    if r.caption <> invalid then
        m.preview.subtitleTrack = r.caption.TrackName
    end if
    m.preview.mute = true
    m.preview.control = "play"
end sub

sub onPreviewState()
    state = m.preview.state
    if state = "playing" then
        if m.previewItem <> invalid then m.previewFrame.visible = true
    else if state = "error" or state = "finished" then
        stopPreview()
    end if
end sub

sub onPreviewPosition()
    if m.preview.position >= 30 then stopPreview()
end sub
