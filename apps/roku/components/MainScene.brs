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
    m.inbox = invalid
    m.inboxTask = invalid
    m.inboxTimer = m.top.findNode("inboxTimer")
    m.inboxTimer.observeField("fire", "refreshInbox")
    m.pendingLink = invalid
    m.launched = false
    m.awaitingLinkPlayback = false
    m.deviceId = ZDeviceId()
    m.deviceName = ZDeviceName()
    m.global.observeField("settings", "onSettingsChanged")
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
    for each other in accounts
        if other.key <> account.key and other.server = account.server then
            showAccounts()
            return
        end if
    end for
    useAccount(account, true)
end sub

sub useAccount(account as object, validate = false as boolean)
    if m.global.hasField("pickSession") then m.global.pickSession = invalid
    m.account = account
    m.tabBar.showRequests = false
    m.global.features = {}
    m.global.extras = {}
    saved = ZActiveAccount()
    m.global.session = {
        remembered: saved <> invalid and saved.token = account.token,
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
    m.global.settings = ZSettings()
    applyLooks(ZCachedLooks(account.server))
    runTask({ cmd: "looks" }, "onLooks")
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
    m.inboxTimer.control = "stop"
    m.inbox = invalid
    m.tabBar.unread = 0
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
    m.inboxTimer.control = "stop"
    m.inbox = invalid
    m.tabBar.unread = 0
    m.global.session = {}
    showAccounts()
end sub

sub onSignedIn(account as object, remember as boolean)
    ZSaveAccount(account, remember)
    ZSetLastServer(account.server)
    useAccount(account, false)
end sub

' MARK: Server looks

sub applyLooks(looks as object)
    m.global.accent = ZStr(looks.accent)
    m.global.cardScale = ZNum(looks.cardScale, 0.0)
    m.global.defaultCardScale = ZNum(looks.defaultCardScale, 0.0)
end sub

' The server's accent and card size beat the viewer's own settings. A
' change seen after Home was built (first sign-in, or the owner changed
' it) rebuilds Home once so every card and ring picks it up.
sub onLooks(event as object)
    r = event.getData()
    if r = invalid or not r.ok or m.global.session = invalid then return
    if ZStr(r.server) <> ZStr(m.global.session.server) then return
    looks = r.looks
    changed = ZStr(looks.accent) <> m.global.accent or ZNum(looks.cardScale, 0.0) <> m.global.cardScale or ZNum(looks.defaultCardScale, 0.0) <> m.global.defaultCardScale
    ZSaveLooks(r.server, looks)
    if not changed then return
    applyLooks(looks)
    if m.currentTab = "home" and m.stack.count() = 1 then
        clearScreens()
        showTab("home")
    end if
end sub

' Display changes must rebuild cached browsing screens on return. Keep the
' current Profile/Settings screen and its focus intact.
sub onSettingsChanged()
    stale = []
    for each key in m.roots
        if key <> m.currentTab then stale.push(key)
    end for
    for each key in stale
        forgetArt(m.roots[key])
        m.roots.delete(key)
    end for
    if m.inbox <> invalid and m.inbox.scope = ZNotificationScope(m.global.session) then applyInbox(m.inbox, false)
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
    dialogStarted()
end sub

sub showAccounts()
    clearScreens()
    m.tabBar.visible = false
    screen = CreateObject("roSGNode", "AccountsScreen")
    screen.accounts = ZAccounts()
    screen.observeField("chosen", "onAccountChosen")
    pushScreen(screen)
    dialogStarted()
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
    dialogDone()
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
    else if tabId = "requests" and m.tabBar.showRequests then
        screen = CreateObject("roSGNode", "RequestsScreen")
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
    menu.pickTogether = ZNum(m.features.pickTogether, 0) = 1
    extras = m.global.extras
    menu.calendar = extras <> invalid and extras.calendar = true
    menu.catchUp = extras <> invalid and extras.catchUp = true
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
    else if a.type = "pickTogether" then
        closeMenu()
        openScreen("PickTogetherScreen")
    else if a.type = "calendar" then
        closeMenu()
        openScreen("CalendarScreen")
    else if a.type = "catchUp" then
        closeMenu()
        openScreen("CatchUpScreen")
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
    if m.inbox <> invalid and m.inbox.scope = ZNotificationScope(m.global.session) then panel.snapshot = m.inbox
    refreshInbox()
end sub

sub onNotificationsAction(event as object)
    a = event.getData()
    if a = invalid then return
    if a.type = "close" then
        closeMenu("notifications")
    else if a.type = "seen" then
        if ZStr(a.scope) <> ZNotificationScope(m.global.session) then return
        for each reply in a.replies
            m.inboxLocalReplies[ZReplyKey(reply)] = true
        end for
        for each id in a.requests
            m.inboxLocalRequests[id.toStr()] = true
        end for
        if m.inbox <> invalid then applyInbox(m.inbox, false)
        postNotificationReads(a.requests, a.replies, false)
    else if a.type = "refresh" then
        refreshInbox()
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
    if m.roots.home = invalid or not m.roots.home.isSameNode(event.getRoSGNode()) then return
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
        #if ZOROFIN_REQUESTS
        m.tabBar.showRequests = ZContains([1, 2], Int(ZNum(m.features.requests, 0)))
        #end if
        m.tabBar.showSupport = ZNum(m.features.support, 0) = 1
        m.tabBar.showNotifications = ZNum(m.features.notifications, 0) = 1 or (ZNum(m.features.notificationReads, 0) = 1 and ZContains([1, 2], Int(ZNum(m.features.requests, 0))))
        if m.tabBar.showNotifications then
            refreshInbox()
            m.inboxTimer.control = "start"
        else
            m.inboxTimer.control = "stop"
            m.tabBar.unread = 0
        end if
        runTask({ cmd: "extras" }, "onExtras")
    end if
    if m.pendingLink <> invalid then
        link = m.pendingLink
        m.pendingLink = invalid
        m.awaitingLinkPlayback = true
        handleDeepLink(link)
    else if not m.awaitingLinkPlayback then
        launchComplete()
    end if
end sub

' Calendar and Catch Up appear in Profile only when the server turns them on.
sub onExtras(event as object)
    r = event.getData()
    if r <> invalid and r.ok then m.global.extras = r.extras
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
        ' Quick Connect and Support open from Account and Help & about.
        screen.observeField("action", "onProfileAction")
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
    if nav.live = true and ZLtsRoute(m.features) <> "" and nav.checked <> true then
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
    screen.observeField("playbackStarted", "onPlaybackStarted")
    wire(screen)
    m.tabBar.visible = false
    pushScreen(screen)
    screen.start = nav
end sub

sub onPlaybackStarted()
    ' A cold direct-play launch finishes only once Video is actually playing.
    m.awaitingLinkPlayback = false
    launchComplete()
end sub

sub refreshInbox()
    if not hasSession() or not m.tabBar.showNotifications then return
    scope = ZNotificationScope(m.global.session)
    if m.inboxTask <> invalid and m.inboxTask.request.scope = scope and m.inboxTask.state = "run" then return
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "inbox", scope: scope, features: m.features }
    task.observeField("response", "onInbox")
    m.inboxTask = task
    task.control = "RUN"
