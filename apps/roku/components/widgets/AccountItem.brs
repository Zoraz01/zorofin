sub init()
    m.top.findNode("initial").font = ZFont(64, "regular")
    m.regular = ZFont(26)
    m.bold = ZFont(26, "semibold")
    m.lit = false
    m.top.findNode("name").font = m.regular
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid then return
    m.top.findNode("name").text = c.title
    initial = m.top.findNode("initial")
    if c.id = "add" then
        initial.text = "+"
        m.top.findNode("square").color = "0xFFFFFF17"
    else
        initial.text = UCase(Left(ZStr(c.title), 1))
        m.top.findNode("square").color = "0x24543EFF"
    end if
    m.top.findNode("photo").uri = c.HDPosterUrl
end sub

sub onFocus()
    p = m.top.focusPercent
    m.top.findNode("ring").opacity = p
    avatar = m.top.findNode("avatar")
    s = 1 + 0.08 * p
    avatar.scale = [s, s]
    avatar.opacity = 0.82 + 0.18 * p
    lit = p > 0.5
    if lit = m.lit then return
    m.lit = lit
    name = m.top.findNode("name")
    if lit then
        name.color = "0xF5F7F5FF"
        name.font = m.bold
    else
        name.color = "0xBBC5BDFF"
        name.font = m.regular
    end if
end sub
