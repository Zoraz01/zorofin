sub init()
    m.top.findNode("title").font = ZFont(32, "bold")
    m.top.findNode("intro").font = ZFont(22)
    m.top.findNode("status").font = ZFont(22)
    m.code = m.top.findNode("code")
    m.authorize = m.top.findNode("authorize")
    s = m.global.session
    m.top.findNode("intro").text = "Enter the Quick Connect code shown on your other device. Authorizing it signs that device into " + ZStr(s.userName) + "’s account."
    m.code.observeField("selected", "editCode")
    m.authorize.observeField("selected", "authorize")
    m.busy = false
    paint()
end sub

function Valid() as boolean
    re = CreateObject("roRegex", "^[0-9]{6}$", "")
    return re.IsMatch(m.code.value)
end function

sub paint()
    text = "Authorize"
    if m.busy then text = "Authorizing…"
    m.authorize.buttons = [{ id: "authorize", text: text, style: "primary", width: 720, disabled: not Valid() or m.busy }]
end sub

sub restoreFocus()
    m.code.setFocus(true)
end sub

sub editCode()
    entry = CreateObject("roSGNode", "TextEntry")
    entry.title = "Quick Connect code"
    entry.message = "Type the six digits shown on your other device."
    entry.text = m.code.value
    entry.observeField("result", "onEntry")
    m.entry = entry
    m.top.modal = true
    m.top.appendChild(entry)
    entry.focusIn = true
end sub

sub onEntry(event as object)
    r = event.getData()
    m.top.removeChild(m.entry)
    m.entry = invalid
    m.top.modal = false
    if r.ok then m.code.value = Left(r.text.trim(), 6)
    paint()
    if Valid() then m.authorize.setFocus(true) else m.code.setFocus(true)
end sub

sub authorize()
    if not Valid() or m.busy then return
    m.busy = true
    m.top.findNode("status").text = ""
    paint()
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "authorizeQuickConnect", code: m.code.value }
    task.observeField("response", "onAuthorized")
    task.control = "RUN"
    m.task = task
end sub

sub onAuthorized(event as object)
    r = event.getData()
    m.busy = false
    status = m.top.findNode("status")
    if r.ok and r.accepted then
        status.text = "Device authorized. You can continue on your other device."
        m.code.value = ""
    else if r.ok then
        status.text = "That code could not be authorized. Check the code on your other device."
    else
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        status.text = "Authorization could not be confirmed. Check your other device before trying again."
    end if
    paint()
    m.code.setFocus(true)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "down" and m.code.isInFocusChain() then
        m.authorize.setFocus(true)
        return true
    else if key = "up" and m.authorize.isInFocusChain() then
        m.code.setFocus(true)
        return true
    end if
    return false
end function
