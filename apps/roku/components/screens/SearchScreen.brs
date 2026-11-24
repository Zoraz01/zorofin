' See SearchScreen.xml. Searches 0.3 s after typing stops (Apple waits
' 300 ms); suggestions come from Search/Hints, results from Items by type.

sub init()
    m.keyboard = m.top.findNode("keyboard")
    m.results = m.top.findNode("results")
    m.suggestions = m.top.findNode("suggestions")
    m.top.findNode("heading").font = ZFont(44, "bold")
    m.top.findNode("statusTitle").font = ZFont(32, "bold")
    m.top.findNode("statusText").font = ZFont(24)
    m.debounce = m.top.findNode("debounce")
    m.debounce.observeField("fire", "search")
    m.keyboard.observeField("text", "onText")
    m.results.observeField("rowItemSelected", "onSelected")
    m.suggestions.observeField("selected", "onSuggestion")
    m.lastTerm = invalid
    m.hints = []
    search()
end sub

sub restoreFocus()
    m.keyboard.setFocus(true)
end sub

sub onText()
    m.debounce.control = "stop"
    m.debounce.control = "start"
end sub

sub setStatus(title as string, text as string)
    m.top.findNode("statusTitle").text = title
    m.top.findNode("statusText").text = text
    m.top.findNode("status").visible = title <> "" or text <> ""
end sub

sub search()
    term = m.keyboard.text.trim()
    if m.lastTerm <> invalid and term = m.lastTerm then return
    m.lastTerm = term
    task = CreateObject("roSGNode", "JellyfinTask")
    if Len(term) < 2 then
        ' An empty search shows Recommended titles.
        showHints([])
        task.request = { cmd: "search", recommend: true }
        if m.picks <> invalid then
            showContent(m.picks)
            return
        end if
        setStatus("", "Finding recommendations…")
    else
        task.request = { cmd: "search", term: term }
        setStatus("", "Searching…")
        hints = CreateObject("roSGNode", "JellyfinTask")
        hints.request = { cmd: "searchHints", term: term }
        hints.observeField("response", "onHints")
        hints.control = "RUN"
        m.hintTask = hints
    end if
    task.observeField("response", "onResults")
    task.control = "RUN"
    m.task = task
end sub

sub onResults(event as object)
    r = event.getData()
    if r.recommend = true then
        if m.keyboard.text.trim().len() >= 2 then return
    else if r.term <> m.keyboard.text.trim() then
        return
    end if
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        setStatus("Search isn't available", ZErrorText(r.error))
        return
    end if
    content = m.task.content
    if r.recommend = true then
        if content.getChildCount() = 0 then
            m.results.content = invalid
            setStatus("Explore your library", "Recommended movies and shows will appear here as your library grows.")
            return
        end if
        m.picks = content
    else if content.getChildCount() = 0 then
        m.results.content = invalid
        setStatus("No matching titles", "Try another title or spelling.")
        return
    end if
    showContent(content)
end sub

sub showContent(content as object)
    setStatus("", "")
    hadFocus = m.results.isInFocusChain()
    ZSetupRows(m.results, content, 28, 1280, 40)
    m.results.numRows = 2
    if hadFocus then m.results.setFocus(true)
end sub

sub onSelected()
    f = m.results.rowItemSelected
    item = m.results.content.getChild(f[0]).getChild(f[1])
    if item <> invalid then m.top.navigate = ZCardAction(item)
end sub

sub onHints(event as object)
    r = event.getData()
    if r.term <> m.keyboard.text.trim() then return
    if r.ok then showHints(r.hints) else showHints([])
end sub

sub showHints(hints as object)
    m.hints = hints
    buttons = []
    width = 0
    for each h in hints
        text = ZTruncate(h.name, 26)
        w = ZTextWidth(text, ZFont(22, "semibold")) + 90
        if width + w <= 1200 then
            icon = "film"
            if h.kind = "Series" or h.kind = "Episode" then icon = "tv"
            if h.kind = "TvChannel" then icon = "live"
            buttons.push({ id: h.id, text: text, icon: icon })
            width = width + w + 12
        end if
    end for
    hadFocus = m.suggestions.isInFocusChain()
    m.suggestions.buttons = buttons
    m.suggestions.visible = buttons.count() > 0
    ' Results sit under the top matches when there are any.
    if buttons.count() > 0 then m.results.translation = [640, 236] else m.results.translation = [640, 150]
    if hadFocus and buttons.count() = 0 then m.keyboard.setFocus(true)
end sub

sub onSuggestion(event as object)
    id = event.getData()
    for each h in m.hints
        if h.id = id then
            if h.kind = "TvChannel" then
                m.top.navigate = { to: "player", id: h.id, live: true }
            else
                m.top.navigate = { to: "detail", id: h.id }
            end if
        end if
    end for
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "right" and m.keyboard.isInFocusChain() then
        if m.suggestions.visible then
            m.suggestions.setFocus(true)
        else if m.results.content <> invalid then
            m.results.setFocus(true)
        end if
        return true
    end if
    if key = "left" and m.suggestions.isInFocusChain() then
        m.keyboard.setFocus(true)
        return true
    end if
    if key = "down" and m.suggestions.isInFocusChain() and m.results.content <> invalid then
        m.results.setFocus(true)
        return true
    end if
    if key = "up" and m.results.isInFocusChain() and m.suggestions.visible then
        f = m.results.rowItemFocused
        if f = invalid or f[0] = 0 then
            m.suggestions.setFocus(true)
            return true
        end if
    end if
    if key = "left" and m.results.isInFocusChain() then
        f = m.results.rowItemFocused
        if f = invalid or f[1] = 0 then
            m.keyboard.setFocus(true)
            return true
        end if
    end if
    return false
end function
