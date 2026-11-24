' Card metrics follow the Apple TV strip: 600 wide, 80 px logo, 24 px gaps.
sub init()
    m.top.focusable = true
    m.cards = m.top.findNode("cards")
    m.summary = m.top.findNode("summary")
    m.summary.font = ZFont(22)
    m.streams = []
    m.top.observeField("focusedChild", "paint")
end sub

function cardWidth() as integer
    return 600
end function

function cardHeight() as integer
    return 136
end function

sub build()
    status = m.top.status
    m.cards.removeChildrenIndex(m.cards.getChildCount(), 0)
    m.streams = []
    if status = invalid or status.streams = invalid or status.streams.count() = 0 then
        m.summary.text = ""
        m.top.height = 0
        return
    end if
    m.streams = status.streams
    now = ZNowSeconds()
    x = 0
    for each s in m.streams
        m.cards.appendChild(makeCard(s, now, x))
        x = x + cardWidth() + 24
    end for
    m.summary.text = ZLtsSummary(status)
    m.summary.translation = [0, cardHeight() + 18]
    m.top.height = cardHeight() + 18 + 34
    if m.top.focusIndex >= m.streams.count() then m.top.focusIndex = m.streams.count() - 1
    paint()
end sub

function makeCard(s as object, now as integer, x as integer) as object
    w = cardWidth()
    h = cardHeight()
    card = CreateObject("roSGNode", "Group")
    card.translation = [x, 0]
    ring = card.createChild("Poster")
    ring.id = "ring"
    ring.uri = "pkg:/images/ring.9.png"
    ring.width = w + 12
    ring.height = h + 12
    ring.translation = [-6, -6]
    ring.opacity = 0
    bg = card.createChild("Poster")
    bg.uri = "pkg:/images/panel.9.png"
    bg.width = w
    bg.height = h
    bg.blendColor = "0x1B211EFF"
    if s.yours then
        edge = card.createChild("Poster")
        edge.uri = "pkg:/images/card_ring.9.png"
        edge.width = w
        edge.height = h
        edge.blendColor = "0x72E79B73"
    end if
    ' Logo tile with the channel's initials until (or unless) the logo loads.
    tile = card.createChild("Poster")
    tile.uri = "pkg:/images/card.9.png"
    tile.width = 80
    tile.height = 80
    tile.translation = [20, 28]
    tile.blendColor = "0x0D110FFF"
    initials = card.createChild("Label")
    initials.text = UCase(Left(s.channelName, 3))
    initials.font = ZFont(19, "bold")
    initials.color = "0x8A958DFF"
    initials.width = 80
    initials.height = 80
    initials.horizAlign = "center"
    initials.vertAlign = "center"
    initials.translation = [20, 28]
    logo = card.createChild("Poster")
    logo.width = 62
    logo.height = 62
    logo.translation = [29, 37]
    logo.loadDisplayMode = "scaleToFit"
    if m.top.server <> "" then logo.uri = ZEndpoint(m.top.server, ["Items", s.channelId, "Images", "Primary"], { maxWidth: 240, quality: 90 })
    ' LIVE capsule, channel, programme, "2 watching · 18 min left".
    badge = card.createChild("Poster")
    badge.uri = "pkg:/images/badge.9.png"
    badge.width = 62
    badge.height = 28
    badge.translation = [120, 24]
    badge.blendColor = "0x05120AFF"
    live = card.createChild("Label")
    live.text = "LIVE"
    live.font = ZFont(15, "bold")
    live.color = "0x72E79BFF"
    live.width = 62
    live.height = 28
    live.horizAlign = "center"
    live.vertAlign = "center"
    live.translation = [120, 24]
    name = card.createChild("Label")
    name.text = s.channelName
    name.font = ZFont(26, "bold")
    name.color = "0xF5F7F5FF"
    name.width = 250
    name.maxLines = 1
    name.translation = [194, 20]
    lineY = 60
    if s.programme <> invalid and s.programme.title <> "" then
        show = card.createChild("Label")
        show.text = s.programme.title
        show.font = ZFont(21)
        show.color = "0xE3E8E4FF"
        show.width = 320
        show.maxLines = 1
        show.translation = [120, lineY]
        lineY = lineY + 32
    end if
    detail = card.createChild("Label")
    detail.text = ZLtsDetail(s, now)
    detail.font = ZFont(18)
    detail.color = "0x8A958DFF"
    detail.width = 320
    detail.maxLines = 1
    detail.translation = [120, lineY]
    ' Join pill on the right; "Watching" when it's this Roku's own stream.
    pill = card.createChild("Poster")
    pill.id = "pill"
    pill.uri = "pkg:/images/pill.9.png"
    pill.width = 136
    pill.height = 60
    pill.translation = [w - 156, (h - 60) / 2]
    label = card.createChild("Label")
    label.id = "pillText"
    label.text = "Join"
    if s.yours then label.text = "Watching"
    label.font = ZFont(22, "semibold")
    label.width = 136
    label.height = 60
    label.horizAlign = "center"
    label.vertAlign = "center"
    label.translation = [w - 156, (h - 60) / 2]
    return card
end function

sub paint()
    focused = m.top.isInFocusChain()
    for i = 0 to m.cards.getChildCount() - 1
        card = m.cards.getChild(i)
        on = focused and i = m.top.focusIndex
        s = m.streams[i]
        card.findNode("ring").opacity = 0
        if on then card.findNode("ring").opacity = 1
        pill = card.findNode("pill")
        text = card.findNode("pillText")
        if on then
            pill.blendColor = "0xFFFFFFFF"
            text.color = "0x111513FF"
        else if s <> invalid and not s.yours then
            pill.blendColor = "0x72E79BFF"
            text.color = "0x111513FF"
        else
            pill.blendColor = "0x2B342FFF"
            text.color = "0xF5F7F5FF"
        end if
    end for
    ' Keep the focused card on screen when several channels are playing.
    stride = cardWidth() + 24
    shift = 0
    if m.top.focusIndex > 1 then shift = -(m.top.focusIndex - 1) * stride
    m.cards.translation = [shift, 0]
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    count = m.streams.count()
    if count = 0 then return false
    if key = "right" and m.top.focusIndex < count - 1 then
        m.top.focusIndex = m.top.focusIndex + 1
        return true
    else if key = "left" and m.top.focusIndex > 0 then
        m.top.focusIndex = m.top.focusIndex - 1
        return true
    else if key = "OK" then
        m.top.selected = m.streams[m.top.focusIndex]
        return true
    end if
    return false
end function
