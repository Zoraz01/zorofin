' Live now card. Text uses only the shared type scale (ZTypeStyle): every
' extra size costs a permanent glyph atlas in texture memory.

sub init()
    m.lift = m.top.findNode("lift")
    m.art = m.top.findNode("art")
    m.art.observeField("loadStatus", "onArtLoaded")
    m.rejectedArt = ""
    m.liveDot = m.top.findNode("liveDot")
    m.logo = m.top.findNode("logo")
    m.crests = [m.top.findNode("awayCrest"), m.top.findNode("homeCrest")]
    m.placeholder = m.top.findNode("placeholder")
    m.tint = m.top.findNode("tint")
    m.fade = m.top.findNode("fade")
    m.teams = m.top.findNode("teams")
    m.sportLabel = m.top.findNode("sportLabel")
    m.sport = m.top.findNode("sport")
    m.corners = m.top.findNode("corners")
    m.ring = m.top.findNode("ring")
    m.fill = m.top.findNode("progressFill")
    m.fill.color = ZAccent()
    m.livePill = m.top.findNode("livePill")
    m.liveText = m.top.findNode("liveText")
    m.starPill = m.top.findNode("starPill")
    m.starText = m.top.findNode("starText")
    m.title = m.top.findNode("title")
    m.caption = m.top.findNode("caption")
    m.title.font = ZFont(22, "semibold")
    m.caption.font = ZFont(18)
    m.sportLabel.font = ZFont(22, "semibold")
    m.liveText.font = ZFont(18, "semibold")
    m.starText.font = ZFont(18, "semibold")
    m.sides = {}
    for each side in ["away", "home"]
        m.sides[side] = { row: m.top.findNode(side + "Row"), name: m.top.findNode(side + "Name"), score: m.top.findNode(side + "Score") }
        m.sides[side].name.font = ZFont(30, "semibold")
        m.sides[side].score.font = ZFont(30, "semibold")
    end for
    m.artHeight = 0
end sub

function CardWidth() as float
    return m.top.width - 12
end function

sub layout()
    w = CardWidth()
    if w <= 0 then return
    ah = Int(w * 9 / 16)
    m.artHeight = ah
    for each node in [m.placeholder, m.sport, m.tint, m.art, m.corners, m.fade]
        node.width = w
        node.height = ah
    end for
    m.art.loadWidth = w
    m.art.loadHeight = ah
    m.sport.loadWidth = w
    m.sport.loadHeight = ah
    m.logo.width = Int(w * 0.45)
    m.logo.height = Int(ah * 0.4)
    m.logo.loadWidth = m.logo.width
    m.logo.loadHeight = m.logo.height
    m.logo.translation = [Int((w - m.logo.width) / 2), Int(ah * 0.22)]
    ' Fixture crests side by side, top-aligned so the scores sit below them.
    cw = Int(w * 0.3)
    ch = Int(ah * 0.46)
    for i = 0 to 1
        crest = m.crests[i]
        crest.width = cw
        crest.height = ch
        crest.loadWidth = cw
        crest.loadHeight = ch
        crest.translation = [Int(w * (0.25 + 0.5 * i) - cw / 2), Int(ah * 0.1)]
    end for
    m.sportLabel.width = w
    m.sportLabel.translation = [0, Int(ah * 0.68)]
    ' Away then home at the bottom, name left and score right (18 px in).
    m.teams.translation = [18, ah - 14 - 74]
    for each key in ["away", "home"]
        s = m.sides[key]
        s.name.width = w - 36 - 76
        s.score.width = 66
        s.score.translation = [w - 36 - 66, 0]
    end for
    m.ring.width = w + 16
    m.ring.height = ah + 16
    m.ring.translation = [-8, -8]
    ' Lift from a quarter of the way down, not the middle: the list clips at
    ' the 12 px inset, and a centred 1.045 lift pushed the 8 px focus ring
    ' past it (about 4 px cut off the top on Roku, Nov 24). The bottom still
    ' clears the title.
    m.lift.scaleRotateCenter = [w / 2, Int(ah / 4)]
    ' Dark pill with a red dot, as on the web and the other apps.
    textW = ZTextWidth("LIVE", m.liveText.font)
    m.livePill.width = textW + 44
    m.liveText.width = textW
    m.livePill.translation = [12, 12]
    m.liveDot.translation = [26, 22]
    m.liveText.translation = [44, 12]
    m.starPill.translation = [w - 50, 12]
    m.starText.translation = [w - 50, 12]
    m.fill.translation = [8, ah - 10]
    m.title.width = w
    m.caption.width = w
    ' Below the focus ring of a lifted card, as MediaCard.
    m.title.translation = [0, ah + 20]
    m.caption.translation = [0, ah + 51]
    onContent()
