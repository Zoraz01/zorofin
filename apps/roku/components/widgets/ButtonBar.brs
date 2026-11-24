' Buttons styled like the Apple TV app (Theme.swift):
'   ZoroButtonStyle  capsule, 22 pt semibold, panel fill with a 1 px border,
'                    "primary" play green, "white" text colour; focus adds a
'                    3 px white stroke and a 1.04 lift.
'   DetailIconStyle  60 px circle (style "icon"), panel fill, 1 px border,
'                    3 px white stroke and 1.08 lift on focus.
'   "glass"          60 px circle on white 12%, used over artwork.
' A button is { id, text?, icon?, style?, tint?, primary?, disabled? }. icon
' names a white glyph in images/icons; "▶" (older callers) means play.

sub init()
    m.top.focusable = true
    m.items = []
    m.top.observeField("focusedChild", "onFocusChange")
end sub

sub onFocusChange()
    paint()
end sub

function StyleOf(b as object) as string
    style = ZStr(b.style)
    if style = "" and b.primary = true then style = "white"
    if style = "" then style = "default"
    return style
end function

function IconOf(b as object) as string
    icon = ZStr(b.icon)
    if icon = "▶" then icon = "play-filled"
    return icon
end function

sub build()
    m.top.removeChildrenIndex(m.top.getChildCount(), 0)
    m.items = []
    x = 0
    y = 0
    h = m.top.buttonHeight
    font = ZFont(m.top.fontSize, "semibold")
    for each b in m.top.buttons
        style = StyleOf(b)
        icon = IconOf(b)
        text = ZStr(b.text)
        round = style = "icon" or style = "glass"
        bh = h
        if round then bh = 60
        w = bh
        textW = 0
        if not round then
            w = m.top.fixedWidth
            if text <> "" then textW = ZTextWidth(text, font)
            if w <= 0 then
                w = textW + 56
                if icon <> "" then w = w + 34
                if w < m.top.minWidth then w = m.top.minWidth
                if b.width <> invalid then w = b.width
            end if
        end if
        g = CreateObject("roSGNode", "Group")
        g.translation = [x, y + Int((h - bh) / 2)]
        g.scaleRotateCenter = [w / 2, bh / 2]
        if round then
            bg = ZPoster("pkg:/images/circle.png", bh, bh)
            border = ZPoster("pkg:/images/circle_hair.png", bh, bh)
            stroke = ZPoster("pkg:/images/circle_stroke.png", bh, bh)
        else
            bg = ZPoster("pkg:/images/pill.9.png", w, bh)
            border = ZPoster("pkg:/images/pill_hair.9.png", w, bh)
            stroke = ZPoster("pkg:/images/pill_stroke.9.png", w, bh)
        end if
        g.appendChild(bg)
        g.appendChild(border)
        g.appendChild(stroke)
        glyph = invalid
        label = invalid
        if icon <> "" then
            size = 26
            if not round then size = 24
            gx = Int((w - size) / 2)
            if not round and text <> "" then
                gx = Int((w - (size + 10 + textW)) / 2)
                if m.top.align = "left" then gx = 28
            end if
            glyph = ZPoster("pkg:/images/icons/" + icon + ".png", size, size, gx, Int((bh - size) / 2))
            g.appendChild(glyph)
        end if
        if text <> "" and not round then
            label = CreateObject("roSGNode", "Label")
            label.text = text
            label.font = font
            label.height = bh
            label.vertAlign = "center"
            if glyph <> invalid then
                label.translation = [glyph.translation[0] + 34, 0]
                label.width = textW + 4
            else if m.top.align = "left" then
                label.translation = [28, 0]
                label.width = w - 56
            else
                label.width = w
                label.horizAlign = "center"
            end if
            g.appendChild(label)
        end if
        m.top.appendChild(g)
        m.items.push({
            id: ZStr(b.id), group: g, bg: bg, border: border, stroke: stroke,
            glyph: glyph, label: label, style: style, tint: ZStr(b.tint),
            disabled: b.disabled = true, width: w, height: bh
        })
        if m.top.vertical then
            y = y + h + 16
        else
            spacing = 16
            if m.top.spacing > 0 then spacing = m.top.spacing
            x = x + w + spacing
        end if
    end for
    m.top.totalWidth = x
    if m.top.focusIndex >= m.items.count() then m.top.focusIndex = 0
    paint()
end sub

sub paint()
    focused = m.top.isInFocusChain()
    theme = ZTheme()
    for i = 0 to m.items.count() - 1
        it = m.items[i]
        on = focused and i = m.top.focusIndex
        fg = theme.text
        if it.style = "primary" then
            it.bg.blendColor = theme.play
            fg = theme.background
        else if it.style = "white" then
            it.bg.blendColor = theme.text
            fg = theme.background
        else if it.style = "glass" then
            it.bg.blendColor = "0xFFFFFF1F"
        else
            it.bg.blendColor = theme.panel
        end if
        it.border.blendColor = theme.border
        it.border.visible = (it.style = "default" or it.style = "icon") and not on
        ' A white capsule needs a jade stroke to show focus.
        it.stroke.blendColor = "0xFFFFFFFF"
        if it.style = "white" then it.stroke.blendColor = theme.jade
        it.stroke.visible = on
        scale = 1
        if on then
            scale = 1.04
            if it.style = "icon" or it.style = "glass" then scale = 1.08
        end if
        it.group.scale = [scale, scale]
        if it.disabled then
            it.group.opacity = 0.45
        else
            it.group.opacity = 1
        end if
        if it.label <> invalid then it.label.color = fg
        if it.glyph <> invalid then
            if it.tint <> "" then
                it.glyph.blendColor = it.tint
            else
                it.glyph.blendColor = fg
            end if
        end if
    end for
    if m.items.count() > 0 and m.top.focusIndex < m.items.count() then m.top.focusedId = m.items[m.top.focusIndex].id
end sub

' Replaces one button's label, icon or tint in place: { id, text?, icon?, tint? }.
sub setLabel(params as object)
    for each it in m.items
        if it.id = params.id then
            if params.text <> invalid and it.label <> invalid then it.label.text = params.text
            if params.icon <> invalid and it.glyph <> invalid then it.glyph.uri = "pkg:/images/icons/" + params.icon + ".png"
            if params.tint <> invalid then it.tint = params.tint
        end if
    end for
    paint()
end sub

' Moves focus to the button with this id.
sub focusButton(id as dynamic)
    for i = 0 to m.items.count() - 1
        if m.items[i].id = id then m.top.focusIndex = i
    end for
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    count = m.items.count()
    if count = 0 then return false
    nextKey = "right"
    prevKey = "left"
    if m.top.vertical then
        nextKey = "down"
        prevKey = "up"
    end if
    if key = nextKey and m.top.focusIndex < count - 1 then
        m.top.focusIndex = m.top.focusIndex + 1
        return true
    else if key = prevKey and m.top.focusIndex > 0 then
        m.top.focusIndex = m.top.focusIndex - 1
        return true
    else if key = "OK" then
        it = m.items[m.top.focusIndex]
        if not it.disabled then m.top.selected = it.id
        return true
    end if
    return false
end function
