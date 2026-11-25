' See LiveTvScreen.xml. Channels load once; listings load 40 channels at a
' time for the rows on screen (Apple guideChannels / guidePrograms).

sub init()
    m.top.findNode("previewLine").color = ZAccent()
    m.offset = ZGuideLocalOffset()
    m.controls = m.top.findNode("controls")
    m.modes = m.top.findNode("modes")
    m.browse = m.top.findNode("browse")
    m.browseStatus = m.top.findNode("browseStatus")
    m.browseStatus.font = ZFont(24)
    m.sports = m.top.findNode("sports")
    m.onNow = m.top.findNode("onNow")
    m.showGuide = false
    m.loadedBrowseAt = 0
    m.modes.observeField("selected", "onMode")
    m.sports.observeField("itemSelected", "onBrowseSelected")
    m.onNow.observeField("itemSelected", "onBrowseSelected")
    m.grid = m.top.findNode("grid")
    m.status = m.top.findNode("status")
    m.strip = m.top.findNode("strip")
    m.preview = m.top.findNode("preview")
    m.status.font = ZFont(28)
    m.top.findNode("previewName").font = ZFont(30, "bold")
    m.top.findNode("previewTime").font = ZFont(21)
    m.top.findNode("previewLine").font = ZFont(22, "semibold")
    m.top.findNode("previewBody").font = ZFont(21)
    m.all = []
    m.query = ""
    m.favorites = false
    m.follows = true
    m.requested = {}
    m.dialog = invalid
    m.streamStatus = invalid
    now = ZNowSeconds()
    m.grid.offset = m.offset
    m.grid.now = now
    m.grid.windowStart = ZGuideWindowStart(now, m.offset)
    m.grid.observeField("topIndex", "ensurePrograms")
    m.grid.observeField("focusInfo", "paintPreview")
    m.grid.observeField("selected", "onSelected")
    m.grid.observeField("play", "onPlay")
    m.grid.observeField("edge", "onEdge")
    m.controls.observeField("selected", "onControl")
    m.strip.server = ZStr(m.global.session.server)
    m.strip.observeField("selected", "onJoin")
    m.clock = m.top.findNode("clock")
    m.clock.observeField("fire", "onClock")
    m.clock.control = "start"
    m.streamsTimer = m.top.findNode("streamsTimer")
    m.streamsTimer.observeField("fire", "loadStreams")
    m.top.observeField("visible", "onVisible")
    showMode(false)
    onVisible()
end sub

sub onMode(event as object)
    showMode(event.getData() = "guide")
end sub

sub showMode(guide as boolean)
    hadFocus = m.top.isInFocusChain()
    m.showGuide = guide
    programStyle = "primary"
    guideStyle = "secondary"
    if guide then
        programStyle = "secondary"
        guideStyle = "primary"
    end if
    m.modes.buttons = [
        { id: "programs", text: "Programs", style: programStyle },
        { id: "guide", text: "Guide", style: guideStyle }
    ]
    m.controls.visible = guide
    m.browse.visible = not guide
    m.status.visible = guide
    if guide then
        buildControls()
        applyFilter()
        if m.all.count() = 0 then load()
        m.modes.callFunc("focusButton", "guide")
    else
        m.grid.visible = false
        m.preview.visible = false
        loadBrowse()
        m.modes.callFunc("focusButton", "programs")
    end if
    if hadFocus then m.modes.setFocus(true)
    layout()
end sub

sub loadBrowse()
    if m.browseTask <> invalid or m.showGuide or not m.top.visible then return
    if m.loadedBrowseAt > 0 and ZNowSeconds() - m.loadedBrowseAt < 60 then return
    if not m.sports.visible and not m.onNow.visible then m.browseStatus.text = "Loading live programs…"
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "liveNow", programs: true, sports: ZNum(m.global.features.sportsEvents, 0) = 1 }
    task.observeField("response", "onBrowse")
    m.browseTask = task
    m.loadedBrowseAt = ZNowSeconds()
    task.control = "RUN"
