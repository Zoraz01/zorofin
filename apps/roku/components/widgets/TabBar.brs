' Header metrics from the Apple TV app: 60 px controls, 22 pt semibold tab
' labels with 20 px padding, 18 px between controls.
function HeaderTop() as integer
    return 40
end function

sub init()
    m.global.observeField("settings", "paintBadge")
    m.top.focusable = true
    m.tabs = m.top.findNode("tabs")
    m.tools = m.top.findNode("tools")
    m.focusIndex = 0
    m.items = []
    m.badge = invalid
    m.top.observeField("focusedChild", "onFocusChange")
    m.hadFocus = false
    build()
end sub

sub build()
    entries = [
        { id: "home", text: "Home" },
        { id: "movies", text: "Movies" },
        { id: "shows", text: "TV Shows" }
    ]
    if m.top.showLive then entries.push({ id: "live", text: "Live TV" })
    if m.top.showRequests then entries.push({ id: "requests", text: "Requests" })
    m.tabs.removeChildrenIndex(m.tabs.getChildCount(), 0)
    m.tools.removeChildrenIndex(m.tools.getChildCount(), 0)
    m.items = []
    m.badge = invalid
    top = HeaderTop()
    x = 96 + 48 + 30
    font = ZFont(22, "semibold")
    for each e in entries
        w = ZTextWidth(e.text, font) + 40
        g = CreateObject("roSGNode", "Group")
        g.translation = [x, top]
        g.scaleRotateCenter = [w / 2, 30]
        ring = ZPoster("pkg:/images/pill_ring.9.png", w + 12, 72, -6, -6)
        ring.blendColor = ZTheme().jade
        ring.visible = false
        bg = ZPoster("pkg:/images/pill.9.png", w, 60, 0, 0)
        label = CreateObject("roSGNode", "Label")
        label.text = e.text
        label.font = font
        label.width = w
        label.height = 60
        label.horizAlign = "center"
        label.vertAlign = "center"
        g.appendChild(ring)
        g.appendChild(bg)
        g.appendChild(label)
        m.tabs.appendChild(g)
        m.items.push({ id: e.id, kind: "tab", group: g, ring: ring, bg: bg, label: label })
        x = x + w + 18
    end for

    ' Right side, laid out from the right edge: Search, Notifications, Support, avatar.
    tools = [{ id: "search", icon: "search" }]
    if m.top.showNotifications then tools.unshift({ id: "notifications", icon: "bell" })
    if m.top.showSupport then tools.unshift({ id: "support", icon: "support" })
    tools.unshift({ id: "account", icon: "" })
    right = 1824
    placed = []
    for i = tools.count() - 1 to 0 step -1
        t = tools[i]
        size = 60
        if t.id = "account" then size = 64
        right = right - size
        placed.unshift({ tool: t, x: right, size: size })
        right = right - 18
    end for
    for each p in placed
        t = p.tool
        size = p.size
        g = CreateObject("roSGNode", "Group")
        g.translation = [p.x, top + Int((60 - size) / 2)]
        g.scaleRotateCenter = [size / 2, size / 2]
        ring = ZPoster("pkg:/images/circle_ring.png", size + 12, size + 12, -6, -6)
        ring.blendColor = ZTheme().jade
        ring.visible = false
        bg = ZPoster("pkg:/images/circle.png", size, size, 0, 0)
        g.appendChild(ring)
        g.appendChild(bg)
        item = { id: t.id, kind: "tool", group: g, ring: ring, bg: bg }
        if t.id = "account" then
            ' Avatar: initial on the avatar green, replaced by the photo when it loads.
            disc = ZPoster("pkg:/images/circle.png", 48, 48, 8, 8)
            disc.blendColor = ZTheme().avatar
            initial = CreateObject("roSGNode", "Label")
            initial.font = ZFont(25, "semibold")
            initial.color = "0xE6FFEFFF"
            initial.width = 48
            initial.height = 48
            initial.translation = [8, 8]
            initial.horizAlign = "center"
            initial.vertAlign = "center"
            photo = CreateObject("roSGNode", "Poster")
            photo.width = 48
            photo.height = 48
            photo.translation = [8, 8]
            photo.loadDisplayMode = "scaleToZoom"
            mask = ZPoster("pkg:/images/circle_mask.png", 48, 48, 8, 8)
            g.appendChild(disc)
            g.appendChild(initial)
            g.appendChild(photo)
            g.appendChild(mask)
            m.initial = initial
            m.photo = photo
        else
            icon = ZPoster("pkg:/images/icons/" + t.icon + ".png", 30, 30, 15, 15)
            g.appendChild(icon)
            item.icon = icon
            if t.id = "notifications" then
                badge = CreateObject("roSGNode", "Group")
                badge.translation = [34, -4]
                pill = ZPoster("pkg:/images/badge.9.png", 30, 26, 0, 0)
                pill.blendColor = ZTheme().jade
                count = CreateObject("roSGNode", "Label")
                count.font = ZFont(15, "bold")
                count.color = ZTheme().background
                count.height = 26
                count.horizAlign = "center"
                count.vertAlign = "center"
                badge.appendChild(pill)
                badge.appendChild(count)
                g.appendChild(badge)
                m.badge = { group: badge, pill: pill, label: count }
            end if
        end if
        m.tools.appendChild(g)
        m.items.push(item)
    end for
    if m.focusIndex >= m.items.count() then m.focusIndex = 0
    onUser()
    paintBadge()
    paint()
