' Apple TV MediaCard (LibraryViews.swift): 12 px corners, white focus ring
' and a 1.045 lift, quality badges in one dark pill at the bottom left, a
' 4 px jade progress line, an optional rating pill at the top right, then a
' 22 pt title and a 17 pt caption. Display settings follow the viewer's
' Profile choices in m.global.settings.

sub init()
    m.top.findNode("progressFill").color = ZAccent()
    m.lift = m.top.findNode("lift")
    m.art = m.top.findNode("art")
    m.placeholder = m.top.findNode("placeholder")
    m.fallback = m.top.findNode("fallback")
    m.corners = m.top.findNode("corners")
    m.ring = m.top.findNode("ring")
    m.title = m.top.findNode("title")
    m.caption = m.top.findNode("caption")
    m.fill = m.top.findNode("progressFill")
    m.ratingGroup = m.top.findNode("ratingGroup")
    m.ratingPill = m.top.findNode("ratingPill")
    m.ratingText = m.top.findNode("ratingText")
    m.badgePill = m.top.findNode("badgePill")
    m.badgeText = m.top.findNode("badgeText")
    m.liveDot = m.top.findNode("liveDot")
    m.title.font = ZFont(22, "semibold")
    m.caption.font = ZFont(17)
    m.ratingText.font = ZFont(18, "bold")
    m.badgeText.font = ZFont(16, "bold")
    m.fallback.font = ZFont(22, "semibold")
    m.game = m.top.findNode("game")
    m.gameBack = m.top.findNode("gameBack")
    m.crests = [m.top.findNode("crestA"), m.top.findNode("crestB")]
    m.versus = m.top.findNode("versus")
    m.gameStatus = m.top.findNode("gameStatus")
    m.versus.font = ZFont(18, "bold")
    m.gameStatus.font = ZFont(17)
    for each crest in m.crests
        crest.observeField("loadStatus", "onCrest")
    end for
    m.artHeight = 0
end sub

function ViewerPrefs() as object
    s = m.global.settings
    if s = invalid then return {}
    return s
end function

' Lists size the item 12 px larger than the card (see the frame inset).
function CardWidth() as float
    return m.top.width - 12
end function

sub layout()
    w = CardWidth()
    if w <= 0 then return
    landscape = w >= 300
    if landscape then
        m.artHeight = Int(w * 9 / 16)
    else
        m.artHeight = Int(w * 3 / 2)
    end if
    ah = m.artHeight
    for each node in [m.placeholder, m.art, m.corners]
        node.width = w
        node.height = ah
    end for
    ' Decode artwork at card size; full-size posters fill texture memory.
    ' Zoom fills the card like the Apple apps' aspect fill: posters that
    ' aren't exactly 2:3 are trimmed at the edges rather than letterboxed
    ' with dark bars that look like clipped artwork. loadWidth/Height keep
    ' the decoded bitmap at card size either way.
    m.art.loadWidth = w
    m.art.loadHeight = ah
    m.fallback.width = w - 24
    m.fallback.height = ah
    m.fallback.translation = [12, 0]
    m.ring.width = w + 16
    m.ring.height = ah + 16
    m.ring.translation = [-8, -8]
    ' Lift from a quarter of the way down, not the middle: the list clips at
    ' the 12 px inset, and a centred 1.045 lift pushed the 8 px focus ring
    ' past it (about 4 px cut off the top on Roku, Nov 24). The bottom still
    ' clears the title.
    m.lift.scaleRotateCenter = [w / 2, Int(ah / 4)]
    m.title.width = w
    m.caption.width = w
    ' Below the focus ring of a lifted card (ring 8 px out plus the lift).
    m.title.translation = [0, ah + 20]
    m.caption.translation = [0, ah + 51]
    m.fill.translation = [8, ah - 10]
    m.liveDot.translation = [14, 14]
    ' Game layer: each crest fitted into 28% x 56% of the card around "VS".
    cw = Int(w * 0.28)
    ch = Int(ah * 0.56)
    gap = Int(w * 0.035)
    vw = 44
    left = Int((w - cw * 2 - gap * 2 - vw) / 2)
    top = Int((ah - ch) / 2)
    m.gameBack.width = w
    m.gameBack.height = ah
    for i = 0 to 1
        m.crests[i].width = cw
        m.crests[i].height = ch
        m.crests[i].loadWidth = cw
        m.crests[i].loadHeight = ch
    end for
    m.crests[0].translation = [left, top]
    m.versus.width = vw
    m.versus.height = ch
    m.versus.translation = [left + cw + gap, top]
    m.crests[1].translation = [left + cw + gap * 2 + vw, top]
    update()
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid
        ' A list that drops its content keeps its item components; let go
        ' of the artwork so Roku can evict the bitmap.
        m.art.uri = ""
        return
    end if
    landscape = CardWidth() >= 300
    uri = c.HDPosterUrl
    if landscape and c.landscapeUrl <> invalid and c.landscapeUrl <> "" then uri = c.landscapeUrl
    if not landscape and (uri = invalid or uri = "") and c.landscapeUrl <> invalid then uri = c.landscapeUrl
    if uri = invalid then uri = ""
    m.art.uri = uri
    title = c.title
    if c.itemType = "Episode" and c.seriesName <> "" then title = c.seriesName
    m.fallback.text = title
    m.fallback.visible = uri = ""
    m.title.text = title
    caption = c.caption
    if c.itemType = "TvChannel" and c.programName <> "" then caption = c.programName
    if caption = "" and c.itemType = "TvChannel" then caption = "Live TV"
    m.caption.text = caption
    m.liveDot.visible = c.itemType = "TvChannel"
    ' A game starts as the channel card and switches only when both crests
    ' are in; clearing first also stops a recycled card showing old crests.
    m.game.visible = false
    m.gameStatus.visible = false
    g = c.game
    paired = landscape and ZIsMap(g) and ZIsArray(g.crests) and g.crests.count() = 2
    for i = 0 to 1
        if paired then m.crests[i].uri = ZStr(g.crests[i]) else m.crests[i].uri = ""
    end for
    if paired then onCrest()
    update()
