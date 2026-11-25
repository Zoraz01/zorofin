' See GuideGrid.xml. Focus is drawn by the grid itself: m.row is the focused
' channel's index in m.top.channels and m.col is a slot index, or -1 for the
' channel cell. m.anchor is the time that Up and Down keep, so moving between
' channels stays in the same part of the schedule.

sub init()
    m.top.findNode("nowLine").color = ZAccent("A6")
    m.top.focusable = true
    m.theme = ZTheme()
    m.schedule = 1480
    m.rowHeight = 108
    m.rowStep = 118
    m.headFont = ZFont(21, "semibold")
    m.nameFont = ZFont(23, "semibold")
    m.timeFont = ZFont(18)
    m.numberFont = ZFont(20, "semibold")
    m.channelFont = ZFont(22, "semibold")
    m.top.findNode("channelHead").font = m.headFont
    m.cache = {}
    m.slots = {}
    m.row = 0
    m.col = 0
    m.anchor = 0
    m.first = 0
    m.pool = []
    m.top.observeField("focusedChild", "paint")
    heads = m.top.findNode("timeHead")
    m.heads = []
    for i = 0 to 3
        l = CreateObject("roSGNode", "Label")
        l.font = m.headFont
        l.color = m.theme.muted
        l.height = 38
        l.vertAlign = "center"
        l.translation = [Int(i * m.schedule / 4), 0]
        heads.appendChild(l)
        m.heads.push(l)
    end for
    buildRows()
end sub

sub buildRows()
    rows = m.top.findNode("rows")
    rows.removeChildrenIndex(rows.getChildCount(), 0)
    m.pool = []
    for i = 0 to m.top.rowCount - 1
        g = CreateObject("roSGNode", "Group")
        g.translation = [0, i * m.rowStep]
        cell = CreateObject("roSGNode", "Group")
        bg = ZPoster("pkg:/images/option.9.png", 236, m.rowHeight)
        bg.blendColor = m.theme.panel
        hair = ZPoster("pkg:/images/option_hair.9.png", 236, m.rowHeight)
        hair.blendColor = "0x39423C80"
        stroke = ZPoster("pkg:/images/option_stroke.9.png", 236, m.rowHeight)
        stroke.blendColor = m.theme.jade
        logo = ZPoster("", 64, 44, 10, 32)
        logo.loadWidth = 64
        logo.loadHeight = 44
        logo.loadDisplayMode = "scaleToFit"
        number = CreateObject("roSGNode", "Label")
        number.font = m.numberFont
        number.color = m.theme.jade
        number.translation = [86, 18]
        number.width = 130
        name = CreateObject("roSGNode", "Label")
        name.font = m.channelFont
        name.color = m.theme.text
        name.translation = [86, 44]
        name.width = 124
        name.wrap = true
        name.maxLines = 2
        placeholder = ZPoster("pkg:/images/icons/tv.png", 28, 28, 28, 40)
        placeholder.blendColor = m.theme.muted
        heart = ZPoster("pkg:/images/icons/heart-filled.png", 16, 16, 208, 14)
        heart.blendColor = m.theme.jade
        for each n in [bg, hair, stroke, placeholder, logo, number, name, heart]
            cell.appendChild(n)
        end for
        slotsGroup = CreateObject("roSGNode", "Group")
        slotsGroup.translation = [248, 0]
        g.appendChild(cell)
        g.appendChild(slotsGroup)
        rows.appendChild(g)
        m.pool.push({ group: g, bg: bg, hair: hair, stroke: stroke, logo: logo, placeholder: placeholder, number: number, name: name, heart: heart, slotsGroup: slotsGroup, slots: [] })
    end for
    line = m.top.findNode("nowLine")
    line.height = m.top.rowCount * m.rowStep - 10
    line.translation = [0, 46]
    paint()
end sub

' A reusable program cell inside a row.
function SlotNode(row as object, index as integer) as object
    while row.slots.count() <= index
        g = CreateObject("roSGNode", "Group")
        bg = ZPoster("pkg:/images/option.9.png", 10, m.rowHeight)
        hair = ZPoster("pkg:/images/option_hair.9.png", 10, m.rowHeight)
        hair.blendColor = "0x39423C80"
        stroke = ZPoster("pkg:/images/option_stroke.9.png", 10, m.rowHeight)
        stroke.blendColor = m.theme.jade
        bar = CreateObject("roSGNode", "Rectangle")
        bar.color = m.theme.jade
        bar.height = 3
        name = CreateObject("roSGNode", "Label")
        name.font = m.nameFont
        name.color = m.theme.text
        name.wrap = true
        name.maxLines = 2
        name.lineSpacing = -4
        name.translation = [14, 10]
        time = CreateObject("roSGNode", "Label")
        time.font = m.timeFont
        time.color = m.theme.muted
        time.translation = [14, 74]
        for each n in [bg, hair, stroke, bar, name, time]
            g.appendChild(n)
        end for
        row.slotsGroup.appendChild(g)
        row.slots.push({ group: g, bg: bg, hair: hair, stroke: stroke, bar: bar, name: name, time: time })
    end while
    return row.slots[index]
