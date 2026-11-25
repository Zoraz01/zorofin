sub init()
    m.keyboard = m.top.findNode("keyboard")
    m.results = m.top.findNode("results")
    m.status = m.top.findNode("status")
    m.status.font = ZFont(24)
    m.top.findNode("heading").font = ZFont(44, "bold")
    m.timer = m.top.findNode("debounce")
    m.timer.observeField("fire", "browse")
    m.keyboard.observeField("text", "onText")
    m.results.observeField("selected", "onSelected")
    m.page = 1
    m.scope = ZNotificationScope(m.global.session)
    m.version = m.global.features.requests
    browse()
end sub

sub requestTask(req as object, callback as string)
    req.scope = m.scope
    req.version = m.version
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = req
    task.observeField("response", callback)
    m.task = task
    task.control = "RUN"
end sub

sub onText()
    m.page = 1
    m.results.rows = []
    m.timer.control = "stop"
    m.timer.control = "start"
end sub

sub browse()
    m.status.text = "Loading…"
    requestTask({ cmd: "requestBrowse", term: m.keyboard.text.trim(), page: m.page }, "onBrowse")
end sub

function currentTask(event as object) as boolean
    return m.task <> invalid and m.task.isSameNode(event.getRoSGNode()) and m.scope = ZNotificationScope(m.global.session)
end function

sub onBrowse(event as object)
    if not currentTask(event) then return
    req = m.task.request
    m.task = invalid
    if req.term <> m.keyboard.text.trim() then return
    r = event.getData()
    rows = []
    if m.page > 1 then rows.push({ id: "prev", title: "Previous page" })
    if r.ok then rows.append(r.rows)
    if r.more = true then rows.push({ id: "next", title: "Next page" })
    m.results.rows = rows
    m.status.text = ZStr(r.message, "Trending")
    if r.ok and req.term <> "" then m.status.text = "Search results"
    if r.ok and r.rows.count() = 0 then m.status.text = "No titles found."
end sub

sub onSelected(event as object)
    if m.task <> invalid or m.dialog <> invalid then return
    id = event.getData()
    if id = "next" or id = "prev" then
        if id = "next" then m.page++ else m.page--
        browse()
        return
    end if
    for each row in m.results.rows
        if row.id = id then
            m.selected = row
            m.status.text = "Checking availability…"
            requestTask({ cmd: "requestChoice", kind: row.kind, mediaId: row.mediaId }, "onChoice")
            return
        end if
    end for
end sub

sub onChoice(event as object)
    if not currentTask(event) then return
    m.task = invalid
    r = event.getData()
    m.status.text = ZStr(r.message, "Requests unavailable.")
    if not r.ok or r.choice = invalid or not m.top.visible or not m.top.isInFocusChain() then return
    m.choice = r.choice
    d = CreateObject("roSGNode", "PickerDialog")
    d.title = m.selected.title
    d.message = r.message
    d.options = [{ id: "cancel", title: "Cancel" }, { id: "submit", title: "Request" }]
    d.observeField("result", "onConfirm")
    m.dialog = d
    m.top.appendChild(d)
    m.top.modal = true
    d.focusIn = true
end sub

sub onConfirm(event as object)
    m.top.removeChild(m.dialog)
    m.dialog = invalid
    m.top.modal = false
    m.results.setFocus(true)
    if event.getData().id = "submit" then
        m.status.text = "Submitting…"
        requestTask({ cmd: "requestChoice", kind: m.selected.kind, mediaId: m.selected.mediaId, confirmed: m.choice }, "onChoice")
    end if
end sub

sub restoreFocus()
    if m.dialog <> invalid then m.dialog.focusIn = true else m.keyboard.setFocus(true)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "options" and m.task = invalid then
        browse()
        return true
    else if key = "right" and m.keyboard.isInFocusChain() and m.results.rows.count() > 0 then
        m.results.setFocus(true)
        return true
    else if key = "left" and m.results.isInFocusChain() then
        m.keyboard.setFocus(true)
        return true
    end if
    return false
end function
