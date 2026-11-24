sub init()
    m.list = m.top.findNode("list")
    m.top.findNode("heading").font = ZFont(30, "bold")
    m.top.findNode("sub").font = ZFont(22)
    m.list.observeField("selected", "onSelected")
    layout()
end sub

' Right-hand panel, 680 px (1000 px for episodes and channels), full height
' inside the 40 px safe margin.
sub layout()
    w = 680
    if m.top.wide then w = 1000
    x = 1920 - 60 - w
    for each id in ["bg", "hair"]
        p = m.top.findNode(id)
        p.width = w
        p.height = 1000
        p.translation = [x, 40]
    end for
    heading = m.top.findNode("heading")
    heading.text = m.top.title
    heading.translation = [x + 40, 80]
    heading.width = w - 80
    sub2 = m.top.findNode("sub")
    sub2.text = m.top.context
    sub2.translation = [x + 40, 126]
    sub2.width = w - 80
    top = 180
    if m.top.context = "" then top = 140
    m.list.translation = [x + 28, top]
    m.list.width = w - 56
    m.list.maxHeight = 1040 - 40 - top
end sub

sub onRows()
    m.list.rows = m.top.rows
    if m.top.focusId <> "" then m.list.callFunc("focusRow", m.top.focusId)
end sub

sub updateRow(params as object)
    m.list.callFunc("updateRow", params)
end sub

sub takeFocus()
    m.list.setFocus(true)
end sub

sub onSelected(event as object)
    m.top.selected = event.getData()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" or key = "left" then
        m.top.back = true
        return true
    end if
    if key = "options" then
        m.top.selected = "__close"
        return true
    end if
    ' The panel is modal: keep other keys from reaching the video.
    return key <> "home"
end function