end function

sub onChannels()
    m.slots = {}
    m.row = ZClamp(m.row, 0, ZMax(0, m.top.channels.count() - 1))
    m.first = ZClamp(m.first, 0, ZMax(0, m.top.channels.count() - m.top.rowCount))
    if m.row < m.first then m.first = m.row
    m.top.topIndex = m.first
    paint()
end sub

sub onWindow()
    m.cache = {}
    m.slots = {}
    ws = m.top.windowStart
    for i = 0 to 3
        m.heads[i].text = ZGuideTime(ws + i * 1800, m.top.offset)
    end for
    m.anchor = ws
    if m.top.now >= ws and m.top.now < ws + ZGuideDuration() then m.anchor = m.top.now
    if m.col >= 0 then m.col = ZMax(0, ZGuideSlotAt(SlotsFor(m.row), m.anchor))
    paint()
end sub

sub onPrograms()
    update = m.top.programs
    if update = invalid then return
    for each id in update
        m.cache[id] = update[id]
        m.slots.delete(id)
    end for
    if m.col >= 0 then m.col = ZClamp(ZGuideSlotAt(SlotsFor(m.row), m.anchor), 0, 999)
    paint()
end sub

' Slots for the channel at an index, from the listings cache.
function SlotsFor(index as integer) as object
    channels = m.top.channels
    ws = m.top.windowStart
    if channels = invalid or index < 0 or index >= channels.count() then return []
    id = ZStr(channels[index].id)
    if m.slots.doesExist(id) then return m.slots[id]
    slots = ZGuideSlots(id, m.cache[id], ws, ws + ZGuideDuration())
    if m.cache.doesExist(id) then m.slots[id] = slots
    return slots
end function

sub paint()
    channels = m.top.channels
    if channels = invalid then channels = []
    focused = m.top.hasFocus()
    ws = m.top.windowStart
    now = m.top.now
    offset = m.top.offset
    for i = 0 to m.pool.count() - 1
        row = m.pool[i]
        index = m.first + i
        if index >= channels.count() then
            row.group.visible = false
        else
            row.group.visible = true
            c = channels[index]
            row.logo.uri = ZStr(c.logo)
            ' Apple GuideChannelLogo: a muted TV glyph until the logo loads.
            row.placeholder.visible = ZStr(c.logo) = ""
            row.number.text = ZStr(c.number)
            row.name.text = ZStr(c.name)
            if ZStr(c.number) = "" then row.name.translation = [86, 24] else row.name.translation = [86, 44]
            row.heart.visible = c.favorite = true
            on = focused and index = m.row and m.col = -1
            row.stroke.visible = on
            row.hair.visible = not on
            loaded = m.cache.doesExist(ZStr(c.id))
            empty = "Loading…"
            if loaded then
                empty = "No listings"
            else if m.top.failed then
                empty = "Guide unavailable"
            end if
            slots = SlotsFor(index)
            for s = 0 to slots.count() - 1
                slot = slots[s]
                node = SlotNode(row, s)
                x = Int(m.schedule * ZGuideFraction(ws, slot.start))
                w = Int(m.schedule * (slot.finish - slot.start) / ZGuideDuration()) - 4
                if w < 1 then w = 1
                compact = w < 110
                node.group.visible = true
                node.group.translation = [x, 0]
                node.bg.width = w
                node.hair.width = w
                node.stroke.width = w
                airing = ZGuideAiring(slot.program, now)
                if airing then node.bg.blendColor = "0x263B2EFF" else node.bg.blendColor = m.theme.panel
                sOn = focused and index = m.row and m.col = s
                node.stroke.visible = sOn
                node.hair.visible = not sOn
                pad = 14
                if compact then pad = 2
                node.name.translation = [pad, 10]
                node.name.width = ZMax(1, w - pad * 2)
                node.time.width = ZMax(1, w - pad * 2)
                if compact then
                    node.name.text = "…"
                    node.time.text = ""
                else if slot.program <> invalid then
                    node.name.text = ZStr(slot.program.name)
                    node.time.text = ZGuideRange(slot.program.start, slot.program.finish, offset)
                else
                    node.name.text = empty
                    node.time.text = ""
                end if
                node.name.color = m.theme.text
                if slot.program = invalid then node.name.color = m.theme.muted
                node.bar.visible = airing
                if airing then
                    p = (now - slot.program.start) / ZMax(1, slot.program.finish - slot.program.start)
                    node.bar.width = Int(ZMax(0, w - 20) * ZClamp(p, 0, 1))
                    node.bar.translation = [10, m.rowHeight - 9]
                end if
            end for
            for s = slots.count() to row.slots.count() - 1
                row.slots[s].group.visible = false
            end for
        end if
    end for
    line = m.top.findNode("nowLine")
    line.visible = now >= ws and now < ws + ZGuideDuration() and channels.count() > 0
    line.translation = [248 + Int(m.schedule * ZGuideFraction(ws, now)), 46]
    rows = channels.count() - m.first
    if rows > m.top.rowCount then rows = m.top.rowCount
    line.height = ZMax(0, rows * m.rowStep - 10)
    publishFocus()
