' Apple TV MediaCard (LibraryViews.swift): 12 px corners, white focus ring
' and a 1.045 lift, quality badges in one dark pill at the bottom left, a
' 4 px jade progress line, an optional rating pill at the top right, then a
' 22 pt title and a 17 pt caption. Display settings follow the viewer's
' Profile choices in m.global.settings.

sub init()
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
    ' scaleToFit (not Zoom) keeps an odd-shaped image inside the card's
    ' size instead of decoding it wider than the screen.
    m.art.loadWidth = w
    m.art.loadHeight = ah
    m.fallback.width = w - 24
    m.fallback.height = ah
    m.fallback.translation = [12, 0]
    m.ring.width = w + 16
    m.ring.height = ah + 16
    m.ring.translation = [-8, -8]
    m.lift.scaleRotateCenter = [w / 2, ah / 2]
    m.title.width = w
    m.caption.width = w
    ' Below the focus ring of a lifted card (ring 8 px out plus the lift).
    m.title.translation = [0, ah + 20]
    m.caption.translation = [0, ah + 51]
    m.fill.translation = [8, ah - 10]
    m.liveDot.translation = [14, 14]
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
    update()
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
