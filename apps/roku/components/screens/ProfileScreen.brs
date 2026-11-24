sub init()
    m.top.findNode("name").font = ZFont(36, "bold")
    m.top.findNode("server").font = ZFont(22)
    m.top.findNode("initial").font = ZFont(28, "bold")
    m.rows = m.top.findNode("rows")
    m.rows.observeField("selected", "onRow")
    m.dialog = invalid
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
    features = m.global.features
    if features = invalid then features = {}
    rows = [
        { id: "switch", title: "Change account", icon: "users" },
        { id: "settings:account", title: "Account", icon: "user" },
        { id: "quickConnect", title: "Quick Connect", icon: "phone" }
    ]
    rows.append([
        { id: "settings:display", title: "Display", icon: "display" },
        { id: "settings:playback", title: "Playback", icon: "playback" },
        { id: "settings:subtitles", title: "Subtitles", icon: "subtitles" },
        { id: "settings:controls", title: "Controls", icon: "controls" },
        { id: "settings:storage", title: "Storage & app", icon: "storage" },
        { divider: true }
    ])
    if ZNum(features.support, 0) = 1 then rows.push({ id: "support", title: "Support", icon: "support" })
    rows.push({ id: "settings:notifications", title: "Notification settings", icon: "options" })
    if ZNum(features.notifications, 0) = 1 then rows.push({ id: "notifications", title: "Notifications", icon: "bell" })
    rows.append([
        { id: "privacy", title: "Privacy Policy", icon: "privacy" },
        { id: "help", title: "App Support", icon: "help" },
        { divider: true },
        { id: "signOut", title: "Sign Out", icon: "signout" }
    ])
    m.rows.rows = rows
end sub

sub onRow(event as object)
    id = event.getData()
    if Left(id, 9) = "settings:" then
        m.top.navigate = { to: "settings", page: Mid(id, 10) }
    else if id = "privacy" then
        info("Privacy Policy", "Zorofin connects only to the Jellyfin server you choose and has no ads, tracking or analytics. Read the full policy at zorofin.app/privacy on your phone or computer.")
    else if id = "help" then
        info("App Support", "Zorofin " + ZStr(m.global.appVersion) + " for Roku, by Vitality Labs LLC. For help, visit zorofin.app/support on your phone or computer. Zorofin is independently developed and is not affiliated with the Jellyfin project.")
    else if id = "signOut" then
        s = m.global.session
        name = "this account"
        if s <> invalid and ZStr(s.userName) <> "" then name = ZStr(s.userName)
        confirm("signOut", "Sign out of " + name + "?", "You can sign in again from Change account.", "Sign Out")
    else
        ' switch, quickConnect, support and notifications are handled by MainScene.
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
