sub init()
    m.video = m.top.findNode("video")
    m.loading = m.top.findNode("loading")
    m.skip = m.top.findNode("skip")
    m.upNext = m.top.findNode("upNext")
    m.errorBox = m.top.findNode("errorBox")
    m.panelLayer = m.top.findNode("panelLayer")
    m.top.findNode("loadingTitle").font = ZFont(48, "bold")
    m.top.findNode("loadingText").font = ZFont(28)
    m.top.findNode("skipText").font = ZFont(28, "semibold")
    m.top.findNode("upNextLabel").font = ZFont(24, "bold")
    m.top.findNode("upNextTitle").font = ZFont(28, "semibold")
    m.top.findNode("upNextHint").font = ZFont(22)
    m.top.findNode("errorTitle").font = ZFont(44, "bold")
    m.top.findNode("errorText").font = ZFont(28)
    m.video.observeField("state", "onState")
    m.video.observeField("position", "onPosition")
    m.progressTimer = m.top.findNode("progressTimer")
    m.progressTimer.observeField("fire", "reportProgress")
    m.tickTimer = m.top.findNode("tickTimer")
    m.tickTimer.observeField("fire", "onTick")
    m.startTimer = m.top.findNode("startTimer")
    m.startTimer.observeField("fire", "onStartTimeout")
    m.info = invalid
    m.started = false
    m.stopped = false
    m.next = invalid
    m.upNextShown = false
    m.upNextDismissed = false
    m.countdown = 0
    m.skippedIntro = false
    m.quality = 0
    m.subtitleUrl = ""
    m.tasks = []
end sub

' MARK: Start and restart

sub onStart()
    s = m.top.start
    if s = invalid then return
    m.request = { id: s.id, startTicks: ZNum(s.startTicks, 0) }
    settings = m.global.settings
    if settings <> invalid then m.quality = ZNum(settings.maxBitrate, 0)
    if settings <> invalid and settings.subtitles = "off" then m.request.subtitleIndex = -1
    requestPlayback()
end sub

sub requestPlayback()
    m.loading.visible = true
    m.errorBox.visible = false
    req = {
        cmd: "playback",
        id: m.request.id,
        startTicks: m.request.startTicks,
        settings: { maxBitrate: m.quality }
    }
    if m.request.audioIndex <> invalid then req.audioIndex = m.request.audioIndex
    if m.request.subtitleIndex <> invalid then req.subtitleIndex = m.request.subtitleIndex
    if m.request.forceTranscode = true then req.forceTranscode = true
    if m.quality > 0 then req.forceTranscode = true
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = req
    task.observeField("response", "onPlayback")
    task.control = "RUN"
    m.playTask = task
end sub

sub onPlayback(event as object)
    r = event.getData()
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        showError(r)
        return
    end if
    m.info = r
    m.top.findNode("loadingTitle").text = r.title
    m.top.findNode("cover").uri = r.backdrop
    content = CreateObject("roSGNode", "ContentNode")
    content.url = r.url
    content.streamFormat = r.streamFormat
    content.title = r.title
    if r.secondary <> "" then content.title = r.secondary + "  ·  " + r.title
    content.live = r.isLive
    if not r.isLive and r.startSeconds > 0 then content.PlayStart = r.startSeconds
    content.HttpCertificatesFile = "common:/certs/ca-bundle.crt"
    content.SwitchingStrategy = "full-adaptation"

    ' External text subtitles are side-loaded; the chosen one is switched on.
    tracks = []
    m.subtitleUrl = ""
    for each s in r.subtitles
        if s.url <> "" then
            tracks.push({ TrackName: s.url, Language: s.language, Description: s.title })
            if s.index = r.subtitleIndex then m.subtitleUrl = s.url
        end if
    end for
    settings = m.global.settings
    if m.subtitleUrl = "" and settings <> invalid and settings.subtitles = "always" and m.request.subtitleIndex = invalid then
        for each s in r.subtitles
            if s.url <> "" and m.subtitleUrl = "" then
                m.subtitleUrl = s.url
                m.info.subtitleIndex = s.index
            end if
        end for
    end if
    content.subtitleTracks = tracks
    m.video.content = content
    if m.subtitleUrl <> "" then
        m.video.subtitleTrack = m.subtitleUrl
        m.video.globalCaptionMode = "On"
    else
        m.video.globalCaptionMode = "Off"
    end if
    m.started = false
    m.stopped = false
    m.startTimer.control = "stop"
    m.startTimer.control = "start"
    m.video.control = "play"
    m.video.setFocus(true)

    if r.type = "Episode" and m.next = invalid then
        task = CreateObject("roSGNode", "JellyfinTask")
        task.request = { cmd: "nextEpisode", id: r.id, seriesId: r.seriesId }
        task.observeField("response", "onNext")
        task.control = "RUN"
        m.nextTask = task
    end if
