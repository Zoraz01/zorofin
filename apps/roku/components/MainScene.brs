sub init()
    m.top.backgroundColor = "0x111513FF"
    m.top.backgroundUri = ""
    m.screens = m.top.findNode("screens")
    m.tabBar = m.top.findNode("tabBar")
    m.dialogLayer = m.top.findNode("dialogLayer")
    m.busy = m.top.findNode("busy")
    m.toast = m.top.findNode("toast")
    m.toastText = m.top.findNode("toastText")
    m.toastText.font = ZFont(26, "semibold")
    m.top.findNode("busyText").font = ZFont(30)
    m.toastTimer = m.top.findNode("toastTimer")
    m.toastTimer.observeField("fire", "hideToast")
    m.tabBar.observeField("selectedTab", "onTabSelected")
    m.tabBar.observeField("leaveDown", "onTabLeave")

    m.stack = []
    m.parked = []
    m.roots = {}
    m.currentTab = ""
    m.views = []
    m.features = {}
    m.pendingLink = invalid
    m.launched = false
    m.deviceId = ZDeviceId()
    m.deviceName = ZDeviceName()
    m.global.settings = ZSettings()

    start()
end sub

' MARK: Startup and session

sub start()
    account = ZActiveAccount()
    accounts = ZAccounts()
    if account = invalid and accounts.count() > 0 then
        showAccounts()
        return
    end if
    if account = invalid then
        showConnect("")
        return
    end if
    useAccount(account, true)
end sub

sub useAccount(account as object, validate = false as boolean)
    m.account = account
    m.global.session = {
        server: account.server,
        serverId: ZStr(account.serverId),
        serverName: ZStr(account.serverName),
        token: account.token,
        userId: account.userId,
        userName: ZStr(account.userName),
        imageTag: ZStr(account.imageTag),
        isAdmin: account.isAdmin = true,
        deviceId: m.deviceId,
        deviceName: m.deviceName
    }
    if validate then
        setBusy(true, "Signing in…")
        runTask({ cmd: "validate" }, "onValidated")
    else
        openHome()
    end if
end sub

sub onValidated(event as object)
    setBusy(false)
    r = event.getData()
    if r.ok then
        ' Keep the saved name and photo current.
        m.account.userName = r.userName
        m.account.imageTag = r.imageTag
        m.account.isAdmin = r.isAdmin
        ZSaveAccount(m.account)
        s = m.global.session
        s.userName = r.userName
        s.imageTag = r.imageTag
        s.isAdmin = r.isAdmin
        m.global.session = s
        openHome()
    else if r.error = "unauthorized" then
        ZForgetAccount(m.account.key)
        showConnect(m.account.server, "Your sign-in on " + ZStr(m.account.serverName, "this server") + " has ended. Please sign in again.")
    else
        ' Offline or server down: still open Home so the viewer sees the error there.
        openHome()
    end if
end sub

sub signOut(params = invalid as dynamic)
    if m.account <> invalid then
        runTask({ cmd: "logout" }, "")
        ZForgetAccount(m.account.key)
    end if
    server = ""
    server = ZStr(m.global.session.server)
    m.global.session = {}
    m.global.features = {}
    m.account = invalid
    if ZAccounts().count() > 0 then
        showAccounts()
    else
        showConnect(server)
    end if
end sub

sub switchAccount()
    ZSetActive(invalid)
    m.global.session = {}
    showAccounts()
end sub

sub onSignedIn(account as object, remember as boolean)
    ZSaveAccount(account, remember)
    ZSetLastServer(account.server)
    useAccount(account, false)
end sub

' MARK: Navigation

sub clearScreens()
    m.screens.removeChildrenIndex(m.screens.getChildCount(), 0)
    m.stack = []
    m.roots = {}
    m.currentTab = ""
end sub

sub showConnect(server as string, notice = "" as string)
    clearScreens()
    m.tabBar.visible = false
    screen = CreateObject("roSGNode", "ConnectScreen")
    if server = "" then server = ZLastServer()
    screen.deviceId = m.deviceId
    screen.deviceName = m.deviceName
    screen.server = server
    screen.notice = notice
    screen.observeField("signedIn", "onScreenSignedIn")
    pushScreen(screen)
    launchComplete()
end sub

sub showAccounts()
    clearScreens()
    m.tabBar.visible = false
    screen = CreateObject("roSGNode", "AccountsScreen")
    screen.accounts = ZAccounts()
    screen.observeField("chosen", "onAccountChosen")
    pushScreen(screen)
    launchComplete()
