sub init()
    m.top.focusable = true
    m.clip = m.top.findNode("clip")
    m.body = m.top.findNode("body")
    m.items = []
    m.top.observeField("focusedChild", "onFocusChange")
end sub

sub onFocusChange()
    if m.top.isInFocusChain() and (m.top.focusIndex < 0 or not Focusable(m.top.focusIndex)) then
        m.top.focusIndex = NextFocusable(-1, 1)
    end if
    paint()
end sub

function Focusable(i as integer) as boolean
    if i < 0 or i >= m.items.count() then return false
    it = m.items[i]
    return it.focusable
end function

function NextFocusable(from as integer, direction as integer) as integer
    i = from + direction
    while i >= 0 and i < m.items.count()
        if Focusable(i) then return i
        i = i + direction
    end while
    return -1
end function

sub build()
    m.body.removeChildrenIndex(m.body.getChildCount(), 0)
    m.items = []
    w = m.top.width
    y = 0
    theme = ZTheme()
    font = ZFont(m.top.fontSize)
    bold = ZFont(m.top.fontSize, "semibold")
    small = ZFont(17)
    for each r in m.top.rows
        if r.divider = true then
            line = CreateObject("roSGNode", "Rectangle")
            line.width = w
            line.height = 1
            line.color = theme.border
            line.translation = [0, y + 8]
            m.body.appendChild(line)
            m.items.push({ focusable: false, top: y, height: 17 })
            y = y + 17
        else if ZStr(r.note) <> "" then
            ' A footnote under a section (Apple's .footnote, muted).
            note = CreateObject("roSGNode", "Label")
            note.font = small
            note.color = theme.muted
            note.wrap = true
            note.width = w - 24
            note.text = r.note
            note.translation = [12, y + 6]
            lines = Int(ZTextWidth(r.note, small) / (w - 24)) + 1
            nh = lines * 24 + 14
            m.body.appendChild(note)
            m.items.push({ focusable: false, top: y, height: nh })
            y = y + nh
        else if r.header = true then
            label = CreateObject("roSGNode", "Label")
            label.font = ZFont(18, "semibold")
            label.color = theme.muted
            label.text = UCase(ZStr(r.title))
            label.translation = [12, y + 14]
            m.body.appendChild(label)
            m.items.push({ focusable: false, top: y, height: 44 })
            y = y + 44
        else
            h = m.top.rowHeight
            if ZStr(r.subtitle) <> "" or r.avatar <> invalid then h = 72
            if r.height <> invalid then h = r.height
            g = CreateObject("roSGNode", "Group")
            g.translation = [0, y]
            bg = ZPoster("pkg:/images/option.9.png", w, h)
            ring = ZPoster("pkg:/images/option_ring.9.png", w, h)
            ring.blendColor = theme.jade
            g.appendChild(bg)
            g.appendChild(ring)
            x = 12
            if r.avatar <> invalid then
                disc = ZPoster("pkg:/images/badge.9.png", 44, 44, x, Int((h - 44) / 2))
                disc.blendColor = theme.avatar
                initial = CreateObject("roSGNode", "Label")
                initial.font = ZFont(21, "bold")
                initial.color = theme.text
                initial.text = ZStr(r.initial)
                initial.width = 44
                initial.height = 44
                initial.horizAlign = "center"
                initial.vertAlign = "center"
                initial.translation = [x, Int((h - 44) / 2)]
                photo = ZPoster(ZStr(r.avatar), 44, 44, x, Int((h - 44) / 2))
                photo.loadDisplayMode = "scaleToZoom"
                g.appendChild(disc)
                g.appendChild(initial)
                g.appendChild(photo)
                x = x + 58
            else if ZStr(r.icon) <> "" then
                icon = ZPoster("pkg:/images/icons/" + r.icon + ".png", 28, 28, x, Int((h - 28) / 2))
                icon.blendColor = theme.text
                if ZStr(r.tint) <> "" then icon.blendColor = r.tint
                g.appendChild(icon)
                x = x + 44
            end if
            trailing = 0
            check = invalid
            value = invalid
            if r.checked = true then
                check = ZPoster("pkg:/images/icons/check-filled.png", 26, 26, w - 40, Int((h - 26) / 2))
                check.blendColor = theme.jade
                g.appendChild(check)
                trailing = 48
            end if
            if ZStr(r.value) <> "" then
                value = CreateObject("roSGNode", "Label")
                value.font = ZFont(20)
                value.color = theme.muted
                value.text = r.value
                vw = ZTextWidth(r.value, value.font) + 10
                if vw > Int(w * 0.45) then vw = Int(w * 0.45)
                value.width = vw
                value.height = h
                value.vertAlign = "center"
                value.horizAlign = "right"
                value.translation = [w - 16 - trailing - vw, 0]
                g.appendChild(value)
                trailing = trailing + vw + 16
            end if
            title = CreateObject("roSGNode", "Label")
            title.font = font
            if r.current = true then title.font = bold
            title.color = theme.text
            title.text = ZStr(r.title)
            title.width = w - x - 16 - trailing
            title.maxLines = 1
            sub2 = invalid
            if ZStr(r.subtitle) <> "" then
                title.translation = [x, Int(h / 2) - 30]
                title.height = 30
                sub2 = CreateObject("roSGNode", "Label")
                sub2.font = small
                sub2.color = theme.muted
                sub2.text = r.subtitle
                sub2.width = w - x - 16 - trailing
                sub2.maxLines = 1
                sub2.translation = [x, Int(h / 2) + 2]
                g.appendChild(sub2)
            else
                title.translation = [x, 0]
                title.height = h
                title.vertAlign = "center"
            end if
            g.appendChild(title)
            m.body.appendChild(g)
            m.items.push({
                focusable: r.disabled <> true, id: ZStr(r.id), top: y, height: h,
                bg: bg, ring: ring, title: title, value: value, check: check, row: r
            })
            y = y + h + 4
        end if
    end for
    total = y
    if total > 0 then total = total - 4
    ' Always a real rectangle: on Roku OS 15.3 an all-zero clippingRect
    ' hid every row instead of turning clipping off.
    if m.top.maxHeight > 0 and total > m.top.maxHeight then
        m.top.height = m.top.maxHeight
    else
        m.top.height = total
    end if
    m.clip.clippingRect = [-12, -12, w + 24, m.top.height + 24]
    m.body.translation = [0, 0]
    if not Focusable(m.top.focusIndex) then m.top.focusIndex = NextFocusable(-1, 1)
    paint()