end sub

sub onNext(event as object)
    r = event.getData()
    if r.ok and r.next <> invalid then m.next = r.next
end sub

sub showError(r as object)
    m.loading.visible = false
    m.errorBox.visible = true
    text = ZErrorText(r.error)
    if r.error = "unplayable" then text = "The server couldn't find a version of this title this Roku can play. Ask the server owner to enable transcoding, or try another title."
    m.top.findNode("errorText").text = text + Chr(10) + Chr(10) + "Press Back to return."
    m.top.setFocus(true)
end sub

' Restarts the stream at the current position with new choices.
sub restartWith(changes as object)
    position = m.video.position
    report("stop")
    for each key in changes
        m.request[key] = changes[key]
    end for
    m.request.startTicks = ZSecondsToTicks(position)
    m.video.control = "stop"
    requestPlayback()
end sub

' MARK: Playback state and reporting

sub onState()
    state = m.video.state
    if state = "playing" then
        m.startTimer.control = "stop"
        m.loading.visible = false
        if not m.started then
            m.started = true
            report("start")
            m.progressTimer.control = "start"
            m.tickTimer.control = "start"
        else
            report("progress", "unpause")
        end if
    else if state = "paused" then
        report("progress", "pause")
    else if state = "finished" then
        report("stop")
        finished()
    else if state = "error" then
        report("stop")
        ' A direct-play failure gets one retry through the server's HLS.
        if m.info <> invalid and m.info.playMethod = "DirectPlay" and m.request.forceTranscode <> true then
            m.request.forceTranscode = true
            m.request.startTicks = ZSecondsToTicks(m.video.position)
            requestPlayback()
        else
            msg = m.video.errorMsg
            showError({ error: "unplayable" })
            if msg <> invalid and msg <> "" then m.top.findNode("errorText").text = "The Roku reported: " + msg + Chr(10) + Chr(10) + "Press Back to return."
        end if
    end if
end sub

sub reportProgress()
    if m.video.state = "playing" or m.video.state = "paused" then report("progress", "timeupdate")
end sub

sub report(kind as string, eventName = "timeupdate" as string)
    if m.info = invalid then return
    if kind = "stop" then
        ' A live channel that never started still holds a tuner: always stop it.
        if m.stopped then return
        if not m.started and m.info.liveStreamId = "" then return
        m.stopped = true
        m.progressTimer.control = "stop"
        m.tickTimer.control = "stop"
    end if
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = {
        cmd: "report", event: kind, eventName: eventName, id: m.info.id,
        mediaSourceId: m.info.mediaSourceId, playSessionId: m.info.playSessionId,
        liveStreamId: m.info.liveStreamId, playMethod: m.info.playMethod,
        position: m.video.position, paused: m.video.state = "paused", isLive: m.info.isLive,
        audioIndex: m.info.audioIndex, subtitleIndex: m.info.subtitleIndex
    }
    task.control = "RUN"
    ' Keep references so reports finish even while the screen closes.
    m.tasks.push(task)
    if m.tasks.count() > 6 then m.tasks.shift()