end sub

sub onInbox(event as object)
    r = event.getData()
    if ZStr(r.scope) <> ZNotificationScope(m.global.session) then return
    if not r.ok then
        if m.menu <> invalid and m.menu.subtype() = "NotificationsPanel" then m.menu.refreshFailed = true
        return
    end if
    ' Preserve a component's last snapshot when only its optional service fails.
    if m.inbox <> invalid and m.inbox.scope = r.scope then
        if r.reads <> invalid then r.reads = ZMergeNotificationReads(m.inbox.reads, r.reads)
        if not r.repliesOk then r.replies = m.inbox.replies
        if not r.requestsOk then r.notices = m.inbox.notices
    end if
    applyInbox(r, true)
end sub

sub applyInbox(r as object, sync as boolean)
    if ZStr(r.scope) <> ZNotificationScope(m.global.session) then return
    if m.inboxLocalScope <> r.scope then
        m.inboxLocalScope = r.scope
        m.inboxLocalReplies = {}
        m.inboxLocalRequests = {}
        m.inboxLocalInitialized = false
    end if
    seen = ZSeenReplies()
    seen.append(m.inboxLocalReplies)
    for each reply in r.replies
        reply.localSeen = seen[ZReplyKey(reply)] = true
    end for
    local = ZLocalRequestReads()
    local.requests.append(m.inboxLocalRequests)
    local.initialized = local.initialized or m.inboxLocalInitialized
    plan = ZNotificationPlan(r.notices, r.replies, local, r.reads, r.requestsComplete = true)
    if plan.localInitialized then
        ZMarkRequestsSeen(plan.mark, true)
        m.inboxLocalInitialized = true
        for each id in plan.mark
            m.inboxLocalRequests[id.toStr()] = true
            local.requests[id.toStr()] = true
        end for
    end if
    r.rows = ZNotificationRows(r.notices, r.replies, local, r.reads)
    m.inbox = r
    count = r.rows.unread
    if ZSettings().showUnreadBadge = false then count = 0
    m.tabBar.unread = count
    if m.menu <> invalid and m.menu.subtype() = "NotificationsPanel" then m.menu.snapshot = r
    if sync then postNotificationReads(plan.requests, plan.replies, plan.initialize)
