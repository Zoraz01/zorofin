sub init()
    m.top.findNode("title").font = ZFont(52, "bold")
    m.top.findNode("subtitle").font = ZFont(28)
    m.top.findNode("serverHelp").font = ZFont(24)
    m.top.findNode("qcTitle").font = ZFont(34, "bold")
    m.top.findNode("qcCode").font = ZFont(96, "bold")
    m.top.findNode("qcHelp").font = ZFont(26)
    m.top.findNode("error").font = ZFont(26)
    m.top.findNode("footer").font = ZFont(20)
    m.top.findNode("footer").text = "Zorofin " + ZStr(m.global.appVersion) + " · Works with any Jellyfin server"

    m.serverStep = m.top.findNode("serverStep")
    m.signInStep = m.top.findNode("signInStep")
    m.serverField = m.top.findNode("serverField")
    m.serverActions = m.top.findNode("serverActions")
    m.userPicker = m.top.findNode("userPicker")
    m.userField = m.top.findNode("userField")
    m.passField = m.top.findNode("passField")
    m.signInActions = m.top.findNode("signInActions")
    m.qcPanel = m.top.findNode("qcPanel")
    m.qcCode = m.top.findNode("qcCode")
    m.error = m.top.findNode("error")
    m.qcTimer = m.top.findNode("qcTimer")
    m.qcTimer.observeField("fire", "pollQuickConnect")

    m.serverActions.buttons = [{ id: "connect", text: "Continue", primary: true }]
    m.signInActions.buttons = [{ id: "signin", text: "Sign in", primary: true }, { id: "rokuEmail", text: "Use Roku email" }, { id: "change", text: "Change server" }]
    m.serverField.observeField("selected", "editServer")
    m.userField.observeField("selected", "editUser")
    m.passField.observeField("selected", "editPassword")
    m.serverActions.observeField("selected", "onServerAction")
    m.signInActions.observeField("selected", "onSignInAction")
    m.userPicker.observeField("selected", "onUserPicked")

    m.step = "server"
    m.probe = invalid
    m.secret = ""
    m.users = []
    m.top.observeField("server", "onServer")
    showServerStep()
end sub

sub onServer()
    m.serverField.value = m.top.server
end sub

sub onNotice()
    m.error.text = m.top.notice
end sub

sub showServerStep()
    stopPolling()
    m.step = "server"
    m.top.findNode("title").text = "Connect to your server"
    m.top.findNode("subtitle").text = "Zorofin works with your own Jellyfin server. Enter its address to get started."
    m.serverStep.visible = true
    m.signInStep.visible = false
    m.top.findNode("logo").visible = true
    if m.serverField.value = "" then
        m.serverField.setFocus(true)
    else
        m.serverActions.setFocus(true)
    end if
end sub

sub restoreFocus()
    if m.entry <> invalid then
        m.entry.focusIn = true
        return
    end if
    if m.step = "server" then
        if m.serverField.value = "" then m.serverField.setFocus(true) else m.serverActions.setFocus(true)
    else
        if m.userField.value = "" and m.users.count() > 0 then
            m.userPicker.setFocus(true)
        else if m.userField.value = "" then
            m.userField.setFocus(true)
        else
            m.passField.setFocus(true)
        end if
    end if
end sub

' MARK: Text entry

sub openEntry(title as string, message as string, value as string, secure as boolean, target as string, doneText = "Done" as string)
    entry = CreateObject("roSGNode", "TextEntry")
    entry.title = title
    entry.message = message
    entry.secure = secure
    entry.text = value
    entry.doneText = doneText
    entry.observeField("result", "onEntryResult")
    m.entryTarget = target
    m.entry = entry
    m.top.appendChild(entry)
    entry.focusIn = true
end sub