end sub

' Nothing played within the start window: say so instead of spinning.
sub onStartTimeout()
    if m.started or m.info = invalid then return
    report("stop")
    m.video.control = "stop"
    if m.info.isLive then
        showError({ error: "liveStart" })
        m.top.findNode("errorText").text = "This channel didn't start. The server may be busy or the channel may be off the air. Try again in a moment, or pick another channel." + Chr(10) + Chr(10) + "Press Back to return."
    else
        showError({ error: "timeout" })
    end if
end sub

sub onClosing()
    m.startTimer.control = "stop"
    report("stop")
    m.video.control = "stop"
    m.video.content = invalid
end sub

' MARK: Skip intro and Up next

sub onPosition()
    if m.info = invalid then return
    playhead = m.video.position
    settings = m.global.settings
    showSkip = false
    if settings = invalid or settings.skipIntro <> false then
        for each s in m.info.segments
            if s.type = "Intro" and playhead >= s.start and playhead < s.finish - 2 and not m.skippedIntro then showSkip = true
        end for
    end if
    if showSkip <> m.skip.visible then
        m.skip.visible = showSkip
        if showSkip then m.skip.setFocus(true) else if m.panel = invalid then m.video.setFocus(true)
    end if
    checkUpNext(playhead)
end sub

function creditsStart() as integer
    for each s in m.info.segments
        if s.type = "Outro" and s.start > 0 then return s.start
    end for
    if m.info.runtime > 0 then return m.info.runtime - 25
    return 0
end function

sub checkUpNext(playhead as dynamic)
    if m.next = invalid or m.upNextDismissed or m.info.isLive then return
    settings = m.global.settings
    if settings <> invalid and settings.autoplayNext = false then return
    at = creditsStart()
    if at > 0 and playhead >= at and not m.upNextShown then
        m.upNextShown = true
        m.countdown = 15
        remaining = m.info.runtime - Int(playhead)
        if remaining > 0 and remaining < m.countdown then m.countdown = remaining
        m.top.findNode("upNextArt").uri = m.next.image
        m.top.findNode("upNextTitle").text = m.next.label + "  " + m.next.title
        paintCountdown()
        m.upNext.visible = true
    end if
end sub

sub paintCountdown()
    m.top.findNode("upNextHint").text = "Starts in " + m.countdown.toStr() + "s · OK to play now, Back to keep watching"
end sub

sub onTick()
    refreshInfo()
    if m.upNext.visible then
        m.countdown = m.countdown - 1
        if m.countdown <= 0 then
            playNext()
        else
            paintCountdown()
        end if
    end if
end sub

sub playNext()
    if m.next = invalid then return
    playItem(m.next.id)
end sub

' Plays another episode or channel in place (Up next, Seasons & episodes,
' Channels & guide). Stopping first frees a Live TV tuner.
sub playItem(nextId as string, startTicks = 0 as dynamic)
    report("stop")
    m.video.control = "stop"
    m.upNext.visible = false
    m.upNextShown = false
    m.upNextDismissed = false
    m.skippedIntro = false
    m.next = invalid
    m.request = { id: nextId, startTicks: startTicks }
    settings = m.global.settings
    if settings <> invalid and settings.subtitles = "off" then m.request.subtitleIndex = -1
    requestPlayback()
end sub

sub finished()
    if m.next <> invalid and not m.upNextDismissed then
        settings = m.global.settings
        if settings = invalid or settings.autoplayNext <> false then
            playNext()
            return
        end if
    end if
    m.top.navigate = { to: "back" }
end sub

' MARK: Player options (Apple's transport bar menu and options surface)