end sub

sub paint()
    focused = m.top.isInFocusChain()
    for i = 0 to m.items.count() - 1
        it = m.items[i]
        if it.bg <> invalid then
            on = focused and i = m.top.focusIndex
            if on then
                it.bg.blendColor = "0xF5F7F517"
            else
                it.bg.blendColor = "0xF5F7F500"
            end if
            it.ring.visible = on
            if it.row.disabled = true then
                it.title.opacity = 0.45
            else
                it.title.opacity = 1
            end if
        end if
    end for
    i = m.top.focusIndex
    if i >= 0 and i < m.items.count() and m.items[i].id <> invalid then
        if m.top.focusedId <> m.items[i].id then m.top.focusedId = m.items[i].id
        ' Keep the focused row inside the visible height.
        if m.top.maxHeight > 0 then
            it = m.items[i]
            offset = -m.body.translation[1]
            if it.top < offset then offset = it.top
            if it.top + it.height > offset + m.top.maxHeight then offset = it.top + it.height - m.top.maxHeight
            m.body.translation = [0, -offset]
        end if
    end if
end sub

sub focusRow(id as dynamic)
    for i = 0 to m.items.count() - 1
        if m.items[i].id = id and Focusable(i) then m.top.focusIndex = i
    end for
end sub

' Changes one row in place: { id, title?, value?, subtitle? }.
sub updateRow(params as object)
    for each it in m.items
        if it.id = params.id then
            if params.title <> invalid then it.title.text = params.title
            if params.value <> invalid and it.value <> invalid then it.value.text = params.value
        end if
    end for
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "down" then
        n = NextFocusable(m.top.focusIndex, 1)
        if n < 0 then return false
        m.top.focusIndex = n
        return true
    else if key = "up" then
        n = NextFocusable(m.top.focusIndex, -1)
        if n < 0 then return false
        m.top.focusIndex = n
        return true
    else if key = "OK" then
        if Focusable(m.top.focusIndex) then m.top.selected = m.items[m.top.focusIndex].id
        return true
    end if
    return false
end function