end sub

sub onBrowse(event as object)
    result = event.getData()
    rows = m.browseTask.content
    m.browseTask = invalid
    if result = invalid or not result.ok or rows = invalid then
        if result <> invalid and result.error = "unauthorized" then m.top.sessionExpired = true
        if not m.sports.visible and not m.onNow.visible then m.browseStatus.text = "Live programs unavailable. Open Guide for channels."
        return
    end if
    sports = rows.getChild(0)
    updateBrowseShelf(m.sports, sports)
    ' Owner rule (Nov 24): no "On now" row in any app; Live TV browsing shows
    ' Sports & live events, and the Guide has every channel.
    updateBrowseShelf(m.onNow, invalid)
    m.browseStatus.text = ""
    if not m.sports.visible and not m.onNow.visible then m.browseStatus.text = "No sports or live events right now. Open Guide for channels."
    layout()
end sub

sub updateBrowseShelf(shelf as object, row as dynamic)
    hasCards = row <> invalid and row.getChildCount() > 0
    if hasCards then
        index = shelf.focusIndex
        ' Shelf takes ownership of the row's content node.
        if row.getParent() <> invalid then row.getParent().removeChild(row)
        shelf.content = row
        if index > 0 then shelf.jumpTo = ZMin(index, row.getChildCount() - 1)
    else if shelf.isInFocusChain() then
        m.modes.setFocus(true)
    end if
    shelf.visible = hasCards
end sub

sub onBrowseSelected(event as object)
    item = event.getData()
    if item = invalid or item.live = invalid then return
    now = ZNowSeconds()
    if item.live.start > now or item.live.finish <= now then return
    m.top.navigate = { to: "player", id: item.id, live: true }
end sub

' MARK: Controls

sub buildControls()
    filterText = "All channels"
    filterIcon = "list"
    if m.favorites then
        filterText = "Favorites"
        filterIcon = "heart-filled"
    end if
    find = "Find a channel"
    if m.query <> "" then find = "“" + m.query + "”"
    ws = m.grid.windowStart
    now = ZNowSeconds()
    first = ZGuideDayStart(now, m.offset)
    m.controls.buttons = [
        { id: "find", text: find, icon: "search" },
        { id: "filter", text: filterText, icon: filterIcon },
        { id: "refresh", icon: "refresh", style: "icon" },
        { id: "day", text: ZGuideDayLabel(ws, now, m.offset) + "  ·  " + ZGuideRange(ws, ws + ZGuideDuration(), m.offset), icon: "chevron-down" },
        { id: "earlier", icon: "chevron-left", style: "icon", disabled: ws <= first },
        { id: "now", text: "Now" },
        { id: "later", icon: "chevron-right", style: "icon", disabled: ws + ZGuideDuration() >= first + 7 * 86400 }
    ]
end sub

sub onControl(event as object)
    id = event.getData()
    if id = "find" then
        entry = CreateObject("roSGNode", "TextEntry")
        entry.title = "Find a channel"
        entry.message = "Type a channel name or number. Leave it empty to show every channel."
        entry.text = m.query
        entry.doneText = "Find"
        entry.observeField("result", "onFind")
        openDialog(entry)
    else if id = "filter" then
        pick("filter", "Channels", [
            { id: "all", title: "All channels", checked: not m.favorites },
            { id: "favorites", title: "Favorites", checked: m.favorites }
        ])
    else if id = "refresh" then
        load()
    else if id = "day" then
        options = []
        first = ZGuideDayStart(ZNowSeconds(), m.offset)
        for d = 0 to 6
            options.push({ id: d.toStr(), title: ZGuideLongDay(first + d * 86400 + 43200, m.offset) })
        end for
        pick("day", "Choose a day", options)
    else if id = "earlier" then
        shiftWindow(-1)
    else if id = "later" then
        shiftWindow(1)
    else if id = "now" then
        m.follows = true
        setWindow(ZGuideWindowStart(ZNowSeconds(), m.offset))
        m.grid.callFunc("focusTime", ZNowSeconds())
        if m.grid.channels.count() > 0 then m.grid.setFocus(true)
    end if