end sub

sub onUser()
    name = m.top.userName
    if m.initial <> invalid and name <> "" then m.initial.text = UCase(Left(name, 1))
    if m.photo <> invalid then m.photo.uri = m.top.userImage
end sub

sub paintBadge()
    if m.badge = invalid then return
    n = m.top.unread
    ' Notification settings > Show unread badge.
    s = m.global.settings
    if s <> invalid and s.showUnreadBadge = false then n = 0
    if n <= 0 then
        m.badge.group.visible = false
        return
    end if
    text = n.toStr()
    if n > 99 then text = "99+"
    w = 26 + (Len(text) - 1) * 9
    m.badge.pill.width = w
    m.badge.label.width = w
    m.badge.label.text = text
    m.badge.group.visible = true
end sub

sub paint()
    focused = m.top.isInFocusChain()
    theme = ZTheme()
    for i = 0 to m.items.count() - 1
        it = m.items[i]
        selected = it.id = m.top.selectedId
        on = focused and i = m.focusIndex
        it.ring.visible = on
        if on then
            it.group.scale = [1.06, 1.06]
        else
            it.group.scale = [1, 1]
        end if
        if it.kind = "tab" then
            if selected then
                it.bg.blendColor = theme.text
                it.label.color = theme.background
            else if on then
                it.bg.blendColor = "0xF5F7F514"
                it.label.color = theme.text
            else
                it.bg.blendColor = "0xF5F7F500"
                it.label.color = theme.muted
            end if
        else
            if on then
                it.bg.blendColor = "0xF5F7F514"
            else if selected then
                it.bg.blendColor = "0xF5F7F51F"
            else
                it.bg.blendColor = "0xF5F7F500"
            end if
            if it.icon <> invalid then
                if on or selected then
                    it.icon.blendColor = theme.text
                else
                    it.icon.blendColor = theme.muted
                end if
            end if
        end if
    end for
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "left" and m.focusIndex > 0 then
        m.focusIndex = m.focusIndex - 1
        paint()
        return true
    else if key = "right" and m.focusIndex < m.items.count() - 1 then
        m.focusIndex = m.focusIndex + 1
        paint()
        return true
    else if key = "OK" then
        m.top.selectedTab = m.items[m.focusIndex].id
        return true
    else if key = "down" then
        m.top.leaveDown = true
        return true
    end if
    return false
end function

' Focus lands on the selected tab, or on the control named by focusId.
sub syncFocus()
    for i = 0 to m.items.count() - 1
        if m.items[i].id = m.top.selectedId then m.focusIndex = i
    end for
    paint()
end sub

sub onFocusId()
    for i = 0 to m.items.count() - 1
        if m.items[i].id = m.top.focusId then m.focusIndex = i
    end for
    paint()
end sub

sub onFocusChange()
    has = m.top.isInFocusChain()
    if has and not m.hadFocus and m.top.focusId = "" then syncFocus()
    if has and not m.hadFocus and m.top.focusId <> "" then
        onFocusId()
        m.top.focusId = ""
    end if
    m.hadFocus = has
    paint()
end sub
