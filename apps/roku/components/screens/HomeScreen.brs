sub init()
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
    load()
end sub

sub load()
    if m.content = invalid then showStatus("film", "Loading your library…", "", false)
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "home" }
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

sub onHome(event as object)
    r = event.getData()
    content = m.task.content
    if not r.ok then
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
    build()
    if hadFocus then restoreFocus(keep)
    m.top.loaded = { views: r.views, features: r.features }
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
    ' Snapshot first: a Shelf adopts its row, which removes it from m.content.
    rows = []
    for i = 0 to m.content.getChildCount() - 1
        rows.push(m.content.getChild(i))
    end for
    for each row in rows
        if row <> invalid and row.getChildCount() > 0 then
            shelf = CreateObject("roSGNode", "Shelf")
            shelf.landscape = row.hasField("landscape") and row.landscape = true
            shelf.title = row.title
            rowId = row.id
            shelf.content = row
            shelf.observeField("itemSelected", "onItemSelected")
            m.page.appendChild(shelf)
            sections.push({ id: rowId, node: shelf, focus: shelf, height: shelf.height })
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
    if key = "down" then return ZPageMove(1)
    if key = "up" then return ZPageMove(-1)
    if key = "play" then
        item = focusedCard()
        if item <> invalid and item.itemType <> "Series" and item.itemType <> "Season" and not item.isFolder then
            m.top.navigate = { to: "player", id: item.id, startTicks: item.positionTicks, live: item.itemType = "TvChannel" }
            return true
        end if
    end if
    return false
end function