end sub

sub onFind(event as object)
    r = event.getData()
    closeDialog()
    if r <> invalid and r.ok = true then
        m.query = ZGuideTrim(ZStr(r.text))
        applyFilter()
    end if
end sub

sub shiftWindow(pages as integer)
    m.follows = false
    setWindow(m.grid.windowStart + pages * ZGuideDuration())
end sub

sub setWindow(start as integer)
    start = ZGuideClampStart(start, ZNowSeconds(), m.offset)
    m.requested = {}
    m.grid.failed = false
    m.grid.now = ZNowSeconds()
    m.grid.windowStart = start
    focusId = m.controls.focusedId
    buildControls()
    m.controls.callFunc("focusButton", focusId)
    ensurePrograms()
end sub

sub onEdge(event as object)
    if event.getData() = "later" then shiftWindow(1) else shiftWindow(-1)
end sub

' MARK: Loading

sub load()
    if m.all.count() = 0 then m.status.text = "Loading channels…"
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "guideChannels" }
    task.observeField("response", "onChannels")
    task.control = "RUN"
    m.task = task
    m.requested = {}
    m.grid.failed = false
    if m.follows then setWindow(ZGuideWindowStart(ZNowSeconds(), m.offset))
end sub

sub onChannels(event as object)
    r = event.getData()
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        if m.all.count() = 0 then m.status.text = ZErrorText(r.error)
        return
    end if
    m.all = r.channels
    applyFilter()
end sub

sub applyFilter()
    focused = invalid
    info = m.grid.focusInfo
    if info <> invalid and info.channel <> invalid then focused = info.channel.id
    list = ZGuideMatch(m.all, m.query, m.favorites)
    m.grid.channels = list
    m.grid.callFunc("focusChannel", focused)
    buildControls()
    m.controls.callFunc("focusButton", m.controls.focusedId)
    showsGrid = m.showGuide and list.count() > 0
    m.grid.visible = showsGrid
    m.preview.visible = showsGrid
    if showsGrid then
        m.status.text = ""
    else if m.all.count() = 0 then
        m.status.text = "This server has no Live TV channels." + Chr(10) + "Channels available on your server will appear here."
    else if m.query <> "" then
        m.status.text = "No channels match “" + m.query + "”."
    else
        m.status.text = "No favorite channels yet." + Chr(10) + "Favorite channels from their details to find them here."
    end if
    if not showsGrid and m.grid.isInFocusChain() then m.controls.setFocus(true)
    if showsGrid and m.top.isInFocusChain() and not m.controls.isInFocusChain() and not m.strip.isInFocusChain() and not m.modes.isInFocusChain() and m.dialog = invalid then m.grid.setFocus(true)
    ensurePrograms()
end sub

' Requests listings for channels on screen (and the next few) that have not
' been asked for in this window, 40 at a time.
sub ensurePrograms()
    if not m.showGuide or not m.top.visible then return
    channels = m.grid.channels
    if channels = invalid or channels.count() = 0 then return
    first = ZMax(0, m.grid.topIndex - 5)
    last = ZMin(channels.count() - 1, m.grid.topIndex + 20)
    ids = []
    for i = first to last
        id = channels[i].id
        if not m.requested.doesExist(id) and ids.count() < 40 then ids.push(id)
    end for
    if ids.count() = 0 then return
    for each id in ids
        m.requested[id] = true
    end for
    ws = m.grid.windowStart
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "guidePrograms", channelIds: ids, start: ws, finish: ws + ZGuideDuration() }
    task.observeField("response", "onPrograms")
    task.control = "RUN"
    if m.programTasks = invalid then m.programTasks = []
    m.programTasks.push(task)
    if m.programTasks.count() > 4 then m.programTasks.shift()