sub onEntryResult(event as object)
    r = event.getData()
    m.top.removeChild(m.entry)
    m.entry = invalid
    if r.ok then
        if m.entryTarget = "server" then
            m.serverField.value = r.text.trim()
            m.serverActions.setFocus(true)
            if m.serverField.value <> "" then connect()
            return
        else if m.entryTarget = "user" then
            m.userField.value = r.text.trim()
            m.passField.setFocus(true)
            return
        else if m.entryTarget = "password" then
            m.passField.value = r.text
            m.signInActions.focusIndex = 0
            m.signInActions.setFocus(true)
            signIn()
            return
        end if
    end if
    restoreFocus()
end sub

sub editServer()
    openEntry("Server address", "For example https://media.example.com or 192.168.1.20:8096", m.serverField.value, false, "server", "Continue")
end sub

sub editUser()
    openEntry("Username", "", m.userField.value, false, "user", "Next")
end sub

sub editPassword()
    openEntry("Password", "Leave it empty if your account has no password.", m.passField.value, true, "password", "Sign in")
end sub

' MARK: Server step

sub onServerAction(event as object)
    if m.serverField.value = "" then
        editServer()
    else
        connect()
    end if
end sub

sub connect()
    m.error.text = ""
    showStatus("Connecting…")
    runCmd({ cmd: "probe", address: m.serverField.value }, "onProbe")
end sub

sub onProbe(event as object)
    r = event.getData()
    if not r.ok then
        m.error.text = ZStr(r.message, ZErrorText(r.error))
        m.serverField.setFocus(true)
        return
    end if
    m.probe = r
    m.error.text = ""
    runCmd({ cmd: "publicUsers", server: r.server }, "onPublicUsers")
end sub

sub onPublicUsers(event as object)
    r = event.getData()
    m.users = []
    if r.ok and r.users <> invalid then m.users = r.users
    showSignInStep(r.ok and r.quickConnect = true)
end sub

' MARK: Sign-in step

sub showSignInStep(quickConnect as boolean)
    m.step = "signin"
    m.serverStep.visible = false
    m.signInStep.visible = true
    m.top.findNode("logo").visible = false
    m.top.findNode("title").translation = [0, 110]
    m.top.findNode("subtitle").translation = [360, 180]
    m.top.findNode("title").text = "Sign in to " + ZStr(m.probe.serverName, "your server")
    m.top.findNode("subtitle").text = m.probe.server
    m.qcPanel.visible = quickConnect
    passwordPanel = m.top.findNode("passwordPanel")
    if quickConnect then
        passwordPanel.translation = [960, 360]
        m.qcCode.text = "· · · · · ·"
        runCmd({ cmd: "qcInitiate", server: m.probe.server }, "onQuickConnect")
    else
        passwordPanel.translation = [560, 360]
    end if
    buttons = []
    for each u in m.users
        if buttons.count() < 5 then buttons.push({ id: u.name, text: u.name })
    end for
    m.userPicker.buttons = buttons
    m.userPicker.visible = buttons.count() > 0
    m.userPicker.buttonHeight = 64
    m.userPicker.fontSize = 24
    restoreFocus()
end sub

sub onUserPicked(event as object)
    m.userField.value = event.getData()
    m.passField.value = ""
    for each u in m.users
        if u.name = m.userField.value and u.hasPassword = false then
            signIn()
            return
        end if
    end for
    editPassword()
end sub

sub onSignInAction(event as object)
    if event.getData() = "change" then
        showServerStep()
        m.top.findNode("title").translation = [0, 210]
        m.top.findNode("subtitle").translation = [360, 280]
        return
    end if
    if event.getData() = "rokuEmail" then
        requestRokuEmail()
        return
    end if
    if m.userField.value = "" then
        editUser()
        return
    end if
    signIn()
end sub

' Roku's Request for Information: the viewer can share the email on their
' Roku account as the username, for servers that sign in by email. Nothing
' is shared without the viewer's choice in Roku's own dialog.
sub requestRokuEmail()
    info = CreateObject("roSGNode", "ContentNode")
    info.addFields({ context: "signin" })
    store = CreateObject("roSGNode", "ChannelStore")
    store.requestedUserData = "email"
    store.requestedUserDataInfo = info
    store.observeField("userData", "onRokuEmail")
    m.store = store
    store.command = "getUserData"
end sub

