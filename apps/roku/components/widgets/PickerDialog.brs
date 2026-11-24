sub init()
    m.list = m.top.findNode("list")
    m.top.findNode("heading").font = ZFont(30, "bold")
    m.top.findNode("body").font = ZFont(21)
    m.list.observeField("selected", "onSelected")
end sub

sub layout()
    ' Callers set title and message before options; lay out once options exist.
    if type(m.top.options) <> "roArray" then return
    rows = []
    focus = ""
    for each o in m.top.options
        rows.push({ id: ZStr(o.id), title: ZStr(o.title), subtitle: ZStr(o.subtitle), checked: o.checked = true, current: o.checked = true })
        if o.checked = true then focus = ZStr(o.id)
    end for
    m.list.rows = rows
    if focus <> "" then m.list.callFunc("focusRow", focus)
    top = 84
    body = m.top.findNode("body")
    m.top.findNode("heading").text = m.top.title
    body.text = m.top.message
    ' Measure the wrapped message (it may hold line breaks) to place the list.
    if m.top.message <> "" then top = 74 + Int(body.localBoundingRect().height + 0.5) + 18
    m.list.translation = [24, top]
    h = top + m.list.height + 28
    bg = m.top.findNode("bg")
    bg.width = 700
    bg.height = h
    m.top.findNode("card").translation = [610, Int((1080 - h) / 2)]
end sub

sub takeFocus()
    m.list.setFocus(true)
end sub

sub onSelected(event as object)
    m.top.result = { id: event.getData() }
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" then
        m.top.result = {}
        return true
    end if
    return true
end function
