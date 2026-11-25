sub init()
    m.page = m.top.findNode("page")
    m.page.id = "page"
    ZPageInit(m.page, 140)
    m.poll = m.top.findNode("poll")
    m.poll.observeField("fire", "onPoll")
    m.task = invalid
    m.error = ""
    m.busy = false
    m.selected = ""
    ' The TV's group survives leaving this screen, like Apple TV: phones keep
    ' swiping until the host ends it.
    if m.global.hasField("pickSession") then m.session = m.global.pickSession else m.session = invalid
    m.top.observeField("visible", "onVisible")
    build()
    if m.session <> invalid then refresh()
end sub

sub onVisible()
    if m.top.visible then
        if m.session <> invalid then refresh()
    else
        m.poll.control = "stop"
    end if
end sub

sub ptKeep(session as dynamic)
    m.session = session
    if not m.global.hasField("pickSession") then m.global.addFields({ pickSession: invalid })
    m.global.pickSession = session
end sub

sub pickCall(request as object)
    if m.task <> invalid then return
    request.cmd = "pick"
    if m.session <> invalid then
        if request.id = invalid then request.id = m.session.id
        if request.seat = invalid then request.seat = m.session.seat
    end if
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = request
    task.observeField("response", "onResponse")
    task.control = "RUN"
    m.task = task
end sub

sub refresh()
    if m.session = invalid then return
    pickCall({ action: "state", since: m.session.version })
end sub

sub onPoll()
    if m.top.visible then refresh()
end sub

sub onResponse(event as object)
    r = event.getData()
    m.task = invalid
    m.busy = false
    if r = invalid or not r.ok then
        m.error = "Couldn't reach Pick Together. Try again."
    else if r.failed <> invalid then
        m.error = r.failed.text
        if r.failed.ended then ptKeep(invalid)
    else if r.session <> invalid then
        s = r.session
        if m.session = invalid or m.session.id <> s.id or s.version >= m.session.version then
            if m.session <> invalid and m.session.id = s.id and m.session.seat <> "" then s.seat = m.session.seat
            ptKeep(s)
        end if
        m.error = ""
    end if
    build()
    m.poll.control = "stop"
    if m.session <> invalid and m.session.status <> "ended" and m.session.status <> "failed" and m.top.visible then m.poll.control = "start"
end sub

function ptLabel(text as string, size as integer, weight = "regular" as string, muted = false as boolean, width = 0 as integer) as object
    l = CreateObject("roSGNode", "Label")
    l.font = ZFont(size, weight)
    if muted then l.color = ZTheme().muted else l.color = ZTheme().text
    l.text = text
    if width > 0 then
        l.width = width
        l.wrap = true
        l.maxLines = 3
    end if
    return l
end function

function ptStack(items as object, x = 96 as integer) as object
    g = CreateObject("roSGNode", "Group")
    g.translation = [x, 0]
    y = 0
    for each it in items
        it.node.translation = [0, y]
        g.appendChild(it.node)
        y = y + it.height
    end for
    return { node: g, height: y }
end function

function ptButtons(list as object) as object
    bar = CreateObject("roSGNode", "ButtonBar")
    bar.align = "left"
    bar.buttonHeight = 60
    bar.spacing = 16
    bar.translation = [96, 0]
    bar.buttons = list
    bar.observeField("selected", "onButton")
    return bar
end function