' Options (* or Down) opens the menu: Seasons & episodes or Channels & guide,
' Audio & subtitles, Quality and Playback info. Back steps out a page.
sub openOptions(page = "menu" as string)
    if m.info = invalid then return
    if m.panel = invalid then
        panel = CreateObject("roSGNode", "PlayerPanel")
        panel.observeField("selected", "onPanelSelected")
        panel.observeField("back", "onPanelBack")
        m.panel = panel
        m.panelLayer.appendChild(panel)
        ' Browsing pauses a video (not live TV, and not for Playback info).
        m.pausedForPanel = false
    end if
    showPage(page)
    m.panel.focusIn = true
end sub

sub showPage(page as string)
    m.page = page
    info = m.info
    if not info.isLive and page <> "info" and page <> "menu" and m.video.state = "playing" then
        m.video.control = "pause"
        m.pausedForPanel = true
    end if
    p = m.panel
    p.wide = page = "episodes" or page = "channels" or page = "seasons"
    p.context = playerTitle()
    p.focusId = ""
    rows = []
    if page = "menu" then
        p.title = "Player options"
        if info.isLive then
            rows.push({ id: "channels", title: "Channels & guide", icon: "guide" })
        else if info.type = "Episode" and info.seriesId <> "" then
            rows.push({ id: "episodes", title: "Seasons & episodes", icon: "episodes" })
        end if
        if not info.isLive then rows.push({ id: "tracks", title: "Audio & subtitles", icon: "subtitles", value: trackSummary() })
        rows.push({ id: "quality", title: "Quality", icon: "gauge", value: qualityLabel(m.quality) })
        rows.push({ id: "info", title: "Playback info", icon: "info" })
        if m.lastMenu <> invalid then p.focusId = m.lastMenu
    else if page = "tracks" then
        p.title = "Audio & subtitles"
        if info.audioTracks.count() > 0 then
            rows.push({ header: true, title: "Audio" })
            for each a in info.audioTracks
                rows.push({ id: "a:" + a.index.toStr(), title: a.title, checked: a.index = info.audioIndex })
                if a.index = info.audioIndex then p.focusId = "a:" + a.index.toStr()
            end for
        end if
        rows.push({ header: true, title: "Subtitles" })
        current = -1
        if info.subtitleIndex <> invalid then current = info.subtitleIndex
        rows.push({ id: "s:-1", title: "Off", checked: current < 0 })
        for each t in info.subtitles
            label = t.title
            if t.forced then label = label + " (forced)"
            rows.push({ id: "s:" + t.index.toStr(), title: label, checked: t.index = current })
        end for
        if p.focusId = "" then p.focusId = "s:" + current.toStr()
    else if page = "quality" then
        p.title = "Quality"
        note = "Maximum streaming bitrate. Original quality plays when it fits this limit and this Roku."
        if info.isLive then note = "Changes restart at live."
        rows.push({ note: note })
        for each q in [0, 40, 20, 12, 8, 4, 2]
            value = q * 1000000
            rows.push({ id: "q:" + value.toStr(), title: qualityLabel(value), checked: value = m.quality })
        end for
        p.focusId = "q:" + Int(m.quality).toStr()
    else if page = "info" then
        p.title = "Playback info"
        rows = infoRows()
        p.focusId = "i:method"
    else if page = "episodes" then
        p.title = "Seasons & episodes"
        p.context = info.seriesName
        if m.episodes = invalid then
            rows.push({ note: "Loading episodes…" })
            loadEpisodes(m.browseSeason)
        else
            rows = episodeRows()
            p.focusId = "e:" + info.id
        end if
    else if page = "seasons" then
        p.title = "Choose a season"
        p.context = info.seriesName
        for each season in m.seasons
            rows.push({ id: "n:" + season.id, title: season.name, checked: season.id = m.browseSeason })
        end for
        p.focusId = "n:" + ZStr(m.browseSeason)
    else if page = "channels" then
        p.title = "Channels & guide"
        if m.channels <> invalid and ZNowSeconds() - ZNum(m.channelsAt, 0) > 120 then loadChannels()
        if m.channels = invalid then
            rows.push({ note: "Loading channels…" })
            loadChannels()
        else
            rows = channelRows()
            p.focusId = "c:" + info.id
        end if
    end if
    p.rows = rows
