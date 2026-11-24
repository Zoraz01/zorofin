sub init()
    m.top.findNode("title").font = ZFont(40, "bold")
    m.top.findNode("message").font = ZFont(27)
    m.buttons = m.top.findNode("buttons")
    m.buttons.observeField("selected", "onSelected")
end sub

sub onAlert()
    a = m.top.alert
    if a = invalid then return
    title = m.top.findNode("title")
    message = m.top.findNode("message")
    title.text = ZStr(a.title)
    message.text = ZStr(a.message)
    buttons = a.buttons
    if not ZIsArray(buttons) or buttons.count() = 0 then buttons = [{ id: "ok", text: "OK", primary: true }]
    m.buttons.buttons = buttons
    ' Size the panel to the message, then centre everything on screen.
    lines = message.localBoundingRect().height
    if lines < 40 then lines = 40
    height = 70 + 50 + lines + 50 + 76 + 50
    top = Int((1080 - height) / 2)
    panel = m.top.findNode("panel")
    panel.height = height
    panel.translation = [460, top]
    title.translation = [520, top + 50]
    message.translation = [520, top + 120]
    m.buttons.translation = [(1920 - m.buttons.totalWidth) / 2, top + 120 + lines + 50]
end sub

sub takeFocus()
    m.buttons.setFocus(true)
end sub

sub onSelected(event as object)
    m.top.result = event.getData()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return true
    if key = "back" then
        m.top.result = "cancel"
    end if
    ' Modal: nothing reaches the screen underneath.
    return true
end function
