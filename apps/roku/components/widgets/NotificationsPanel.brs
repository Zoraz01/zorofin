sub init()
    m.list = m.top.findNode("list")
    m.status = m.top.findNode("status")
    m.top.findNode("heading").font = ZFont(28, "bold")
    m.status.font = ZFont(19)
    m.rows = []
    m.focus = 0
    m.showHidden = false
    m.replies = []
    m.seenTimer = m.top.findNode("seenTimer")
    m.seenTimer.observeField("fire", "markSeen")
    m.status.text = "Loading…"
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "supportReplies" }
    task.observeField("response", "onReplies")
    task.control = "RUN"
    m.task = task
end sub

sub onReplies(event as object)
    r = event.getData()
    if not r.ok then
        m.status.text = "Couldn't refresh. Press OK to try again."
        m.retry = true
        return
    end if
    m.retry = false
    m.replies = r.replies
    seen = ZSeenReplies()
    m.fresh = []
    m.old = []
    for each reply in r.replies
        if seen[ZReplyKey(reply)] = true then m.old.push(reply) else m.fresh.push(reply)
    end for
    build()
    if m.fresh.count() > 0 then m.seenTimer.control = "start"
end sub

sub markSeen()
    ZMarkRepliesSeen(m.fresh)
    m.top.action = { type: "unread", count: 0 }
end sub

sub build()
    m.list.removeChildrenIndex(m.list.getChildCount(), 0)
    m.rows = []
    theme = ZTheme()
    y = 0
    if m.fresh.count() = 0 then
        m.status.text = ""
        title = CreateObject("roSGNode", "Label")
        title.font = ZFont(23, "semibold")
        title.color = theme.text
        title.text = "You're all caught up"
        title.translation = [8, y + 12]
        detail = CreateObject("roSGNode", "Label")
        detail.font = ZFont(19)
        detail.color = theme.muted
        detail.text = "New updates will appear here."
        detail.translation = [8, y + 48]
        m.list.appendChild(title)
        m.list.appendChild(detail)
        y = y + 96
    else
        m.status.text = ""
    end if
    for each reply in m.fresh
        y = addReply(reply, y)
    end for
    if m.old.count() > 0 then
        g = CreateObject("roSGNode", "Group")
        g.translation = [0, y]
        bg = ZPoster("pkg:/images/option.9.png", 524, 52)
        ring = ZPoster("pkg:/images/option_ring.9.png", 524, 52)
        ring.blendColor = theme.jade
        label = CreateObject("roSGNode", "Label")
        label.font = ZFont(21, "semibold")
        label.color = theme.muted
        label.text = "Hidden (" + m.old.count().toStr() + ")"
        label.translation = [14, 0]
        label.height = 52
        label.vertAlign = "center"
        chevron = "chevron-down"
        if m.showHidden then chevron = "chevron-up"
        icon = ZPoster("pkg:/images/icons/chevron-down.png", 22, 22, 488, 15)
        icon.blendColor = theme.muted
        g.appendChild(bg)
        g.appendChild(ring)
        g.appendChild(label)
        g.appendChild(icon)
        m.list.appendChild(g)
        m.rows.push({ kind: "hidden", group: g, bg: bg, ring: ring, top: y, height: 52 })
        y = y + 60
        if m.showHidden then
            for each reply in m.old
                y = addReply(reply, y)
            end for
        end if
    end if
    if m.focus >= m.rows.count() then m.focus = m.rows.count() - 1
    if m.focus < 0 then m.focus = 0
    paint()
end sub

' Apple NotificationReplyRow: "Support reply", the title or issue, the message.
function addReply(reply as object, y as integer) as integer
    theme = ZTheme()
    expanded = m.expanded <> invalid and m.expanded[reply.id + reply.updatedAt] = true
    g = CreateObject("roSGNode", "Group")
    g.translation = [0, y]
    label = CreateObject("roSGNode", "Label")
    label.font = ZFont(20)
    label.color = theme.jade
    label.text = "Support reply"
    label.translation = [44, 12]
    icon = ZPoster("pkg:/images/icons/support.png", 22, 22, 14, 14)
    icon.blendColor = theme.jade
    title = CreateObject("roSGNode", "Label")
    title.font = ZFont(20, "semibold")
    title.color = theme.text
    heading = reply.affectedMedia
    if heading = "" then heading = reply.issueType
    title.text = heading
    title.width = 496
    title.maxLines = 2
    title.wrap = true
    title.translation = [14, 44]
    message = CreateObject("roSGNode", "Label")
    message.font = ZFont(20)
    message.color = theme.muted
    message.text = reply.message
    message.width = 496
    message.wrap = true
    message.maxLines = 3
    if expanded then message.maxLines = 12
    titleH = 28
    if ZTextWidth(heading, title.font) > 496 then titleH = 54
    message.translation = [14, 44 + titleH + 6]
    lines = Int(ZTextWidth(reply.message, message.font) / 470) + 1
    if lines > message.maxLines then lines = message.maxLines
    h = 44 + titleH + 6 + lines * 26 + 14
    if expanded then
        ref = CreateObject("roSGNode", "Label")
        ref.font = ZFont(18)
        ref.color = theme.muted
        ref.text = "Reference: " + reply.id
        ref.translation = [14, h - 6]
        h = h + 30
    end if
    bg = ZPoster("pkg:/images/option.9.png", 524, h)
    ring = ZPoster("pkg:/images/option_ring.9.png", 524, h)
    ring.blendColor = theme.jade
    g.appendChild(bg)
    g.appendChild(ring)
    g.appendChild(icon)
    g.appendChild(label)
    g.appendChild(title)
    g.appendChild(message)
    if expanded then g.appendChild(ref)
    m.list.appendChild(g)
    m.rows.push({ kind: "reply", reply: reply, group: g, bg: bg, ring: ring, top: y, height: h })
    return y + h + 8
end function

sub paint()
    for i = 0 to m.rows.count() - 1
        r = m.rows[i]
        on = i = m.focus and m.top.isInFocusChain()
        r.ring.visible = on
        if on then
            r.bg.blendColor = "0xF5F7F517"
        else if r.kind = "reply" then
            r.bg.blendColor = "0x11151373"
        else
            r.bg.blendColor = "0xF5F7F500"
        end if
    end for
    ' Keep the focused row inside the 553 px viewport.
    if m.focus < m.rows.count() then
        r = m.rows[m.focus]
        offset = 114 - m.list.translation[1]
        if r.top < offset then offset = r.top
        if r.top + r.height > offset + 520 then offset = r.top + r.height - 520
        m.list.translation = [18, 114 - offset]
    end if
end sub

sub takeFocus()
    m.top.setFocus(true)
    paint()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" or key = "options" then
        m.top.action = { type: "close" }
        return true
    else if key = "down" and m.focus < m.rows.count() - 1 then
        m.focus = m.focus + 1
        paint()
    else if key = "up" and m.focus > 0 then
        m.focus = m.focus - 1
        paint()
    else if key = "OK" then
        if m.retry = true then
            init()
            return true
        end if
        if m.focus < m.rows.count() then
            r = m.rows[m.focus]
            if r.kind = "hidden" then
                m.showHidden = not m.showHidden
            else
                if m.expanded = invalid then m.expanded = {}
                k = r.reply.id + r.reply.updatedAt
                m.expanded[k] = not (m.expanded[k] = true)
            end if
            build()
        end if
    end if
    ' The popover is modal.
    return true
end function
