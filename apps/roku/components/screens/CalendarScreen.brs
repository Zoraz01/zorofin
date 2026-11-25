sub init()
    m.page = m.top.findNode("page")
    m.page.id = "page"
    m.top.findNode("statusTitle").font = ZFont(30, "semibold")
    m.top.findNode("statusDetail").font = ZFont(22)
    ZPageInit(m.page, 140)
    m.filter = "all"
    m.task = invalid
    load()
end sub

sub load()
    showStatus("Loading the calendar…", "")
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "calendar", filter: m.filter }
    task.observeField("response", "onCalendar")
    task.control = "RUN"
    m.task = task
end sub

sub showStatus(title as string, detail as string)
    m.top.findNode("statusTitle").text = title
    m.top.findNode("statusDetail").text = detail
    m.top.findNode("statusGroup").visible = title <> ""
end sub

sub onCalendar(event as object)
    r = event.getData()
    content = m.task.content
    m.task = invalid
    if not r.ok then
        if r.error = "unauthorized" then
            m.top.sessionExpired = true
            return
        end if
        content = invalid
        if r.error = "notFound" then
            showStatus("The calendar is off", "Your server owner can turn it on in the Zorofin plugin settings.")
        else
            showStatus("Couldn't load the calendar", ZErrorText(r.error))
        end if
    else if content = invalid or content.getChildCount() = 0 then
        showStatus("Nothing coming up", "No new episodes or movie releases in the next four weeks.")
    else
        showStatus("", "")
    end if
    build(content)
end sub

sub build(content as dynamic)
    hadFocus = m.top.isInFocusChain()
    m.page.removeChildrenIndex(m.page.getChildCount(), 0)
    sections = []
    header = CreateObject("roSGNode", "Group")
    header.translation = [96, 0]
    title = CreateObject("roSGNode", "Label")
    title.font = ZFont(48, "bold")
    title.color = ZTheme().text
    title.text = "Calendar"
    header.appendChild(title)
    intro = CreateObject("roSGNode", "Label")
    intro.font = ZFont(22)
    intro.color = ZTheme().muted
    intro.text = "New episodes and movie releases over the next four weeks."
    intro.translation = [0, 64]
    header.appendChild(intro)
    m.page.appendChild(header)
    sections.push({ id: "header", node: header, focus: invalid, height: 100 })

    filters = CreateObject("roSGNode", "ButtonBar")
    filters.align = "left"
    filters.buttonHeight = 52
    filters.spacing = 12
    filters.translation = [96, 0]
    buttons = []
    for each f in [["all", "Everything"], ["shows", "Shows"], ["movies", "Movies"]]
        buttons.push({ id: f[0], text: f[1], primary: f[0] = m.filter })
    end for
    filters.buttons = buttons
    filters.observeField("selected", "onFilter")
    m.page.appendChild(filters)
    m.filters = filters
    sections.push({ id: "filters", node: filters, focus: filters, height: 56 })

    rows = []
    if content <> invalid then
        for i = 0 to content.getChildCount() - 1
            rows.push(content.getChild(i))
        end for
    end if
    for each row in rows
        if row.getChildCount() = 0 then
            empty = CreateObject("roSGNode", "ButtonBar")
            empty.align = "left"
            empty.translation = [96, 0]
            empty.buttonHeight = 52
            empty.buttons = [{ id: "empty", text: row.title + " · Nothing scheduled" }]
            m.page.appendChild(empty)
            sections.push({ id: row.id, node: empty, focus: empty, height: 56 })
        else
            shelf = CreateObject("roSGNode", "Shelf")
            shelf.title = row.title
            shelf.content = row
            shelf.observeField("itemSelected", "onItemSelected")
            m.page.appendChild(shelf)
            sections.push({ id: row.id, node: shelf, focus: shelf, height: shelf.height })
        end if
    end for
    ZPageSet(sections)
    if hadFocus or m.pageIndex < 0 then restoreFocus()
end sub

sub onFilter(event as object)
    id = event.getData()
    if id = m.filter then return
    m.filter = id
    load()
end sub

sub onItemSelected(event as object)
    item = event.getData()
    if item = invalid then return
    if item.id = "" then
        m.top.toast = item.title + " isn't on the server yet."
        return
    end if
    m.top.navigate = { to: "detail", id: item.id }
end sub

sub restoreFocus()
    if m.pageSections.count() = 0 then return
    index = m.pageIndex
    if not ZPageFocusable(index) then index = 1
    ZPageFocus(index, false)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "down" then return ZPageMove(1)
    if key = "up" then return ZPageMove(-1)
    return false
end function