end sub

sub onPrograms(event as object)
    r = event.getData()
    if r.start <> m.grid.windowStart then return
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        for each id in r.channelIds
            m.requested.delete(id)
        end for
        m.grid.failed = true
        m.top.toast = "The schedule couldn't refresh. Channels are still available."
        return
    end if
    update = {}
    for each id in r.channelIds
        update[id] = []
    end for
    for each p in r.programs
        if update.doesExist(p.channelId) then update[p.channelId].push(p)
    end for
    m.grid.programs = update
end sub

sub onClock()
    if not m.showGuide then
        loadBrowse()
        return
    end if
    now = ZNowSeconds()
    ws = m.grid.windowStart
    if m.follows and now >= ws + 1800 then
        setWindow(ZGuideWindowStart(now, m.offset))
    else
        m.grid.now = now
    end if
end sub

' MARK: Preview and details

sub paintPreview()
    info = m.grid.focusInfo
    name = m.top.findNode("previewName")
    time = m.top.findNode("previewTime")
    line = m.top.findNode("previewLine")
    body = m.top.findNode("previewBody")
    if info = invalid or info.channel = invalid then
        name.text = "TV Guide"
        time.text = ""
        line.text = ""
        body.text = ""
        return
    end if
    p = info.program
    if p = invalid then
        name.text = info.channel.name
        time.text = ""
        line.text = ""
        body.text = ""
    else
        name.text = p.name
        time.text = ZGuideRange(p.start, p.finish, m.offset)
        episode = ZStr(p.episodeTitle)
        if episode = "" then episode = info.channel.name
        line.text = episode
        body.text = ZStr(p.overview)
    end if
    w = ZMin(1300, ZTextWidth(name.text, name.font) + 4)
    name.width = w
    time.translation = [w + 16, 7]
    channelLine = ""
    if m.streamStatus <> invalid then channelLine = ZLtsChannelLine(m.streamStatus, info.channel.id)
    if channelLine <> "" and p = invalid then line.text = channelLine
end sub

sub onSelected(event as object)
    info = event.getData()
    if info = invalid or info.channel = invalid then return
    m.detail = info
    c = info.channel
    p = info.program
    lines = []
    title = c.name
    if p <> invalid then
        title = p.name
        lines.push(c.name + "  ·  " + ZGuideDayLabel(p.start, ZNowSeconds(), m.offset) + ", " + ZGuideRange(p.start, p.finish, m.offset))
        if ZStr(p.episodeTitle) <> "" then lines.push(p.episodeTitle)
        if ZStr(p.overview) <> "" then lines.push(p.overview)
        if not ZGuideAiring(p, ZNowSeconds()) then lines.push("Watch live plays this channel's current broadcast.")
    else
        lines.push("No program information available.")
    end if
    using = ""
    if m.streamStatus <> invalid then using = ZLtsChannelLine(m.streamStatus, c.id)
    if using <> "" then lines.push(using)
    favorite = "Add to Favorites"
    if c.favorite = true then favorite = "Remove from Favorites"
    picker = CreateObject("roSGNode", "PickerDialog")
    picker.title = title
    picker.message = ZJoin(lines, Chr(10))
    picker.options = [{ id: "watch", title: "Watch live" }, { id: "favorite", title: favorite }]
    picker.observeField("result", "onDetail")
    openDialog(picker)
end sub

sub onDetail(event as object)
    r = event.getData()
    closeDialog()
    info = m.detail
    if r = invalid or info = invalid then return
    if r.id = "watch" then
        playChannel(info.channel)
    else if r.id = "favorite" then
        value = info.channel.favorite <> true
        task = CreateObject("roSGNode", "JellyfinTask")
        task.request = { cmd: "setFavorite", id: info.channel.id, value: value }
        task.observeField("response", "onFavorite")
        task.control = "RUN"
        m.favoriteTask = task
    end if