end sub

sub onAccountChosen(event as object)
    choice = event.getData()
    if choice = invalid then return
    if choice.action = "add" then
        showConnect(ZLastServer())
    else if choice.action = "forget" then
        confirmForget(choice.key)
    else
        for each a in ZAccounts()
            if a.key = choice.key then
                ZSetActive(a.key)
                useAccount(a, true)
                return
            end if
        end for
    end if
end sub

' Removing a saved account asks first; the account can only come back by
' signing in again.
sub confirmForget(key as string)
    name = "this account"
    for each a in ZAccounts()
        if a.key = key then name = ZStr(a.userName)
    end for
    m.forgetKey = key
    buttons = [{ id: "cancel", text: "Cancel", primary: true }, { id: "remove", text: "Remove" }]
    showAlert({ title: "Remove " + name + "?", message: "You'll need to sign in again to use it on this Roku.", buttons: buttons }, "onForgetResult")
end sub

sub onForgetResult(event as object)
    choice = event.getData()
    key = m.forgetKey
    m.forgetKey = invalid
    closeAlert()
    if choice <> "remove" or key = invalid then return
    ZForgetAccount(key)
    if ZAccounts().count() = 0 then showConnect(ZLastServer()) else showAccounts()
end sub

sub onScreenSignedIn(event as object)
    data = event.getData()
    if data = invalid or data.account = invalid then return
    onSignedIn(data.account, data.remember <> false)
end sub

sub openHome()
    clearScreens()
    m.tabBar.visible = true
    m.tabBar.userName = ZStr(m.global.session.userName)
    m.tabBar.userImage = ZUserImageUrl(m.global.session.server, m.global.session.userId, m.global.session.imageTag, 120)
    showTab("home")
end sub

' Root screens are kept alive so switching tabs is instant, but only the
' screen on top stays in the scene: a hidden screen in the tree still holds
' its artwork, and Roku TVs leave apps barely more than one screen's worth
' of texture memory (black screens otherwise).
sub showTab(tabId as string)
    if tabId = m.currentTab and m.stack.count() = 1 then
        focusTop()
        return
    end if
    ' Leaving pushed screens behind when switching tabs.
    while m.stack.count() > 0
        top = m.stack.pop()
        top.visible = false
        if isRoot(top) then parkArt(top) else forgetArt(top)
        detach(top)
    end while
    screen = m.roots[tabId]
    if screen = invalid then
        screen = createRoot(tabId)
        if screen = invalid then return
        m.roots[tabId] = screen
    end if
    m.currentTab = tabId
    m.tabBar.selectedId = tabId
    attach(screen)
    screen.visible = true
    m.stack.push(screen)
    focusTop()
end sub

function isRoot(screen as object) as boolean
    for each key in m.roots
        if m.roots[key] <> invalid and m.roots[key].isSameNode(screen) then return true
    end for
    return false
end function

function createRoot(tabId as string) as dynamic
    screen = invalid
    if tabId = "home" then
        screen = CreateObject("roSGNode", "HomeScreen")
        screen.observeField("loaded", "onHomeLoaded")
    else if tabId = "movies" then
        screen = CreateObject("roSGNode", "LibraryScreen")
        screen.config = { title: "Movies", types: "Movie", sortBy: "SortName", sortOrder: "Ascending" }
    else if tabId = "shows" then
        screen = CreateObject("roSGNode", "LibraryScreen")
        screen.config = { title: "Shows", types: "Series", sortBy: "SortName", sortOrder: "Ascending" }
    else if tabId = "live" then
        screen = CreateObject("roSGNode", "LiveTvScreen")
    else if tabId = "search" then
        screen = CreateObject("roSGNode", "SearchScreen")
    else if tabId = "profile" then
        screen = CreateObject("roSGNode", "ProfileScreen")
        screen.observeField("action", "onProfileAction")
    end if
    if screen <> invalid then wire(screen)
    return screen
end function

sub wire(screen as object)
    if screen.hasField("modal") then screen.observeField("modal", "onModal")
    screen.observeField("navigate", "onNavigate")
    screen.observeField("toast", "onToast")
    screen.observeField("sessionExpired", "onSessionExpired")
end sub

' A node created in the scene can report the scene as its parent before it
' is added anywhere (seen on a TCL Roku TV), so check for m.screens itself.
function inScreens(screen as object) as boolean
    parent = screen.getParent()
    return parent <> invalid and parent.isSameNode(m.screens)