end sub

sub onContent()
    c = m.top.itemContent
    if c = invalid then
        m.art.uri = ""
        m.logo.uri = ""
        for each crest in m.crests
            crest.uri = ""
        end for
        return
    end if
    if CardWidth() <= 0 then return
    live = c.live
    if live = invalid then live = {}
    score = live.score
    scored = ZIsMap(score)
    uri = ZStr(c.landscapeUrl)
    if uri = m.rejectedArt then uri = ""
    hasArt = uri <> ""
    m.art.uri = uri
    m.art.visible = hasArt
    ' The task selects a fixture photo, two crests, or a programme image.
    ' Without any of those, Sports cards take the sport's illustration (web,
    ' Apple, Flutter); On now cards take the channel logo, as Apple's
    ' programme browser does.
    logos = live.logos
    crested = not hasArt and ZIsArray(logos) and logos.count() = 2
    for i = 0 to 1
        if crested then m.crests[i].uri = ZStr(logos[i]) else m.crests[i].uri = ""
        m.crests[i].visible = crested
    end for
    m.logo.uri = ""
    onNow = live.onNow = true
    if not hasArt and not crested and not scored and onNow then m.logo.uri = ZStr(c.logoUrl)
    ' Scored games without art get the team-tinted card.
    m.tint.visible = scored and not hasArt
    if m.tint.visible then m.tint.color = ZLiveTint(score)
    showSport = not hasArt and not crested and not scored and not onNow
    m.sport.uri = ""
    if showSport then m.sport.uri = ZLiveSportArt(ZStr(live.kind, "event"))
    m.sport.visible = showSport
    m.sportLabel.visible = false
    favorite = live.favoriteTeam = true
    m.starPill.visible = favorite
    m.starText.visible = favorite
    final = scored and score.final = true
    m.livePill.visible = not final and (live.onNow <> true or live.isLive = true)
    m.liveText.visible = m.livePill.visible
    m.liveDot.visible = m.livePill.visible
    m.fade.visible = scored
    m.teams.visible = scored
    if scored then
        showScore(score)
        m.title.text = ZLiveStatus(score, ZStr(live.competition))
        m.caption.text = ZLiveChannelLine(ZStr(live.channel, c.title), ZStr(live.number), favorite)
    else
        m.title.text = ZStr(live.name, c.title)
        ' "ESPN 2 · Ch 11" on every unscored card, as web and Apple caption it.
        m.caption.text = ZLiveChannelLine(ZStr(live.channel, c.title), ZStr(live.number), favorite)
    end if
    ' Programme progress, except under the scores.
    start = ZNum(live.start, 0)
    finish = ZNum(live.finish, 0)
    now = ZNowSeconds()
    if not scored and finish > start and now > start and now < finish then
        m.fill.width = Int((CardWidth() - 16) * (now - start) / (finish - start))
        m.fill.visible = true
    else
        m.fill.visible = false
    end if
end sub

sub showScore(score as object)
    away = Val(score.awayScore)
    home = Val(score.homeScore)
    for each key in ["away", "home"]
        s = m.sides[key]
        name = score[key + "Name"]
        if name = "" then name = score[key]
        s.name.text = name
        s.score.text = score[key + "Score"]
        ' On a final the trailing team is muted; the leader stays white.
        trailing = score.final = true and ((key = "away" and away < home) or (key = "home" and home < away))
        if trailing then s.row.opacity = 0.6 else s.row.opacity = 1
    end for
end sub

sub onFocus()
    p = m.top.focusPercent
    if m.top.rowListHasFocus <> true then p = 0
    m.ring.opacity = p
    s = 1 + 0.045 * p
    m.lift.scale = [s, s]
end sub

' A guide image that isn't roughly 16:9 is usually a channel logo or a
' presenter headshot: drop it so the card shows crests, the logo tile or the
' sport label instead (same rule as the web's Live TV pages).
sub onArtLoaded()
    ' An advertised programme image that fails to load (404) falls back the
    ' same way, instead of leaving a blank card (ESPN 2 On now, Nov 24).
    if m.art.loadStatus = "failed" and m.art.uri <> "" then
        m.rejectedArt = m.art.uri
        onContent()
        return
    end if
    if m.art.loadStatus <> "ready" then return
    w = m.art.bitmapWidth
    h = m.art.bitmapHeight
    if w <= 0 or h <= 0 then return
    ratio = w / h
    if ratio >= 1.6 and ratio <= 1.95 then return
    m.rejectedArt = m.art.uri
    onContent()
end sub