end sub

sub onFavorite(event as object)
    r = event.getData()
    if not r.ok then
        m.top.toast = "Couldn't update Favorites. Try again."
        return
    end if
    for each c in m.all
        if c.id = r.id then c.favorite = r.value
    end for
    if r.value then m.top.toast = "Added to Favorites" else m.top.toast = "Removed from Favorites"
    applyFilter()
end sub

sub onPlay(event as object)
    info = event.getData()
    if info <> invalid and info.channel <> invalid then playChannel(info.channel)
end sub

sub playChannel(channel as object)
    m.top.navigate = { to: "player", id: channel.id, live: true }
end sub

' MARK: Dialogs

sub pick(kind as string, title as string, options as object)
    picker = CreateObject("roSGNode", "PickerDialog")
    picker.title = title
    picker.options = options
    picker.observeField("result", "onPicked")
    m.pickKind = kind
    openDialog(picker)
end sub

sub onPicked(event as object)
    r = event.getData()
    closeDialog()
    if r = invalid or r.id = invalid then return
    if m.pickKind = "filter" then
        m.favorites = r.id = "favorites"
        applyFilter()
    else if m.pickKind = "day" then
        m.dayPicked = Int(ZNum(Val(r.id), 0))
        options = []
        for h = 0 to 22 step 2
            options.push({ id: h.toStr(), title: ZGuideTime(ZGuideDayStart(ZNowSeconds(), m.offset) + h * 3600, m.offset) })
        end for
        pick("hour", ZGuideLongDay(ZGuideDayStart(ZNowSeconds(), m.offset) + m.dayPicked * 86400 + 43200, m.offset), options)
    else if m.pickKind = "hour" then
        m.follows = false
        day = ZGuideDayStart(ZNowSeconds(), m.offset) + m.dayPicked * 86400
        setWindow(day + Int(ZNum(Val(r.id), 0)) * 3600)
    end if
end sub

sub openDialog(node as object)
    m.dialogReturn = m.top.focusedChild
    if m.grid.isInFocusChain() then m.dialogReturn = m.grid
    if m.controls.isInFocusChain() then m.dialogReturn = m.controls
    m.dialog = node
    m.top.modal = true
    m.top.appendChild(node)
    node.focusIn = true
end sub

sub closeDialog()
    if m.dialog <> invalid then m.top.removeChild(m.dialog)
    m.dialog = invalid
    m.top.modal = false
    if m.dialogReturn <> invalid and m.dialogReturn.visible then
        m.dialogReturn.setFocus(true)
    else
        restoreFocus()
    end if
end sub

sub restoreFocus()
    if m.dialog <> invalid then
        m.dialog.focusIn = true
    else if m.strip.isInFocusChain() and m.strip.visible then
        return
    else if not m.showGuide then
        m.modes.setFocus(true)
    else if m.grid.visible and m.grid.channels <> invalid and m.grid.channels.count() > 0 then
        m.grid.setFocus(true)
    else
        m.controls.setFocus(true)
    end if
end sub

' MARK: Playing now (companion liveTvStreams module)

' Polls every 15 s while this screen is showing and the server offers it.
sub onVisible()
    if m.top.visible and ZLtsRoute(m.global.features) <> "" then
        loadStreams()
        m.streamsTimer.control = "start"
    else
        m.streamsTimer.control = "stop"
    end if
    if m.top.visible then m.clock.control = "start" else m.clock.control = "stop"
    if m.top.visible then onClock()
end sub

sub loadStreams()
    if m.streamsTask <> invalid and m.streamsTask.state = "run" then return
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "liveStreams" }
    task.observeField("response", "onStreams")
    task.control = "RUN"
    m.streamsTask = task
end sub