end function

sub attach(screen as object)
    if not inScreens(screen) then m.screens.appendChild(screen)
    restoreArt(screen)
end sub

sub detach(screen as object)
    if inScreens(screen) then m.screens.removeChild(screen)
end sub

' A screen out of view lets go of its server artwork so Roku can reuse the
' memory: Posters drop their uri, lists drop their content, and both come
' back (with the focused item) when the screen is shown again. Park before
' the screen leaves the scene, so the renderer sees the release.
sub parkArt(screen as object)
    if m.parked = invalid then m.parked = []
    for each p in m.parked
        if p.screen.isSameNode(screen) then return
    end for
    entries = []
    collectArt(screen, entries)
    m.parked.push({ screen: screen, entries: entries })
    unloadArt(entries)
end sub

' Image URLs of the cards in a list's content (rows of items, or items).
function contentUrls(content as dynamic) as object
    urls = []
    if content = invalid then return urls
    for each child in content.getChildren(-1, 0)
        if child.getChildCount() > 0 then
            for each item in child.getChildren(-1, 0)
                addItemUrls(item, urls)
            end for
        else
            addItemUrls(child, urls)
        end if
    end for
    return urls
end function

sub addItemUrls(item as object, urls as object)
    if item.HDPosterUrl <> invalid and item.HDPosterUrl <> "" then urls.push(item.HDPosterUrl)
    if item.hasField("landscapeUrl") and item.landscapeUrl <> "" then urls.push(item.landscapeUrl)
end sub

sub unloadArt(entries as object)
    urls = []
    for each e in entries
        if e.urls <> invalid then urls.append(e.urls)
    end for
    if urls.count() > 0 then m.top.unloadImages = urls
end sub

sub collectArt(node as object, entries as object)
    kind = node.subtype()
    if kind = "Shelf" then
        if not node.parked then
            node.parked = true
            entries.push({ node: node, kind: "shelf", urls: contentUrls(node.content) })
        end if
        return
    else if kind = "MarkupGrid" or kind = "RowList" then
        if node.content <> invalid then
            entry = { node: node, kind: kind, content: node.content, focus: node.itemFocused, urls: contentUrls(node.content) }
            if kind = "RowList" then entry.focus = node.rowItemFocused
            node.content = invalid
            entries.push(entry)
        end if
        return
    else if kind = "Poster" then
        uri = node.uri
        if uri <> invalid and Left(uri, 4) = "http" then
            entries.push({ node: node, kind: "poster", uri: uri, urls: [uri] })
            node.uri = ""
        end if
    end if
    for each child in node.getChildren(-1, 0)
        collectArt(child, entries)
    end for
end sub

' A screen that closes for good: its artwork was unloaded when it was
' parked, otherwise collect and unload it now.
sub forgetArt(screen as object)
    if m.parked = invalid then m.parked = []
    for i = 0 to m.parked.count() - 1
        if m.parked[i].screen.isSameNode(screen) then
            m.parked.delete(i)
            return
        end if
    end for
    entries = []
    collectArt(screen, entries)
    unloadArt(entries)
end sub

sub restoreArt(screen as object)
    if m.parked = invalid then return
    for i = 0 to m.parked.count() - 1
        if m.parked[i].screen.isSameNode(screen) then
            for each e in m.parked[i].entries
                if e.kind = "shelf" then
                    e.node.parked = false
                else if e.kind = "poster" then
                    ' Code may have set new art while hidden; keep that.
                    if e.node.uri = "" then e.node.uri = e.uri
                else if e.node.content = invalid then
                    e.node.content = e.content
                    if e.kind = "MarkupGrid" and e.focus <> invalid and e.focus > 0 then e.node.jumpToItem = e.focus
                    if e.kind = "RowList" and ZIsArray(e.focus) and e.focus.count() = 2 then e.node.jumpToRowItem = e.focus
                end if
            end for
            m.parked.delete(i)
            return
        end if
    end for
end sub

sub pushScreen(screen as object)
    if m.stack.count() > 0 then
        below = m.stack.peek()
        below.visible = false
        parkArt(below)
        detach(below)
    end if
    attach(screen)
    screen.visible = true
    m.stack.push(screen)
    focusTop()
end sub

