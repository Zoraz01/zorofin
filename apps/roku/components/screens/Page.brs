' Vertical page scrolling shared by Home, Details and Search, like the
' Apple TV ScrollView: sections stack top to bottom and the page moves only
' as far as needed to keep the focused section on screen.
'
' Call ZPageInit(group, top) once, ZPageSet(sections) whenever sections
' change, then ZPageMove(+1/-1) from onKeyEvent. A section is
' { node, focus (node to focus, or invalid when not focusable), height }.

sub ZPageInit(group as object, viewTop as integer, viewBottom = 1040 as integer)
    m.pageGroup = group
    m.pageTop = viewTop
    m.pageBottom = viewBottom
    m.pageOffset = 0
    m.pageIndex = -1
    m.pageSections = []
    anim = CreateObject("roSGNode", "Animation")
    anim.duration = 0.28
    anim.easeFunction = "outCubic"
    interp = CreateObject("roSGNode", "Vector2DFieldInterpolator")
    interp.key = [0.0, 1.0]
    interp.fieldToInterp = group.id + ".translation"
    anim.appendChild(interp)
    group.getParent().appendChild(anim)
    m.pageAnim = anim
    m.pageInterp = interp
    group.translation = [0, viewTop]
end sub

sub ZPageSet(sections as object, gap = 36 as integer)
    m.pageSections = sections
    y = 0
    for each s in sections
        s.node.translation = [s.node.translation[0], y]
        s.top = y
        y = y + s.height + gap
    end for
    m.pageHeight = y
    if m.pageIndex >= sections.count() then m.pageIndex = sections.count() - 1
    ZPageWindow(m.pageOffset)
end sub

' Parks sections (shelves) more than about a screen away from the visible
' part of the page so off-screen artwork doesn't fill texture memory.
sub ZPageWindow(offset as integer)
    viewHeight = m.pageBottom - m.pageTop
    lo = offset - Int(viewHeight / 2)
    hi = offset + Int(viewHeight * 3 / 2)
    for each s in m.pageSections
        if s.node.hasField("parked") then
            far = s.top + s.height < lo or s.top > hi
            if s.node.parked <> far then s.node.parked = far
        end if
    end for
end sub

function ZPageFocusable(index as integer) as boolean
    if index < 0 or index >= m.pageSections.count() then return false
    return m.pageSections[index].focus <> invalid
end function

' Focuses section index and scrolls it into view.
function ZPageFocus(index as integer, animate = true as boolean) as boolean
    if not ZPageFocusable(index) then return false
    m.pageIndex = index
    s = m.pageSections[index]
    s.focus.setFocus(true)
    ZPageScroll(index, animate)
    return true
end function

sub ZPageScroll(index as integer, animate = true as boolean)
    s = m.pageSections[index]
    offset = m.pageOffset
    viewHeight = m.pageBottom - m.pageTop
    ' The first focusable section shows the page from its top.
    first = true
    for i = 0 to index - 1
        if ZPageFocusable(i) then first = false
    end for
    if first then
        offset = 0
    else if s.top - offset < 0 then
        offset = s.top
    else if s.top + s.height - offset > viewHeight then
        offset = s.top + s.height - viewHeight
        if s.height > viewHeight then offset = s.top
    end if
    if offset < 0 then offset = 0
    if offset = m.pageOffset and m.pageGroup.translation[1] = m.pageTop - offset then return
    target = [m.pageGroup.translation[0], m.pageTop - offset]
    m.pageOffset = offset
    ZPageWindow(offset)
    reduce = false
    if m.global.settings <> invalid then reduce = m.global.settings.reduceMotion = true
    if animate and not reduce then
        m.pageAnim.control = "stop"
        m.pageInterp.keyValue = [m.pageGroup.translation, target]
        m.pageAnim.control = "start"
    else
        m.pageGroup.translation = target
    end if
end sub

' Moves focus to the next focusable section in a direction; false at the edge.
function ZPageMove(direction as integer) as boolean
    ' Start from the section that really holds focus; a refresh or a child
    ' can move focus without going through ZPageFocus.
    for j = 0 to m.pageSections.count() - 1
        if m.pageSections[j].node.isInFocusChain() then m.pageIndex = j
    end for
    i = m.pageIndex + direction
    while i >= 0 and i < m.pageSections.count()
        if ZPageFocusable(i) then return ZPageFocus(i)
        i = i + direction
    end while
    return false
end function

' Index of the section that holds node (or one of its descendants).
function ZPageIndexOf(node as object) as integer
    for i = 0 to m.pageSections.count() - 1
        if m.pageSections[i].node.isSameNode(node) then return i
    end for
    return -1
end function
