sub init()
    m.top.focusable = true
    m.heading = m.top.findNode("heading")
    m.row = m.top.findNode("row")
    m.row.observeField("rowItemFocused", "onFocused")
    m.row.observeField("rowItemSelected", "onSelected")
    m.top.observeField("focusedChild", "onFocusChange")
end sub

sub onTitle()
    m.heading.removeChildrenIndex(m.heading.getChildCount(), 0)
    if m.top.title <> "" then m.heading.appendChild(ZSectionTitle(m.top.title, 96, 0))
end sub

' Card sizes from the Apple TV MediaCard: 212 x 318 posters, 360 x 202 art,
' then a 22 pt title and 17 pt caption; 18 px room for the focus lift.
function CardSize() as object
    scale = 1.0
    s = m.global.settings
    if s <> invalid and s.posterScale <> invalid then scale = s.posterScale
    ' Fixed widths: Apple's 380 px episode cards and 180 px person cards.
    w = m.top.cardWidth
    ' Each size includes the card's 12 px focus inset (MediaCard frame).
    if w > 0 and m.top.landscape then return [w + 12, Int(w * 9 / 16) + 99]
    if w > 0 then return [w + 12, Int(w * 3 / 2) + 99]
    if m.top.landscape then return [Int(360 * scale) + 12, Int(202 * scale) + 99]
    return [Int(212 * scale) + 12, Int(318 * scale) + 99]
end function

sub onContent()
    items = m.top.content
    if items = invalid then return
    size = CardSize()
    wrapper = CreateObject("roSGNode", "ContentNode")
    ' A RowList needs rows: hand it a single row holding the cards.
    if items.getChildCount() > 0 and items.getChild(0).subtype() = "ZItem" then
        wrapper.appendChild(items)
    else
        wrapper = items
    end if
    m.row.itemComponentName = "MediaCard"
    m.row.drawFocusFeedback = false
    m.row.rowFocusAnimationStyle = "floatingFocus"
    m.row.vertFocusAnimationStyle = "fixedFocus"
    m.row.focusXOffset = [84]
    m.row.showRowLabel = [false]
    m.row.itemSize = [1920, size[1] + 18]
    m.row.rowItemSize = [size]
    m.row.rowHeights = [size[1] + 18]
    m.row.rowItemSpacing = [[16, 0]]
    m.row.numRows = 1
    m.wrapper = wrapper
    if not m.top.parked then m.row.content = wrapper
    ' Without a title the cards sit at the top (a heading is drawn elsewhere).
    top = 52
    if m.top.title = "" then top = 0
    ' Up by the inset so the cards themselves sit where they did.
    m.row.translation = [0, top - 12]
    m.top.height = top + size[1] + 6
end sub

' A parked shelf keeps its layout but drops the RowList content, so its
' cards (and their artwork) are freed until the page scrolls back near it.
sub onParked()
    if m.wrapper = invalid then return
    if m.top.parked then
        if m.row.content <> invalid then
            m.parkedIndex = m.top.focusIndex
            m.row.content = invalid
        end if
    else if m.row.content = invalid then
        m.row.content = m.wrapper
        if m.parkedIndex <> invalid and m.parkedIndex > 0 then m.row.jumpToRowItem = [0, m.parkedIndex]
    end if
end sub

sub onJump()
    if m.top.jumpTo >= 0 then m.row.jumpToRowItem = [0, m.top.jumpTo]
end sub

function Current() as dynamic
    f = m.row.rowItemFocused
    if f = invalid or f.count() < 2 or m.row.content = invalid then return invalid
    row = m.row.content.getChild(f[0])
    if row = invalid then return invalid
    return row.getChild(f[1])
end function

sub onFocused()
    f = m.row.rowItemFocused
    if f <> invalid and f.count() = 2 then m.top.focusIndex = f[1]
    item = Current()
    if item <> invalid then m.top.itemFocused = item
end sub

sub onSelected()
    item = Current()
    if item <> invalid then m.top.itemSelected = item
end sub

sub onFocusChange()
    if m.top.hasFocus() then m.row.setFocus(true)
end sub