sub popScreen()
    if m.stack.count() <= 1 then return
    top = m.stack.pop()
    top.visible = false
    if top.hasField("closing") then top.closing = true
    if not isRoot(top) then forgetArt(top)
    detach(top)
    current = m.stack.peek()
    attach(current)
    current.visible = true
    if current.hasField("resumed") then current.resumed = true
    m.tabBar.visible = isRoot(current) or current.hasField("showTabs")
    focusTop()
end sub

sub focusTop()
    if m.stack.count() = 0 then return
    top = m.stack.peek()
    top.setFocus(true)
    if top.hasField("focusIn") then top.focusIn = true
end sub

sub onTabSelected(event as object)
    tabId = event.getData()
    if tabId = "" then return
    if tabId = "account" then
        showAccountMenu()
        return
    else if tabId = "support" then
        openScreen("SupportScreen")
        return
    else if tabId = "notifications" then
        showNotifications()
        return
    end if
    showTab(tabId)
    ' Search is for typing, so OK on it lands on the keyboard; other tabs
    ' keep focus on the bar like Apple TV.
    if tabId <> "search" then m.tabBar.setFocus(true)
end sub

' MARK: Header popovers (Apple TV account menu and notifications)

sub showAccountMenu()
    closeMenu()
    menu = CreateObject("roSGNode", "AccountMenu")
    s = m.global.session
    menu.accounts = ZAccounts()
    menu.currentKey = ZStr(m.account.key)
    menu.serverName = ZStr(s.serverName)
    menu.userName = ZStr(s.userName)
    menu.userImage = ZUserImageUrl(s.server, s.userId, s.imageTag, 120)
    menu.watchTogether = ZNum(m.features.syncPlay, 0) = 1
    menu.callFunc("refresh", {})
    menu.observeField("action", "onAccountMenu")
    m.dialogLayer.appendChild(menu)
    menu.focusIn = true
    m.menu = menu
end sub

sub closeMenu(refocus = "" as string)
    if m.menu = invalid then return
    m.dialogLayer.removeChild(m.menu)
    m.menu = invalid
    if refocus <> "" then
        m.tabBar.focusId = refocus
        m.tabBar.setFocus(true)
    end if
end sub

sub onAccountMenu(event as object)
    a = event.getData()
    if a = invalid then return
    if a.type = "close" then
        closeMenu("account")
    else if a.type = "switch" then
        closeMenu()
        if a.key = ZStr(m.account.key) then
            m.tabBar.focusId = "account"
            m.tabBar.setFocus(true)
            return
        end if
        for each acct in ZAccounts()
            if acct.key = a.key then
                ZSetActive(acct.key)
                useAccount(acct, true)
                return
            end if
        end for
    else if a.type = "servers" then
        closeMenu()
        switchAccount()
    else if a.type = "quickConnect" then
        closeMenu()
        openScreen("QuickConnectScreen")
    else if a.type = "watchTogether" then
        closeMenu()
        openScreen("WatchTogetherScreen")
    else if a.type = "settings" then
        closeMenu()
        showTab("profile")
    end if
end sub

sub showNotifications()
    closeMenu()
    panel = CreateObject("roSGNode", "NotificationsPanel")
    panel.observeField("action", "onNotificationsAction")
    m.dialogLayer.appendChild(panel)
    panel.focusIn = true
    m.menu = panel
end sub

sub onNotificationsAction(event as object)
    a = event.getData()
    if a = invalid then return
    if a.type = "close" then
        closeMenu("notifications")
    else if a.type = "unread" then
        m.tabBar.unread = a.count
    end if
end sub

' A full-screen page pushed over the current tab, with the header kept.
sub openScreen(name as string)
    screen = CreateObject("roSGNode", name)
    wire(screen)
    if screen.hasField("action") then screen.observeField("action", "onProfileAction")
    pushScreen(screen)
    m.tabBar.visible = screen.hasField("showTabs")
end sub

' A screen covering everything (text entry) hides the header meanwhile.
sub onModal(event as object)
    top = invalid
    if m.stack.count() > 0 then top = m.stack.peek()
    if event.getData() = true then
        m.tabBar.visible = false
    else if top <> invalid then
        m.tabBar.visible = isRoot(top) or top.hasField("showTabs")
    end if
end sub

sub onTabLeave()
    focusTop()
end sub