sub onRokuEmail()
    data = invalid
    if m.store <> invalid then data = m.store.userData
    m.store = invalid
    email = ""
    if data <> invalid then email = ZStr(data.email).trim()
    if email <> "" then
        m.userField.value = email
        m.passField.value = ""
        editPassword()
    else
        restoreFocus()
    end if
end sub

sub signIn()
    if m.userField.value = "" then return
    m.error.text = ""
    showStatus("Signing in…")
    runCmd({ cmd: "login", server: m.probe.server, serverId: m.probe.serverId, serverName: m.probe.serverName, username: m.userField.value, password: m.passField.value }, "onSignedIn")
end sub

sub onSignedIn(event as object)
    r = event.getData()
    if not r.ok then
        m.error.text = ZErrorText(r.error)
        m.passField.setFocus(true)
        return
    end if
    finish(r.account)
end sub

sub onQuickConnect(event as object)
    r = event.getData()
    if not r.ok or r.code = "" then
        m.qcPanel.visible = false
        m.top.findNode("passwordPanel").translation = [560, 360]
        return
    end if
    m.secret = r.secret
    code = r.code
    if Len(code) = 6 then code = Left(code, 3) + " " + Right(code, 3)
    m.qcCode.text = code
    m.qcTimer.control = "start"
end sub

sub pollQuickConnect()
    if m.secret = "" or m.polling = true then return
    m.polling = true
    runCmd({ cmd: "qcPoll", server: m.probe.server, serverId: m.probe.serverId, serverName: m.probe.serverName, secret: m.secret }, "onQuickConnectPoll")
end sub

sub onQuickConnectPoll(event as object)
    m.polling = false
    r = event.getData()
    if r.ok and r.authenticated = true and r.account <> invalid then
        finish(r.account)
    else if not r.ok and (r.error = "unauthorized" or r.error = "notFound") then
        ' The code expired; ask for a new one.
        stopPolling()
        runCmd({ cmd: "qcInitiate", server: m.probe.server }, "onQuickConnect")
    end if
end sub

sub stopPolling()
    m.qcTimer.control = "stop"
    m.secret = ""
end sub

sub finish(account as object)
    stopPolling()
    account.serverName = ZStr(m.probe.serverName, account.serverName)
    if ZStr(account.serverId) = "" then account.serverId = m.probe.serverId
    m.top.signedIn = { account: account, remember: true }
end sub

' MARK: Helpers

sub showStatus(text as string)
    m.error.text = ""
    m.top.findNode("footer").text = text
end sub

sub runCmd(request as object, callback as string)
    task = CreateObject("roSGNode", "JellyfinTask")
    request.deviceId = m.top.deviceId
    request.deviceName = m.top.deviceName
    task.request = request
    task.observeField("response", callback)
    task.observeField("response", "clearStatus")
    task.control = "RUN"
    if m.tasks = invalid then m.tasks = []
    m.tasks.push(task)
    if m.tasks.count() > 6 then m.tasks.shift()
end sub

sub clearStatus()
    m.top.findNode("footer").text = "Zorofin " + ZStr(m.global.appVersion) + " · Works with any Jellyfin server"
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if m.step = "server" then
        if key = "down" and m.serverField.hasFocus() then
            m.serverActions.setFocus(true)
            return true
        else if key = "up" and m.serverActions.isInFocusChain() then
            m.serverField.setFocus(true)
            return true
        end if
        return false
    end if
    order = []
    if m.userPicker.visible then order.push(m.userPicker)
    order.push(m.userField)
    order.push(m.passField)
    order.push(m.signInActions)
    current = -1
    for i = 0 to order.count() - 1
        if order[i].isInFocusChain() then current = i
    end for
    if key = "down" and current >= 0 and current < order.count() - 1 then
        order[current + 1].setFocus(true)
        return true
    else if key = "up" and current > 0 then
        order[current - 1].setFocus(true)
        return true
    else if key = "back" then
        showServerStep()
        m.top.findNode("title").translation = [0, 210]
        m.top.findNode("subtitle").translation = [360, 280]
        return true
    end if
    return false
end function