end sub

sub closeOptions()
    if m.panel <> invalid then
        m.panelLayer.removeChild(m.panel)
        m.panel = invalid
    end if
    m.lastMenu = invalid
    if m.pausedForPanel = true and m.video.state = "paused" then m.video.control = "resume"
    m.pausedForPanel = false
    m.video.setFocus(true)
end sub

sub onPanelBack()
    if m.page = "menu" then
        closeOptions()
    else if m.page = "seasons" then
        showPage("episodes")
    else
        showPage("menu")
    end if
end sub

sub onPanelSelected(event as object)
    id = event.getData()
    if id = "__close" then
        closeOptions()
        return
    end if
    if m.page = "menu" then
        m.lastMenu = id
        if id = "episodes" then m.browseSeason = m.info.seasonId
        showPage(id)
        return
    end if
    kind = Left(id, 2)
    value = Mid(id, 3)
    if kind = "a:" then
        index = value.toInt()
        closeOptions()
        if index <> m.info.audioIndex then restartWith({ audioIndex: index, forceTranscode: true })
    else if kind = "s:" then
        closeOptions()
        setSubtitle(value.toInt())
    else if kind = "q:" then
        q = value.toInt()
        closeOptions()
        if q <> m.quality then
            m.quality = q
            restartWith({ forceTranscode: q > 0 })
        end if
    else if kind = "e:" then
        closeOptions()
        if value <> m.info.id then
            ' A started episode resumes where the viewer left it.
            start = 0
            for each e in m.episodes
                if e.id = value and not e.played then start = e.positionTicks
            end for
            playItem(value, start)
        end if
    else if id = "season" then
        showPage("seasons")
    else if kind = "n:" then
        if value <> m.browseSeason then
            m.browseSeason = value
            m.episodes = invalid
        end if
        showPage("episodes")
    else if kind = "c:" then
        closeOptions()
        if value <> m.info.id then playItem(value)
    end if
end sub

function playerTitle() as string
    if m.info.secondary <> "" then return m.info.title + "  ·  " + m.info.secondary
    return m.info.title
end function

function qualityLabel(value as dynamic) as string
    if value <= 0 then return "Auto"
    return Int(value / 1000000).toStr() + " Mbps"
end function

function trackSummary() as string
    parts = []
    for each a in m.info.audioTracks
        if a.index = m.info.audioIndex then parts.push(TrackName(a.title))
    end for
    subtitle = "Subtitles off"
    for each t in m.info.subtitles
        if m.info.subtitleIndex <> invalid and t.index = m.info.subtitleIndex then subtitle = TrackName(t.title)
    end for
    parts.push(subtitle)
    return ZJoin(parts, " · ")
end function

' "English - AAC - Stereo" reads as "English" in the menu summary.
function TrackName(title as string) as string
    cut = Instr(1, title, " - ")
    if cut > 1 then return Left(title, cut - 1)
    return title
end function

' Apple's Playback info: how this stream plays now, then the source file.
function infoRows() as object
    info = m.info
    method = "Preparing"
    if info.playMethod = "DirectPlay" then method = "Direct play"
    if info.playMethod = "DirectStream" then method = "Direct stream"
    if info.playMethod = "Transcode" then method = "Transcoding"
    limit = qualityLabel(m.quality)
    if m.quality <= 0 and ZNum(info.maxBitrate, 0) > 0 then limit = "Auto, up to " + qualityLabel(info.maxBitrate)
    rows = [
        { id: "i:method", title: "Playback", value: method },
        { id: "i:limit", title: "Quality limit", value: limit },
        { id: "i:stream", title: "Stream bitrate", value: liveFact("stream") },
        { id: "i:network", title: "Network delivery", value: liveFact("network") },
        { id: "i:video", title: "Playing video", value: liveFact("video") },
        { id: "i:audio", title: "Playing audio", value: liveFact("audio") }
    ]
    if info.sourceBadges <> invalid and info.sourceBadges.count() > 0 then
        rows.push({ header: true, title: "Source file" })
        rows.push({ id: "i:source", title: ZJoin(info.sourceBadges, " · ") })
        rows.push({ note: "Source formats can differ from playback output." })
    end if
    return rows
