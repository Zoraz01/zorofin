sub init()
    m.top.findNode("initial").font = ZFont(80, "bold")
    m.top.findNode("name").font = ZFont(30, "semibold")
    m.top.findNode("server").font = ZFont(22)
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid then return
    m.top.findNode("name").text = c.title
    m.top.findNode("server").text = c.description
    initial = m.top.findNode("initial")
    if c.id = "add" then
        initial.text = "+"
        m.top.findNode("circle").blendColor = "0x262E2AFF"
    else
        initial.text = UCase(Left(c.title, 1))
        m.top.findNode("circle").blendColor = "0x24543EFF"
    end if
    m.top.findNode("photo").uri = c.HDPosterUrl
end sub

sub onFocus()
    p = m.top.focusPercent
    m.top.findNode("ring").opacity = p
    s = 1 + 0.06 * p
    m.top.findNode("avatar").scale = [s, s]
end sub