end sub

' Both crests or neither: a failed or missing image keeps the channel card.
sub onCrest()
    c = m.top.itemContent
    if c = invalid or not ZIsMap(c.game) then return
    if m.crests[0].uri = "" or m.crests[0].loadStatus <> "ready" or m.crests[1].loadStatus <> "ready" then return
    if m.game.visible then return
    m.game.visible = true
    m.fallback.visible = false
    m.liveDot.visible = false
    m.title.text = ZStr(c.game.title)
    ' Channel, then the jade status on the same line.
    channel = ZStr(c.title)
    m.caption.text = channel
    m.gameStatus.text = ZStr(c.game.status)
    used = ZTextWidth(channel + "  ", m.caption.font)
    room = CardWidth() - used
    if room < 110 then
        m.caption.text = ""
        used = 0
        room = CardWidth()
    end if
    m.gameStatus.width = room
    m.gameStatus.translation = [used, m.artHeight + 51]
    m.gameStatus.visible = ViewerPrefs().showTitles <> false
end sub

sub update()
    c = m.top.itemContent
    if c = invalid or CardWidth() <= 0 then return
    prefs = ViewerPrefs()
    w = CardWidth()
    ah = m.artHeight

    showTitles = prefs.showTitles <> false
    m.title.visible = showTitles
    m.caption.visible = showTitles
    if not showTitles then m.gameStatus.visible = false

    ' Progress: watched share of a title, or how far the current programme is.
    p = c.progress
    show = prefs.showProgress <> false and p <> invalid and p > 0.01 and p < 0.99 and c.played <> true
    if c.itemType = "TvChannel" and c.programStart > 0 and c.programEnd > c.programStart then
        now = ZNowSeconds()
        p = (now - c.programStart) / (c.programEnd - c.programStart)
        show = p > 0 and p < 1
    end if
    m.fill.visible = show
    if show then m.fill.width = Int((w - 16) * p)

    ' Rating pill (top right), only when the viewer turns ratings on.
    rating = c.communityRating
    if prefs.showRatings = true and rating <> invalid and rating > 0 and c.itemType <> "TvChannel" then
        m.ratingText.text = "★ " + ZOneDecimalText(rating)
        pillW = ZTextWidth(m.ratingText.text, m.ratingText.font) + 20
        m.ratingPill.width = pillW
        m.ratingText.width = pillW
        m.ratingGroup.translation = [w - pillW - 12, 12]
        m.ratingGroup.visible = true
    else
        m.ratingGroup.visible = false
    end if

    ' Quality badges in one pill: "4K · HDR10".
    badges = c.badges
    if prefs.showQualityBadges <> false and badges <> invalid and badges.count() > 0 then
        m.badgeText.text = ZJoin(badges, " · ")
        bw = ZTextWidth(m.badgeText.text, m.badgeText.font) + 14
        bottom = 8
        if show then bottom = 16
        m.badgePill.width = bw
        m.badgeText.width = bw
        m.badgePill.translation = [8, ah - bottom - 26]
        m.badgeText.translation = [8, ah - bottom - 26]
        m.badgePill.visible = true
        m.badgeText.visible = true
    else
        m.badgePill.visible = false
        m.badgeText.visible = false
    end if
end sub

sub onFocus()
    ' A shelf that doesn't hold focus shows no ring, like Apple TV.
    p = m.top.focusPercent
    if m.top.rowListHasFocus <> true and m.top.gridHasFocus <> true then p = 0
    m.ring.opacity = p
    s = 1 + 0.045 * p
    m.lift.scale = [s, s]
end sub
