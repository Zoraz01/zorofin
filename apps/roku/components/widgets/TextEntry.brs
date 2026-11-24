sub init()
    m.keyboard = m.top.findNode("keyboard")
    m.actions = m.top.findNode("actions")
    m.top.findNode("titleLabel").font = ZFont(44, "bold")
    m.top.findNode("messageLabel").font = ZFont(26)
    m.keyboard.textEditBox.maxTextLength = 256
    m.actions.observeField("selected", "onAction")
    onDoneText()
end sub

sub onTitle()
    m.top.findNode("titleLabel").text = m.top.title
    m.top.findNode("messageLabel").text = m.top.message
end sub

sub onText()
    m.keyboard.text = m.top.text
    m.keyboard.textEditBox.cursorPosition = Len(m.top.text)
end sub

sub onSecure()
    m.keyboard.textEditBox.secureMode = m.top.secure
end sub

sub onDoneText()
    m.actions.buttons = [{ id: "done", text: m.top.doneText, primary: true }, { id: "cancel", text: "Cancel" }]
    m.actions.translation = [(1920 - m.actions.totalWidth) / 2, 880]
end sub

sub takeFocus()
    m.keyboard.setFocus(true)
end sub

sub onAction(event as object)
    if event.getData() = "done" then
        m.top.result = { ok: true, text: m.keyboard.text }
    else
        m.top.result = { ok: false, text: m.top.text }
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "down" and m.keyboard.isInFocusChain() then
        m.actions.setFocus(true)
        return true
    else if key = "up" and m.actions.isInFocusChain() then
        m.keyboard.setFocus(true)
        return true
    else if key = "back" then
        m.top.result = { ok: false, text: m.top.text }
        return true
    else if key = "play" then
        m.top.result = { ok: true, text: m.keyboard.text }
        return true
    end if
    ' The entry is modal: keys never reach the screen underneath.
    return true
end function