sub onStreams(event as object)
    r = event.getData()
    status = invalid
    if r.ok then status = r.status
    m.streamStatus = status
    m.strip.focusable = status <> invalid and status.legacy <> true and status.streams.count() > 0
    hadFocus = m.strip.isInFocusChain()
    if status = invalid or status.legacy = true then
        m.strip.status = {}
        m.strip.visible = false
    else
        m.strip.status = status
        m.strip.visible = true
    end if
    layout()
    paintPreview()
    if hadFocus and (not m.strip.visible or not m.strip.focusable) then
        m.controls.setFocus(true)
    end if
end sub

' Controls at 140; the streams strip (when in use) and the 112 px preview
' below; the grid fills the rest of the screen.
sub layout()
    y = 224
    if m.showGuide then y = 296
    m.strip.translation = [96, y]
    if m.strip.visible then y = y + Int(m.strip.height) + 24
    if not m.showGuide then
        m.sports.translation = [0, 0]
        offset = 0
        if m.sports.visible then offset = Int(m.sports.height) + 14
        m.onNow.translation = [0, offset]
        if m.onNow.isInFocusChain() and y + offset + m.onNow.height > 1050 then
            y = 1050 - offset - m.onNow.height
        end if
        m.browse.translation = [0, y]
        return
    end if
    m.preview.translation = [96, y]
    y = y + 112 + 16
    m.grid.translation = [96, y]
    rows = Int((1040 - y - 46 + 10) / 118)
    if rows < 2 then rows = 2
    if m.grid.rowCount <> rows then m.grid.rowCount = rows
end sub

sub onJoin(event as object)
    stream = event.getData()
    if stream = invalid or stream.channelId = invalid then return
    m.top.navigate = { to: "player", id: stream.channelId, live: true }
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" and m.showGuide and m.dialog = invalid then
        showMode(false)
        return true
    end if
    if key = "down" and m.modes.isInFocusChain() then
        if m.showGuide then
            m.controls.setFocus(true)
        else if m.strip.visible and m.strip.focusable then
            m.strip.setFocus(true)
        else if m.sports.visible then
            m.sports.setFocus(true)
        else if m.onNow.visible then
            m.onNow.setFocus(true)
        end if
        layout()
        return true
    end if
    if not m.showGuide then
        if key = "up" and m.onNow.isInFocusChain() and m.sports.visible then
            m.sports.setFocus(true)
        else if key = "up" and (m.sports.isInFocusChain() or m.onNow.isInFocusChain()) and m.strip.visible and m.strip.focusable then
            m.strip.setFocus(true)
        else if key = "up" and (m.strip.isInFocusChain() or m.sports.isInFocusChain() or m.onNow.isInFocusChain()) then
            m.modes.setFocus(true)
        else if key = "down" and m.strip.isInFocusChain() and m.sports.visible then
            m.sports.setFocus(true)
        else if key = "down" and (m.strip.isInFocusChain() or m.sports.isInFocusChain()) and m.onNow.visible then
            m.onNow.setFocus(true)
        else
            return false
        end if
        layout()
        return true
    end if
    if key = "up" and m.controls.isInFocusChain() then
        m.modes.setFocus(true)
        return true
    end if
    if key = "up" and m.grid.isInFocusChain() then
        if m.strip.visible and m.strip.focusable then m.strip.setFocus(true) else m.controls.setFocus(true)
        return true
    end if
    if key = "up" and m.strip.isInFocusChain() then
        m.controls.setFocus(true)
        return true
    end if
    if key = "down" and m.controls.isInFocusChain() then
        if m.strip.visible and m.strip.focusable then
            m.strip.setFocus(true)
        else if m.grid.visible then
            m.grid.setFocus(true)
        end if
        return true
    end if
    if key = "down" and m.strip.isInFocusChain() and m.grid.visible then
        m.grid.setFocus(true)
        return true
    end if
    if (key = "rewind" or key = "fastforward") and not m.grid.isInFocusChain() and m.dialog = invalid then
        if key = "rewind" then shiftWindow(-1) else shiftWindow(1)
        return true
    end if
    return false
end function
