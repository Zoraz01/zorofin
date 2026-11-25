sub init()
    m.top.findNode("name").font = ZFont(36, "bold")
    m.top.findNode("server").font = ZFont(22)
    m.top.findNode("initial").font = ZFont(28, "bold")
    m.rows = m.top.findNode("rows")
    m.rows.observeField("selected", "onRow")
    m.dialog = invalid
    m.global.observeField("extras", "render")
    render()
end sub

sub render()
    s = m.global.session
    if s <> invalid then
        m.top.findNode("name").text = ZStr(s.userName)
        m.top.findNode("initial").text = UCase(Left(ZStr(s.userName), 1))
        m.top.findNode("server").text = ZStr(s.serverName)
        avatar = m.top.findNode("avatar")
        avatar.uri = ZUserImageUrl(ZStr(s.server), s.userId, s.imageTag, 128)
        m.top.findNode("avatarMask").visible = avatar.uri <> ""
    end if
    ' TV Settings, the same list on every TV app (docs/design/TV_PROFILE_MENU.md).
    ' Switching profiles, Pick/Watch Together, Calendar and Catch Up live in
    ' the avatar menu; Quick Connect is on Account, support and privacy on
    ' Help & about.
    rows = [
        { id: "settings:account", title: "Account", icon: "user", subtitle: "Name, password, Quick Connect" },
        { id: "settings:display", title: "Home & display", icon: "display", subtitle: "Posters, previews, badge" },
        { id: "settings:playback", title: "Playback", icon: "playback", subtitle: "Quality, Skip intro, chapters" },
        { id: "settings:subtitles", title: "Subtitles", icon: "subtitles", subtitle: "Language and mode" },
        { id: "settings:notifications", title: "Notifications", icon: "bell", subtitle: "Email and push alerts" },
        { id: "settings:help", title: "Help & about", icon: "help", subtitle: "Support, privacy, version" },
        { divider: true },
        { id: "signOut", title: "Sign Out", icon: "signout" }
    ]
    m.rows.rows = rows
end sub

sub onRow(event as object)
    id = event.getData()
    if Left(id, 9) = "settings:" then
        m.top.navigate = { to: "settings", page: Mid(id, 10) }
    else if id = "signOut" then
        s = m.global.session
        name = "this account"
        if s <> invalid and ZStr(s.userName) <> "" then name = ZStr(s.userName)
        confirm("signOut", "Sign out of " + name + "?", "You can sign in again from Who's watching.", "Sign Out")
    else
        m.top.action = id
    end if
end sub

sub info(title as string, message as string)
    showDialog("info", title, message, [{ id: "ok", title: "OK" }])
end sub

sub confirm(kind as string, title as string, message as string, action as string)
    showDialog(kind, title, message, [{ id: "yes", title: action }, { id: "no", title: "Cancel" }])
end sub

sub showDialog(kind as string, title as string, message as string, options as object)
    d = CreateObject("roSGNode", "PickerDialog")
    d.title = title
    d.message = message
    d.options = options
    d.observeField("result", "onDialog")
    m.dialogKind = kind
    m.top.appendChild(d)
    m.dialog = d
    m.top.modal = true
    d.focusIn = true
end sub

sub onDialog(event as object)
    r = event.getData()
    m.top.removeChild(m.dialog)
    m.dialog = invalid
    m.top.modal = false
    m.rows.setFocus(true)
    if m.dialogKind = "signOut" and r <> invalid and r.id = "yes" then m.top.action = "signOut"
end sub

sub restoreFocus()
    if m.dialog <> invalid then
        m.dialog.focusIn = true
    else
        m.rows.setFocus(true)
    end if
end sub