end function

' Facts the Roku reports about the stream it is playing.
function liveFact(kind as string) as string
    si = m.video.streamInfo
    if kind = "stream" or kind = "network" then
        if not ZIsMap(si) then return "—"
        bits = ZNum(si.streamBitrate, 0)
        ' Roku's own figure is a placeholder on this hardware, so prefer
        ' what the server says it is sending.
        if kind = "stream" and m.info <> invalid and ZNum(m.info.streamBitrate, 0) > 0 then bits = m.info.streamBitrate
        if kind = "network" then bits = ZNum(si.measuredBitrate, 0)
        if bits <= 0 then return "—"
        return ZOneDecimalText(bits / 1000000) + " Mbps"
    end if
    value = ""
    if kind = "video" then value = ZStr(m.video.videoFormat)
    if kind = "audio" then value = ZStr(m.video.audioFormat)
    if value = "" then return "—"
    return ZCodecName(value)
end function

' Playback info stays current while it is open (called every second).
sub refreshInfo()
    if m.panel = invalid or m.page <> "info" then return
    for each kind in ["stream", "network", "video", "audio"]
        m.panel.callFunc("updateRow", { id: "i:" + kind, value: liveFact(kind) })
    end for
end sub

' MARK: Seasons & episodes

sub loadEpisodes(seasonId as dynamic)
    if m.seasons = invalid then
        task = CreateObject("roSGNode", "JellyfinTask")
        task.request = { cmd: "seasons", seriesId: m.info.seriesId }
        task.observeField("response", "onSeasons")
        task.control = "RUN"
        m.seasonsTask = task
    end if
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "episodes", seriesId: m.info.seriesId, seasonId: seasonId }
    task.observeField("response", "onEpisodes")
    task.control = "RUN"
    m.episodesTask = task
end sub

sub onSeasons(event as object)
    r = event.getData()
    if r.ok then m.seasons = r.seasons else m.seasons = []
    if m.panel <> invalid and m.page = "episodes" and m.episodes <> invalid then showPage("episodes")
end sub

sub onEpisodes(event as object)
    r = event.getData()
    if r.seasonId <> m.browseSeason then return
    list = []
    if r.ok and m.episodesTask.content <> invalid then
        for i = 0 to m.episodesTask.content.getChildCount() - 1
            list.push(m.episodesTask.content.getChild(i))
        end for
    end if
    m.episodes = list
    if m.panel <> invalid and m.page = "episodes" then
        showPage("episodes")
        m.panel.focusIn = true
    end if
end sub

function episodeRows() as object
    rows = []
    seasonName = ""
    if m.seasons <> invalid then
        for each season in m.seasons
            if season.id = m.browseSeason then seasonName = season.name
        end for
        if m.seasons.count() > 1 then rows.push({ id: "season", title: ZStr(seasonName, "Season"), icon: "chevron-down", value: "Change season" })
    end if
    if m.episodes.count() = 0 then
        rows.push({ note: "No episodes are available in this season." })
        return rows
    end if
    for each e in m.episodes
        label = e.title
        if e.episodeIndex >= 0 then label = "E" + e.episodeIndex.toStr() + " · " + e.title
        detail = []
        if e.runtimeTicks > 0 then detail.push(ZRuntimeText(e.runtimeTicks))
        if e.id = m.info.id then
            detail.push("Playing now")
        else if e.played then
            detail.push("Watched")
        else if e.progress > 0 then
            detail.push(ZRemainingText(e.runtimeTicks, e.positionTicks))
        end if
        rows.push({ id: "e:" + e.id, title: label, subtitle: ZJoin(detail, " · "), checked: e.id = m.info.id, current: e.id = m.info.id })
    end for
    return rows
