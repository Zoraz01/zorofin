sub init()
    m.top.findNode("ring").blendColor = ZAccent()
    m.top.focusable = true
    m.bg = m.top.findNode("bg")
    m.ring = m.top.findNode("ring")
    m.caption = m.top.findNode("caption")
    m.text = m.top.findNode("text")
    m.caption.font = ZFont(18, "semibold")
    m.text.font = ZFont(23)
    m.top.observeField("focusedChild", "paint")
    paint()
end sub

sub paint()
    w = m.top.width
    m.bg.width = w
    m.ring.width = w
    m.text.width = w - 40
    m.caption.text = m.top.label
    value = m.top.value
    if value = "" then
        m.text.text = m.top.placeholder
        m.text.color = "0x8A958DFF"
    else
        if m.top.secure then value = String(Len(value), "•")
        m.text.text = value
        m.text.color = "0xF5F7F5FF"
    end if
    focused = m.top.hasFocus()
    m.ring.visible = focused
    if focused then m.bg.blendColor = "0x262E2AFF" else m.bg.blendColor = "0x1B211EFF"
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if press and key = "OK" then
        m.top.selected = true
        return true
    end if
    return false
end function