sub onHomeLoaded(event as object)
    info = event.getData()
    if info <> invalid then
        m.views = info.views
        m.features = info.features
        m.global.features = info.features
        hasLive = false
        if m.views <> invalid then
            for each v in m.views
                if v.collectionType = "livetv" then hasLive = true
            end for
        end if
        m.tabBar.showLive = hasLive
        m.tabBar.showSupport = ZNum(m.features.support, 0) = 1
        m.tabBar.showNotifications = ZNum(m.features.notifications, 0) = 1
        if m.tabBar.showNotifications then runTask({ cmd: "supportReplies" }, "onReplies")
    end if
    launchComplete()
    if m.pendingLink <> invalid then
        link = m.pendingLink
        m.pendingLink = invalid
        handleDeepLink(link)
    end if
end sub

' Generic screen requests: { to: "detail" | "library" | "player" | "season", ... }
sub onNavigate(event as object)
    nav = event.getData()
    if nav = invalid then return
    target = nav.to
    if target = "detail" then
        openDetail(nav.id, nav.autoplay = true)
    else if target = "library" then
        screen = CreateObject("roSGNode", "LibraryScreen")
        wire(screen)
        screen.config = nav.config
        pushScreen(screen)
        m.tabBar.visible = true
    else if target = "player" then
        play(nav)
    else if target = "settings" then
        screen = CreateObject("roSGNode", "SettingsScreen")
        wire(screen)
        screen.page = ZStr(nav.page)
        pushScreen(screen)
        m.tabBar.visible = true
    else if target = "tabId" then
        showTab(nav.tab)
    else if target = "back" then
        popScreen()
    end if
end sub

sub openDetail(id as string, autoplay = false as boolean)
    screen = CreateObject("roSGNode", "DetailScreen")
    wire(screen)
    screen.autoplay = autoplay
    screen.itemId = id
    pushScreen(screen)
    m.tabBar.visible = true
end sub

sub play(nav as object)
    ' Live channels check the server's Live TV streams first, like Apple TV, so a
    ' full tuner shows which channel is using it instead of a playback error.
    if nav.live = true and ZNum(m.features.liveTvStreams, 0) = 1 and nav.checked <> true then
        setBusy(true, "Checking Live TV availability…")
        m.pendingLive = nav
        task = CreateObject("roSGNode", "JellyfinTask")
        task.request = { cmd: "liveStreams", channelId: nav.id }
        task.observeField("response", "onLiveCheck")
        task.control = "RUN"
        m.liveCheckTask = task
        return
    end if
    startPlayer(nav)
end sub

sub onLiveCheck(event as object)
    r = event.getData()
    nav = m.pendingLive
    m.pendingLive = invalid
    setBusy(false)
    if nav = invalid or ZStr(r.channelId) <> ZStr(nav.id) then return
    ' Missing or failing optional services leave playback alone.
    if r.ok then
        blocked = ZLtsBlocked(r.status, nav.id)
        if blocked <> invalid then
            showLiveConflict(blocked)
            return
        end if
    end if
    nav.checked = true
    startPlayer(nav)
end sub

sub showLiveConflict(blocked as object)
    buttons = [{ id: "ok", text: "OK", primary: true }]
    m.conflictJoin = blocked.join
    if blocked.join <> invalid then
        buttons = [{ id: "join", text: "Watch " + blocked.join.channelName, primary: true }, { id: "cancel", text: "Not now" }]
    end if
    showAlert({ title: blocked.title, message: blocked.text + " " + blocked.hint, buttons: buttons }, "onConflictResult")
end sub

sub onConflictResult(event as object)
    choice = event.getData()
    join = m.conflictJoin
    m.conflictJoin = invalid
    closeAlert()
    if choice = "join" and join <> invalid then play({ to: "player", id: join.channelId, live: true })
end sub

sub showAlert(alert as object, handler as string)
    closeAlert()
    dialog = CreateObject("roSGNode", "AlertDialog")
    dialog.alert = alert
    dialog.observeField("result", handler)
    m.dialogLayer.appendChild(dialog)
    dialog.focusIn = true
    m.alert = dialog
end sub

sub closeAlert()
    if m.alert = invalid then return
    m.dialogLayer.removeChild(m.alert)
    m.alert = invalid
    focusTop()
end sub

sub startPlayer(nav as object)
    screen = CreateObject("roSGNode", "PlayerScreen")
    wire(screen)
    m.tabBar.visible = false
    pushScreen(screen)
    screen.start = nav
end sub

sub onReplies(event as object)
    r = event.getData()
    if r.ok then m.tabBar.unread = ZUnreadReplies(r.replies)
