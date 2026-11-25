sub init()
    m.top.focusable = true
    m.top.findNode("heading").font = ZFont(48, "bold")
    m.top.findNode("filterLabel").font = ZFont(22)
    m.top.findNode("count").font = ZFont(22)
    m.top.findNode("title").font = ZFont(48, "bold")
    m.top.findNode("overview").font = ZFont(22)
    m.top.findNode("statusTitle").font = ZFont(30, "semibold")
    m.top.findNode("statusDetail").font = ZFont(22)
    m.card = m.top.findNode("card")
    m.art = m.top.findNode("art")
    m.logo = m.top.findNode("logo")
    m.queue = []
    m.index = 0
    m.kinds = "Movie,Series"
    m.busy = false
    m.dialog = invalid
    drawKeys()
    load()
end sub

function KindName() as string
    if m.kinds = "Movie" then return "Movies"
    if m.kinds = "Series" then return "Shows"
    return "Everything"
end function

sub load()
    m.top.findNode("filterLabel").text = KindName() + "  ·  press * for options"
    m.card.visible = false
    m.top.findNode("keys").visible = false
    m.top.findNode("count").text = ""
    showStatus("Finding something to watch…", "")
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "catchUp", kinds: m.kinds, skips: ZCatchUpSkips() }
    task.observeField("response", "onItems")
    task.control = "RUN"
    m.task = task
end sub

sub showStatus(title as string, detail as string)
    m.top.findNode("statusTitle").text = title
    m.top.findNode("statusDetail").text = detail
    m.top.findNode("statusGroup").visible = title <> ""
end sub

sub onItems(event as object)
    if m.task = invalid or not m.task.isSameNode(event.getRoSGNode()) then return
    r = event.getData()
    content = m.task.content
    m.task = invalid
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        showStatus("Couldn't load titles", "Try again in a moment.")
        return
    end if
    m.queue = []
    if content <> invalid then
        for i = 0 to content.getChildCount() - 1
            m.queue.push(content.getChild(i))
        end for
    end if
    m.index = 0
    m.canLike = r.canLike = true
    drawKeys()
    draw()
end sub

' The hints under the card: the remote's arrows are the choices.
sub drawKeys()
    keys = m.top.findNode("keys")
    font = ZFont(22, "semibold")
    x = 0
    keys.removeChildrenIndex(keys.getChildCount(), 0)
    choices = [["←", "Skip", false], ["OK", "View details", false]]
    if m.canLike = true then choices.push(["→", "Like", true])
    for each k in choices
        text = k[0] + "   " + k[1]
        w = ZTextWidth(text, font) + 40
        pill = ZPoster("pkg:/images/pill.9.png", w, 56, x, 0)
        label = CreateObject("roSGNode", "Label")
        label.font = font
        label.text = text
        label.width = w
        label.height = 56
        label.horizAlign = "center"
        label.vertAlign = "center"
        label.translation = [x, 0]
        if k[2] then
            pill.blendColor = ZAccent()
            label.color = ZTheme().background
        else
            pill.blendColor = "0xFFFFFF26"
            label.color = ZTheme().text
        end if
        keys.appendChild(pill)
        keys.appendChild(label)
        x = x + w + 16
    end for
end sub

sub draw()
    if m.index >= m.queue.count() then
        m.card.visible = false
        m.top.findNode("keys").visible = false
        m.top.findNode("count").text = ""
        m.art.uri = ""
        m.logo.uri = ""
        showStatus("You're all caught up", "No more titles here. Press * to try another filter or to show skipped titles again.")
        return
    end if
    showStatus("", "")
    item = m.queue[m.index]
    m.art.uri = ZStr(item.backdropUrl)
    title = m.top.findNode("title")
    title.text = item.title
    hasLogo = ZStr(item.logoUrl) <> ""
    m.logo.uri = ZStr(item.logoUrl)
    m.logo.visible = hasLogo
    title.visible = not hasLogo
    y = 0
    if hasLogo then y = 176 else y = Int(title.boundingRect().height) + 16
    meta = m.top.findNode("meta")
    meta.translation = [0, y]
    ZMetadataLine(meta, item)
    extra = []
    if item.caption <> "" then extra.push(item.caption)
    if item.communityRating > 0 then extra.push("★ " + ZRating(item.communityRating))
    if extra.count() > 0 then
        font = ZFont(22, "semibold")
        x = 0
        for i = 0 to meta.getChildCount() - 1
            child = meta.getChild(i)
            r = child.boundingRect()
            if r.x + r.width > x then x = r.x + r.width
        end for
        label = CreateObject("roSGNode", "Label")
        label.font = font
        label.color = ZTheme().muted
        label.height = 32
        label.vertAlign = "center"
        label.text = ZJoin(extra, "  ·  ")
        if x > 0 then x = x + 16
        label.translation = [x, 0]
        meta.appendChild(label)
    end if
    overview = m.top.findNode("overview")
    overview.text = item.description
    overview.translation = [0, y + 56]
    m.top.findNode("count").text = (m.index + 1).toStr() + " of " + m.queue.count().toStr()
    m.card.visible = true
    m.top.findNode("keys").visible = true
end sub

sub act(action as string)
    if m.busy or m.index >= m.queue.count() then return
    if action = "like" and m.canLike <> true then return
    item = m.queue[m.index]
    if action = "detail" then
        m.top.navigate = { to: "detail", id: item.id }
        return
    end if
    if action = "skip" then
        ZSaveCatchUpSkips(ZCatchUpSkip(ZCatchUpSkips(), item.id))
        logChoice(item.id, action)
        advance()
        return
    end if
    m.busy = true
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "catchUpAct", id: item.id, action: action }
    task.observeField("response", "onActed")
    task.control = "RUN"
    m.actTask = task
end sub

sub logChoice(id as string, action as string)
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "catchUpAct", id: id, action: action }
    task.control = "RUN"
    m.logTask = task
end sub

sub onActed(event as object)
    r = event.getData()
    m.busy = false
    if r <> invalid and r.ok then
        m.top.toast = "Liked"
    else
        m.top.toast = "Couldn't save that. Try again."
        return
    end if
    advance()
end sub

sub advance()
    m.index = m.index + 1
    draw()
end sub

sub showOptions()
    d = CreateObject("roSGNode", "PickerDialog")
    d.title = "Catch Up"
    d.message = "Choose what to show."
    d.options = [
        { id: "Movie,Series", title: "Everything", checked: m.kinds = "Movie,Series" },
        { id: "Movie", title: "Movies", checked: m.kinds = "Movie" },
        { id: "Series", title: "Shows", checked: m.kinds = "Series" },
        { id: "reset", title: "Show skipped titles again" }
    ]
    d.observeField("result", "onOptions")
    m.top.appendChild(d)
    m.dialog = d
    m.top.modal = true
    d.focusIn = true
end sub

sub onOptions(event as object)
    r = event.getData()
    m.top.removeChild(m.dialog)
    m.dialog = invalid
    m.top.modal = false
    m.top.setFocus(true)
    if r = invalid or r.id = invalid then return
    if r.id = "reset" then
        ZSaveCatchUpSkips([])
    else
        m.kinds = r.id
    end if
    load()
end sub

sub restoreFocus()
    if m.dialog <> invalid then
        m.dialog.focusIn = true
    else
        m.top.setFocus(true)
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "options" then
        showOptions()
        return true
    end if
    if m.index >= m.queue.count() or not m.card.visible then return false
    action = ZCatchUpKeyAction(key)
    if action <> "" then
        act(action)
        return true
    end if
    return false
end function