sub build()
    hadFocus = m.top.isInFocusChain()
    m.page.removeChildrenIndex(m.page.getChildCount(), 0)
    sections = []
    s = m.session
    if s = invalid then
        head = ptStack([
            { node: ptLabel("Pick Together", 26, "semibold"), height: 44 },
            { node: ptLabel("What are we watching?", 60, "bold"), height: 90 },
            { node: ptLabel("Everyone swipes on their own phone. Matches show up here, and Play starts the pick on this TV.", 26, "regular", true, 1300), height: 90 }
        ])
        m.page.appendChild(head.node)
        sections.push({ id: "head", node: head.node, focus: invalid, height: head.height })
        bar = ptButtons([{ id: "create:movie", text: "Movies", primary: true }, { id: "create:series", text: "Shows" }])
        m.page.appendChild(bar)
        sections.push({ id: "kinds", node: bar, focus: bar, height: 64 })
    else if s.status = "lobby" or s.status = "preparing" then
        items = [
            { node: ptLabel("Pick Together · " + ZPickKindLabel(s.kind), 24, "regular", true), height: 40 },
            { node: ptLabel("Grab your phones.", 60, "bold"), height: 86 },
            { node: ptLabel("Scan the QR code or enter the code in Pick Together on your phone. Everyone swipes on their own phone, and matches show up here.", 24, "regular", true, 1300), height: 80 },
            { node: ptLabel("Group code", 24, "regular", true), height: 36 },
            { node: ptLabel(ZPickSpaced(s.code), 88, "bold"), height: 120 },
            { node: ptLabel("Joined · " + ZStr(s.voters), 24, "regular", true), height: 42 }
        ]
        if s.members.count() = 0 then items.push({ node: ptLabel("Waiting for the first phone…", 26, "regular", true), height: 42 })
        for each mem in s.members
            role = "Ready"
            if mem.host then role = "Host"
            items.push({ node: ptLabel(mem.name + "  ·  " + role, 28, "semibold"), height: 46 })
        end for
        if s.status = "preparing" then items.push({ node: ptLabel("Finding titles for everyone…", 24, "regular", true), height: 40 })
        head = ptStack(items)
        link = ZEndpoint(ZStr(m.global.session.server), ["web"]) + "/#/home?zorofin=catchup&pick=" + s.code
        if ZPickCode(s.code) = s.code and Len(link) <= 192 then
            if m.inviteQr = invalid or m.inviteLink <> link then
                m.inviteQr = CreateObject("roSGNode", "QRCode")
                m.inviteQr.width = 300
                m.inviteQr.height = 300
                m.inviteQr.pixel = 5
                m.inviteQr.mask = 0
                m.inviteQr.ecl = "MEDIUM"
                m.inviteQr.text = link
                m.inviteLink = link
            end if
            m.inviteQr.translation = [1350, 58]
            head.node.appendChild(m.inviteQr)
        end if
        m.page.appendChild(head.node)
        sections.push({ id: "head", node: head.node, focus: invalid, height: head.height })
        list = []
        if s.host then list.push({ id: "start", text: "Start swiping", primary: true, disabled: not s.canStart })
        list.push({ id: "cancel", text: "Cancel" })
        bar = ptButtons(list)
        m.page.appendChild(bar)
        sections.push({ id: "actions", node: bar, focus: bar, height: 64 })
        hint = "The TV shows the group. It never swipes."
        if s.voters < 2 then hint = "Start unlocks when two people have joined. The TV never swipes."
        note = ptStack([{ node: ptLabel(hint, 22, "regular", true), height: 34 }])
        m.page.appendChild(note.node)
        sections.push({ id: "hint", node: note.node, focus: invalid, height: note.height })
    else
        items = [
            { node: ptLabel("Pick Together · " + ZPickKindLabel(s.kind) + " · code " + ZPickSpaced(s.code), 22, "regular", true), height: 36 },
            { node: ptLabel(ZPickTitle(s), 54, "bold"), height: 80 }
        ]
        for each mem in s.members
            line = mem.name + " · " + ZStr(mem.swiped) + "/" + ZStr(mem.total)
            if mem.done then line = line + " · done"
            items.push({ node: ptLabel(line, 22), height: 34 })
        end for
        title = "Matches show up here when everyone likes the same title"
        if s.matches.count() > 0 then title = "Matches · everyone liked"
        items.push({ node: ptLabel(title, 24, "semibold"), height: 40 })
        head = ptStack(items)
        m.page.appendChild(head.node)
        sections.push({ id: "head", node: head.node, focus: invalid, height: head.height })
        if s.matches.count() > 0 or s.almost.count() > 0 then
            row = CreateObject("roSGNode", "ContentNode")
            row.title = ""
            base = ZStr(m.global.session.server)
            for each card in s.matches
                node = ZItemNode(ZPickItemJson(card), base)
                node.caption = card.tally + " liked"
                row.appendChild(node)
            end for
            for each card in s.almost
                node = ZItemNode(ZPickItemJson(card), base)
                node.caption = "Almost · " + card.tally
                row.appendChild(node)
            end for
            shelf = CreateObject("roSGNode", "Shelf")
            shelf.content = row
            shelf.observeField("itemSelected", "onMatchSelected")
            shelf.observeField("itemFocused", "onMatchFocused")
            m.page.appendChild(shelf)
            sections.push({ id: "matches", node: shelf, focus: shelf, height: shelf.height })
        end if
        list = []
        chosen = invalid
        for each card in s.matches
            if chosen = invalid or card.itemId = m.selected then chosen = card
        end for
        if chosen <> invalid then list.push({ id: "play", text: "Play " + chosen.title, primary: true })
        over = s.status = "ended" or s.status = "failed"
        if s.host and not over then list.push({ id: "again", text: "Another round", disabled: s.status <> "swiping" and s.status <> "empty" })
        if over then list.push({ id: "done", text: "Done" }) else list.push({ id: "end", text: "End" })
        bar = ptButtons(list)
        m.page.appendChild(bar)
        sections.push({ id: "actions", node: bar, focus: bar, height: 64 })
    end if
    if m.error <> "" then
        err = ptStack([{ node: ptLabel(m.error, 22, "regular", true), height: 34 }])
        m.page.appendChild(err.node)
        sections.push({ id: "error", node: err.node, focus: invalid, height: err.height })
    end if
    ZPageSet(sections)
    if hadFocus or m.pageIndex < 0 then restoreFocus()