end sub

sub onProfileAction(event as object)
    action = event.getData()
    if action = "signOut" then
        signOut()
    else if action = "switch" then
        switchAccount()
    else if action = "quickConnect" then
        openScreen("QuickConnectScreen")
    else if action = "support" then
        openScreen("SupportScreen")
    else if action = "notifications" then
        showNotifications()
    end if
end sub

sub onSessionExpired()
    if m.account <> invalid then ZForgetAccount(m.account.key)
    server = ""
    server = ZStr(m.global.session.server)
    m.global.session = {}
    showConnect(server, "Your sign-in has ended. Please sign in again.")
end sub

' MARK: Deep links (Roku certification: contentId + mediaType)

sub onLaunchArgs(event as object)
    link = event.getData()
    if link <> invalid and ZStr(link.contentId) <> "" then
        if not hasSession() or not m.launched then
            m.pendingLink = link
        else
            handleDeepLink(link)
        end if
    end if
end sub

sub onInputArgs(event as object)
    link = event.getData()
    if link = invalid or ZStr(link.contentId) = "" then return
    if not hasSession() then
        m.pendingLink = link
        return
    end if
    handleDeepLink(link)
end sub

sub handleDeepLink(link as object)
    m.linkRequest = link
    runTask({ cmd: "resolve", id: link.contentId, mediaType: ZStr(link.mediaType) }, "onLinkResolved")
end sub

sub onLinkResolved(event as object)
    r = event.getData()
    if not r.ok then
        showToast("That title isn't available on this server.")
        return
    end if
    ' Close any player first so the new title starts cleanly.
    while m.stack.count() > 1 and m.stack.peek().subtype() = "PlayerScreen"
        popScreen()
    end while
    kind = r.type
    if kind = "Movie" or kind = "Episode" or kind = "Video" or kind = "MusicVideo" or kind = "TvChannel" then
        play({ to: "player", id: r.id, startTicks: r.position, live: kind = "TvChannel" })
    else
        openDetail(r.id)
    end if
end sub

' MARK: Shared UI

sub runTask(request as object, callback as string)
    task = CreateObject("roSGNode", "JellyfinTask")
    request.deviceId = m.deviceId
    request.deviceName = m.deviceName
    task.request = request
    if callback <> "" then task.observeField("response", callback)
    task.control = "RUN"
    if m.tasks = invalid then m.tasks = []
    m.tasks.push(task)
    if m.tasks.count() > 8 then m.tasks.shift()
end sub

sub setBusy(on as boolean, text = "Loading…" as string)
    m.busy.visible = on
    m.top.findNode("busyText").text = text
end sub

sub onToast(event as object)
    showToast(ZStr(event.getData()))
end sub

sub showToast(text as string)
    if text = "" then return
    m.toastText.text = text
    w = Len(text) * 15 + 96
    if w > 1600 then w = 1600
    if w < 400 then w = 400
    m.top.findNode("toastBg").width = w
    m.toastText.width = w
    m.toast.translation = [(1920 - w) / 2, 960]
    m.toast.visible = true
    m.toastTimer.control = "stop"
    m.toastTimer.control = "start"
end sub

sub hideToast()
    m.toast.visible = false
end sub

sub launchComplete()
    if m.launched then return
    m.launched = true
    m.top.signalBeacon("AppLaunchComplete")
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    top = invalid
    if m.stack.count() > 0 then top = m.stack.peek()
    if key = "back" then
        if m.stack.count() > 1 then
            popScreen()
            return true
        end if
        if m.tabBar.visible and m.currentTab <> "home" and m.currentTab <> "" then
            showTab("home")
            return true
        end if
        ' Back on Home (or the sign-in flow) exits, as Roku requires.
        m.top.exitApp = true
        return true
    end if
    if key = "up" and m.tabBar.visible and top <> invalid and (isRoot(top) or top.hasField("showTabs")) and not m.tabBar.isInFocusChain() then
        m.tabBar.setFocus(true)
        return true
    end if
    if key = "down" and m.tabBar.isInFocusChain() then
        focusTop()
        return true
    end if
    if key = "options" and m.tabBar.visible and m.menu = invalid and not m.tabBar.isInFocusChain() then
        m.tabBar.setFocus(true)
        return true
    end if
    return false
end function

function hasSession() as boolean
    s = m.global.session
    return s <> invalid and ZStr(s.token) <> ""
end function