end function

' MARK: Channels & guide

sub loadChannels()
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "guideChannels", withProgram: true }
    task.observeField("response", "onChannelList")
    task.control = "RUN"
    m.channelsTask = task
end sub

sub onChannelList(event as object)
    r = event.getData()
    if r.ok then m.channels = r.channels else m.channels = []
    m.channelsAt = ZNowSeconds()
    if m.panel <> invalid and m.page = "channels" then
        showPage("channels")
        m.panel.focusIn = true
    end if
end sub

function channelRows() as object
    rows = []
    if m.info.secondary <> "" then rows.push({ note: "Now · " + m.info.secondary })
    if m.channels.count() = 0 then
        rows.push({ note: "No channels are available for this account." })
        return rows
    end if
    for each c in m.channels
        rows.push({ id: "c:" + c.id, title: ZJoin([c.number, c.name], " · "), subtitle: c.program, checked: c.id = m.info.id, current: c.id = m.info.id })
    end for
    return rows
end function
sub setSubtitle(index as integer)
    if index < 0 then
        m.video.globalCaptionMode = "Off"
        m.info.subtitleIndex = -1
        ' A burned-in track needs a fresh stream without it.
        if m.burnedIn = true then
            m.burnedIn = false
            restartWith({ subtitleIndex: -1 })
        end if
        return
    end if
    for each s in m.info.subtitles
        if s.index = index then
            if s.url <> "" then
                m.video.subtitleTrack = s.url
                m.video.globalCaptionMode = "On"
                m.info.subtitleIndex = index
            else
                ' Image subtitles (PGS and similar) are burned in by the server.
                m.burnedIn = true
                restartWith({ subtitleIndex: index, forceTranscode: true })
            end if
        end if
    end for
end sub

sub restoreFocus()
    if m.panel <> invalid then
        m.panel.focusIn = true
    else if m.skip.visible then
        m.skip.setFocus(true)
    else
        m.video.setFocus(true)
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if m.upNext.visible then
        if key = "OK" or key = "play" then
            playNext()
            return true
        else if key = "back" then
            m.upNext.visible = false
            m.upNextDismissed = true
            return true
        end if
    end if
    if m.skip.visible and m.skip.isInFocusChain() then
        if key = "OK" then
            for each s in m.info.segments
                if s.type = "Intro" then m.video.seek = s.finish
            end for
            m.skippedIntro = true
            m.skip.visible = false
            m.video.setFocus(true)
            return true
        else if key = "play" then
            if m.video.state = "paused" then m.video.control = "resume" else m.video.control = "pause"
            return true
        else if key = "left" or key = "right" or key = "down" or key = "up" then
            m.skippedIntro = true
            m.skip.visible = false
            m.video.setFocus(true)
            return true
        end if
    end if
    ' Instant replay jumps back by the viewer's Controls setting.
    if key = "replay" and m.info <> invalid and not m.info.isLive and m.panel = invalid then
        back = 10
        if m.global.settings <> invalid and m.global.settings.skipBack <> invalid then back = m.global.settings.skipBack
        target = m.video.position - back
        if target < 0 then target = 0
        m.video.seek = target
        return true
    end if
    if (key = "options" or key = "down") and m.info <> invalid and m.panel = invalid then
        openOptions()
        return true
    end if
    ' Up on live TV goes straight to Channels & guide, like Apple's header button.
    if key = "up" and m.info <> invalid and m.info.isLive and m.panel = invalid then
        openOptions("channels")
        return true
    end if
    return false
end function
