sub init()
    m.grid = m.top.findNode("grid")
    m.filters = m.top.findNode("filters")
    m.status = m.top.findNode("status")
    m.top.findNode("title").font = ZFont(56, "bold")
    m.top.findNode("count").font = ZFont(24)
    m.status.font = ZFont(30)
    m.filters.buttonHeight = 60
    m.filters.fontSize = 24
    m.filters.minWidth = 140
    m.filters.observeField("selected", "onFilter")
    m.grid.observeField("itemFocused", "onItemFocused")
    m.grid.observeField("itemSelected", "onItemSelected")
    m.sorts = [
        { id: "SortName", label: "A to Z", order: "Ascending" },
        { id: "DateCreated,SortName", label: "Recently added", order: "Descending" },
        { id: "CommunityRating,SortName", label: "Top rated", order: "Descending" },
        { id: "ProductionYear,SortName", label: "Newest", order: "Descending" }
    ]
    m.filtersList = [
        { id: "all", label: "All" },
        { id: "unplayed", label: "Unwatched" },
        { id: "favorites", label: "Favorites" }
    ]
    m.sortIndex = 0
    m.filterIndex = 0
    m.total = 0
    m.loading = false
end sub

sub onConfig()
    c = m.top.config
    m.top.findNode("title").text = ZStr(c.title, "Library")
    for i = 0 to m.sorts.count() - 1
        if m.sorts[i].id = c.sortBy then m.sortIndex = i
    end for
    paintFilters()
    reload()
end sub

sub paintFilters()
    focus = m.filters.focusIndex
    m.filters.buttons = [
        { id: "sort", text: "Sort: " + m.sorts[m.sortIndex].label },
        { id: "filter", text: "Show: " + m.filtersList[m.filterIndex].label }
    ]
    m.filters.focusIndex = focus
end sub

sub reload()
    m.content = CreateObject("roSGNode", "ContentNode")
    m.grid.content = m.content
    m.total = 0
    m.status.text = "Loading…"
    fetch(0)
end sub

sub fetch(start as integer)
    if m.loading then return
    m.loading = true
    c = m.top.config
    s = m.sorts[m.sortIndex]
    f = m.filtersList[m.filterIndex].id
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = {
        cmd: "items", types: ZStr(c.types), parentId: ZStr(c.parentId), startIndex: start, limit: 42,
        sortBy: s.id, sortOrder: s.order, unplayed: f = "unplayed", favorites: f = "favorites"
    }
    task.observeField("response", "onPage")
    task.control = "RUN"
    m.task = task
end sub

sub onPage(event as object)
    m.loading = false
    r = event.getData()
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        m.status.text = ZErrorText(r.error)
        return
    end if
    page = m.task.content
    while page.getChildCount() > 0
        child = page.getChild(0)
        page.removeChildIndex(0)
        m.content.appendChild(child)
    end while
    m.total = r.total
    m.status.text = ""
    if m.content.getChildCount() = 0 then m.status.text = "Nothing here yet."
    noun = " titles"
    if m.total = 1 then noun = " title"
    m.top.findNode("count").text = m.total.toStr() + noun
    if m.top.isInFocusChain() and not m.filters.isInFocusChain() then restoreFocus()
end sub

sub restoreFocus()
    if m.content <> invalid and m.content.getChildCount() > 0 then
        m.grid.setFocus(true)
    else
        m.filters.setFocus(true)
    end if
end sub

sub onItemFocused()
    i = m.grid.itemFocused
    loaded = m.content.getChildCount()
    if i >= loaded - 21 and loaded < m.total then fetch(loaded)
end sub

sub onItemSelected()
    item = m.content.getChild(m.grid.itemSelected)
    if item <> invalid then m.top.navigate = ZCardAction(item)
end sub

sub onFilter(event as object)
    if event.getData() = "sort" then
        m.sortIndex = (m.sortIndex + 1) mod m.sorts.count()
    else
        m.filterIndex = (m.filterIndex + 1) mod m.filtersList.count()
    end if
    paintFilters()
    reload()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "up" and m.grid.isInFocusChain() and m.grid.itemFocused < 7 then
        m.filters.setFocus(true)
        return true
    end if
    if key = "down" and m.filters.isInFocusChain() and m.content <> invalid and m.content.getChildCount() > 0 then
        m.grid.setFocus(true)
        return true
    end if
    if key = "play" and m.grid.isInFocusChain() then
        item = m.content.getChild(m.grid.itemFocused)
        if item <> invalid and item.itemType = "Movie" then
            m.top.navigate = { to: "player", id: item.id, startTicks: item.positionTicks, live: item.itemType = "TvChannel" }
            return true
        end if
    end if
    return false
end function
