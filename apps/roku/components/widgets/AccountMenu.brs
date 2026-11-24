sub init()
    m.card = m.top.findNode("card")
    m.list = m.top.findNode("list")
    m.top.findNode("server").font = ZFont(25, "semibold")
    m.top.findNode("initial").font = ZFont(21, "semibold")
    m.list.observeField("selected", "onSelected")
end sub

sub refresh(params = invalid as dynamic)
    width = 460
    m.list.width = width - 32
    m.list.maxHeight = 640
    m.top.findNode("server").text = ZStr(m.top.serverName, "Accounts")
    m.top.findNode("server").width = width - 92
    m.top.findNode("initial").text = UCase(Left(m.top.userName, 1))
    m.top.findNode("avatar").uri = m.top.userImage
    m.top.findNode("topLine").width = width
    rows = []
    focusKey = ""
    for each a in m.top.accounts
        current = a.key = m.top.currentKey
        rows.push({
            id: "account:" + a.key, title: ZStr(a.userName), subtitle: ZStr(a.serverName, ZStr(a.server)),
            avatar: ZUserImageUrl(a.server, a.userId, ZStr(a.imageTag), 96), initial: UCase(Left(ZStr(a.userName), 1)),
            checked: current, current: current
        })
        if current then focusKey = "account:" + a.key
    end for
    if rows.count() = 0 then rows.push({ id: "none", title: "No saved accounts", disabled: true })
    rows.push({ divider: true })
    rows.push({ id: "servers", title: "Change server", icon: "server" })
    rows.push({ id: "quickConnect", title: "Quick Connect", icon: "phone" })
    if m.top.watchTogether then rows.push({ id: "watchTogether", title: "Watch together", icon: "users" })
    rows.push({ divider: true })
    rows.push({ id: "settings", title: "Settings", icon: "settings" })
    m.list.rows = rows
    if focusKey <> "" then m.list.callFunc("focusRow", focusKey)
    height = 88 + m.list.height + 16
    bg = m.top.findNode("bg")
    edge = m.top.findNode("edge")
    bg.width = width
    bg.height = height
    edge.width = width
    edge.height = height
    ' Right edge 16 px past the avatar, just under the header.
    m.card.translation = [1824 - width + 16, 114]
end sub

sub takeFocus()
    m.list.setFocus(true)
end sub

sub onSelected(event as object)
    id = event.getData()
    if Left(id, 8) = "account:" then
        m.top.action = { type: "switch", key: Mid(id, 9) }
    else
        m.top.action = { type: id }
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if key = "back" or key = "options" then
        m.top.action = { type: "close" }
        return true
    end if
    ' The popover is modal.
    return true
end function