end sub

sub publishFocus()
    channels = m.top.channels
    if channels = invalid or m.row >= channels.count() then
        m.top.focusInfo = {}
        return
    end if
    info = { channel: channels[m.row], program: invalid, start: 0, finish: 0 }
    slots = SlotsFor(m.row)
    if m.col >= 0 and m.col < slots.count() then
        info.program = slots[m.col].program
    else
        ' The channel cell previews what is on now (or first in the window).
        for each slot in slots
            if slot.program <> invalid and info.program = invalid then info.program = slot.program
        end for
    end if
    m.top.focusInfo = info
end sub

sub moveRow(index as integer)
    count = m.top.channels.count()
    if count = 0 then return
    m.row = ZClamp(index, 0, count - 1)
    if m.row < m.first then m.first = m.row
    if m.row >= m.first + m.top.rowCount then m.first = m.row - m.top.rowCount + 1
    if m.col >= 0 then m.col = ZMax(0, ZGuideSlotAt(SlotsFor(m.row), m.anchor))
    m.top.topIndex = m.first
    paint()
end sub

sub setCol(col as integer)
    m.col = col
    slots = SlotsFor(m.row)
    if col >= 0 and col < slots.count() then
        slot = slots[col]
        ' Keep the visible middle of the focused cell for Up and Down.
        m.anchor = slot.start + Int((slot.finish - slot.start) / 2)
    end if
    paint()
end sub

' Puts focus on a channel by id (after a refresh or filter change).
sub focusChannel(id as dynamic)
    channels = m.top.channels
    if channels = invalid then return
    for i = 0 to channels.count() - 1
        if channels[i].id = id then
            moveRow(i)
            return
        end if
    end for
    moveRow(0)
end sub

' Moves focus to the program airing at a time on the current row ("Now").
sub focusTime(t as dynamic)
    m.anchor = Int(ZNum(t, m.top.windowStart))
    m.col = ZMax(0, ZGuideSlotAt(SlotsFor(m.row), m.anchor))
    paint()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    channels = m.top.channels
    if channels = invalid or channels.count() = 0 then return false
    slots = SlotsFor(m.row)
    if key = "up" then
        if m.row = 0 then return false
        moveRow(m.row - 1)
        return true
    else if key = "down" then
        if m.row >= channels.count() - 1 then return true
        moveRow(m.row + 1)
        return true
    else if key = "left" then
        if m.col > 0 then
            setCol(m.col - 1)
        else if m.col = 0 then
            setCol(-1)
        else
            return false
        end if
        return true
    else if key = "right" then
        if m.col = -1 then
            setCol(ZMax(0, ZGuideSlotAt(slots, m.anchor)))
        else if m.col < slots.count() - 1 then
            setCol(m.col + 1)
        else
            m.top.edge = "later"
        end if
        return true
    else if key = "fastforward" then
        m.top.edge = "later"
        return true
    else if key = "rewind" then
        m.top.edge = "earlier"
        return true
    else if key = "OK" then
        info = m.top.focusInfo
        if m.col = -1 then info = { channel: channels[m.row], program: info.program }
        m.top.selected = info
        return true
    else if key = "play" then
        m.top.play = { channel: channels[m.row] }
        return true
    end if
    return false
end function