end sub

sub onButton(event as object)
    id = event.getData()
    if m.busy then return
    if Left(id, 7) = "create:" then
        m.busy = true
        pickCall({ action: "create", kind: Mid(id, 8), id: "", seat: "" })
    else if id = "start" then
        m.busy = true
        pickCall({ action: "start" })
    else if id = "again" then
        m.busy = true
        pickCall({ action: "next-round" })
    else if id = "end" or id = "cancel" then
        if m.session <> invalid then pickCall({ action: "end" })
        ptKeep(invalid)
        build()
        if id = "cancel" then m.top.navigate = { to: "back" }
    else if id = "done" then
        ptKeep(invalid)
        build()
    else if id = "play" then
        playSelected()
    end if
end sub

sub onMatchFocused(event as object)
    item = event.getData()
    if item <> invalid then m.selected = item.id
end sub

sub onMatchSelected(event as object)
    item = event.getData()
    if item = invalid then return
    m.selected = item.id
    playSelected()
end sub

' A matched movie plays here; a show opens its details to pick an episode.
sub playSelected()
    if m.session = invalid then return
    chosen = invalid
    for each card in m.session.matches
        if chosen = invalid or card.itemId = m.selected then chosen = card
    end for
    if chosen = invalid then return
    m.top.navigate = { to: "detail", id: chosen.itemId, autoplay: chosen.type = "Movie" }
end sub

sub restoreFocus()
    if m.pageSections.count() = 0 then return
    index = m.pageIndex
    if not ZPageFocusable(index) then
        index = 0
        while index < m.pageSections.count() and not ZPageFocusable(index)
            index = index + 1
        end while
    end if
    ZPageFocus(index, false)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "down" then return ZPageMove(1)
    if key = "up" then return ZPageMove(-1)
    return false
end function