end sub

sub postNotificationReads(requests as object, replies as object, initialize as boolean)
    if ZNum(m.features.notificationReads, 0) <> 1 then return
    if requests.count() + replies.count() = 0 and not initialize then return
    runTask({ cmd: "notificationReadsWrite", scope: ZNotificationScope(m.global.session), version: 1, requests: requests, replies: replies, initialize: initialize }, "onNotificationReadsSaved")
end sub

sub onNotificationReadsSaved(event as object)
    r = event.getData()
    if ZStr(r.scope) <> ZNotificationScope(m.global.session) then return
    if r.ok and r.reads <> invalid and m.inbox <> invalid and m.inbox.scope = r.scope then
        m.inbox.reads = ZMergeNotificationReads(m.inbox.reads, r.reads)
        applyInbox(m.inbox, false)
    end if
    ' Failure leaves local receipts in place; refresh/next dwell retries them.
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
    else if action = "calendar" then
        openScreen("CalendarScreen")
    else if action = "catchUp" then
        openScreen("CatchUpScreen")
    else if action = "notifications" then
        showNotifications()
    end if
end sub

sub onSessionExpired()
    if m.account <> invalid then ZForgetAccount(m.account.key)
    server = ""
    server = ZStr(m.global.session.server)
    m.inboxTimer.control = "stop"
    m.inbox = invalid
    m.tabBar.unread = 0
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
        ' Roku certification: an invalid link lands on Home.
        if hasSession() then
            showTab("home")
            m.awaitingLinkPlayback = false
            launchComplete()
        end if
        showToast("That title isn't available on this server.")
        return
    end if
    ' Close any player first so the new title starts cleanly.
    while m.stack.count() > 1 and m.stack.peek().subtype() = "PlayerScreen"
        popScreen()
    end while
    kind = r.type
    if ZDeepLinkTarget(kind) = "play" then
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
    dialogDone()
    m.launched = true
    m.top.signalBeacon("AppLaunchComplete")
end sub

' Sign-in or "Who's watching" shown before Home counts as a launch dialog for
' Roku certification: AppDialogInitiate when it appears, AppDialogComplete
' when it is done, then AppLaunchComplete once Home is ready.
sub dialogStarted()
    if m.launched = true or m.launchDialog = true then return
    m.launchDialog = true
    m.top.signalBeacon("AppDialogInitiate")
end sub

sub dialogDone()
    if m.launchDialog <> true then return
    m.launchDialog = false
    m.top.signalBeacon("AppDialogComplete")
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
