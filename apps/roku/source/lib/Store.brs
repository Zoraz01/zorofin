' Saved servers, accounts and viewer settings in the channel's private
' registry section. Roku keeps each channel's registry separate from every
' other channel; tokens never leave the device except to their own server.

function ZRegistry() as object
    return CreateObject("roRegistrySection", "zorofin")
end function

function ZRegRead(key as string) as dynamic
    sec = ZRegistry()
    if not sec.Exists(key) then return invalid
    text = sec.Read(key)
    if text = "" then return invalid
    return ParseJson(text)
end function

sub ZRegWrite(key as string, value as dynamic)
    sec = ZRegistry()
    if value = invalid then
        sec.Delete(key)
    else
        sec.Write(key, FormatJson(value))
    end if
    sec.Flush()
end sub

' Accounts: [{ key, server, serverId, serverName, userId, userName, token, imageTag }]
function ZAccounts() as object
    list = ZRegRead("accounts")
    if not ZIsArray(list) then return []
    out = []
    for each a in list
        if ZIsMap(a) and ZStr(a.server) <> "" and ZStr(a.userId) <> "" and ZStr(a.token) <> "" then out.push(a)
    end for
    return out
end function

function ZAccountKey(serverId as string, userId as string) as string
    return LCase(serverId + ":" + userId)
end function

' Adds or replaces an account and makes it the active one.
sub ZSaveAccount(account as object, remember = true as boolean)
    account.key = ZAccountKey(ZStr(account.serverId), ZStr(account.userId))
    list = []
    for each a in ZAccounts()
        if a.key <> account.key then list.push(a)
    end for
    if remember then list.unshift(account)
    ' A small cap keeps the registry well under Roku's 16 KB channel limit.
    while list.count() > 8
        list.pop()
    end while
    ZRegWrite("accounts", list)
    ZRegWrite("active", account.key)
end sub

sub ZForgetAccount(key as string)
    list = []
    for each a in ZAccounts()
        if a.key <> key then
            list.push(a)
        else
            scope = ZNotificationScope(a)
            if scope <> "" then DeleteFile("cachefs:/zorofin-home-v1-" + scope + ".json")
        end if
    end for
    ZRegWrite("accounts", list)
    if ZRegRead("active") = key then ZRegWrite("active", invalid)
end sub

function ZActiveAccount() as dynamic
    key = ZRegRead("active")
    if key = invalid then return invalid
    for each a in ZAccounts()
        if a.key = key then return a
    end for
    return invalid
end function

sub ZSetActive(key as dynamic)
    ZRegWrite("active", key)
end sub

' Last server typed, so the connect field is prefilled next time.
function ZLastServer() as string
    return ZStr(ZRegRead("lastServer"))
end function

sub ZSetLastServer(url as string)
    ZRegWrite("lastServer", url)
end sub

' Viewer settings with defaults (Apple "Playback" settings subset).
function ZSettings() as object
    defaults = {
        maxBitrate: 0,            ' 0 = Auto (device maximum)
        subtitles: "default",     ' default | always | off
        autoplayNext: true,
        skipIntro: true,
        ' Home: rest on a movie or show to play its trailer, muted.
        autoplayPreviews: true,
        ' Player: chapter names can give the story away, so off until asked for.
        showChapters: false,
        ' Tell the server owner when a title won't start or keeps failing.
        sendPlaybackReports: true,
        ' Display, as in the Apple app's NativePreferences.
        showTitles: true,
        showProgress: true,
        showRatings: true,
        showQualityBadges: true,
        showUnreadBadge: true,
        posterScale: 1.0,
        posterSizeChosen: false,
        reduceMotion: false,
        ' Controls.
        skipBack: 10,
        skipForward: 30
    }
    saved = ZRegRead("settings")
    if ZIsMap(saved) then
        ' Iterate a copy of the keys: writing into an associative array while
        ' "for each" walks it skips entries, so saved toggles such as Show
        ' chapters and the report opt-out came back as defaults (Nov 24).
        ' Match keys without regard to case: dot assignments (p.showChapters)
        ' are written in lower case, and parsed JSON maps can be case-sensitive,
        ' so saved toggles came back as defaults (Roku tasks 227/327, Nov 24).
        lower = {}
        for each sk in saved
            lower[LCase(sk)] = saved[sk]
        end for
        for each k in defaults.Keys()
            v = lower[LCase(k)]
            if v <> invalid then defaults[k] = v
        end for
    end if
    key = ZPosterSettingKey()
    ' Migrate the old device-wide choice only to the account using it.
    if ZIsMap(saved) and (saved.doesExist("posterScale") or saved.doesExist("posterscale")) then
        oldScale = saved["posterScale"]
        if oldScale = invalid then oldScale = saved["posterscale"]
        if key <> "" and ZNum(oldScale, 1.0) <> 1.0 and ZRegRead(key) = invalid then ZRegWrite(key, oldScale)
        for each dead in ["posterScale", "posterscale", "posterSizeChosen", "postersizechosen"]
            saved.delete(dead)
        end for
        ZRegWrite("settings", saved)
    end if
    defaults.posterScale = 1.0
    defaults.posterSizeChosen = false
    if key <> "" then
        scale = ZRegRead(key)
        if ZIsPosterScale(scale) then
            defaults.posterScale = scale
            defaults.posterSizeChosen = true
        end if
    end if
    return defaults
end function

function ZPosterSettingKey() as string
    account = ZActiveAccount()
    if account = invalid then return ""
    return "poster:" + ZStr(account.key)
end function

function ZIsPosterScale(value as dynamic) as boolean
    return ZNum(value, 0) = 0.85 or ZNum(value, 0) = 1.0 or ZNum(value, 0) = 1.2
end function

sub ZSaveSettings(settings as object)
    key = ZPosterSettingKey()
    if key <> "" then
        if settings.posterSizeChosen = true and ZIsPosterScale(settings.posterScale) then
            ZRegWrite(key, settings.posterScale)
        else
            ZRegWrite(key, invalid)
        end if
    end if
    general = {}
    for each k in settings
        lk = LCase(k)
        if lk <> "posterscale" and lk <> "postersizechosen" then general[lk] = settings[k]
    end for
    ZRegWrite("settings", general)
end sub

' Stable per-channel device id from Roku (not the serial number).
function ZDeviceId() as string
    di = CreateObject("roDeviceInfo")
    id = di.GetChannelClientId()
    if id = invalid or id = "" then id = "roku-" + di.GetRandomUUID()
    return id
end function

function ZDeviceName() as string
    di = CreateObject("roDeviceInfo")
    name = di.GetFriendlyName()
    if name = invalid or name = "" then name = "Roku " + di.GetModelDisplayName()
    return name
end function

' MARK: Support replies seen on this Roku (Apple NotificationHistory)

' A later reply on the same ticket is a new notification, so the key covers
' the ticket, its time and its message.
function ZReplyKey(reply as object) as string
    ba = CreateObject("roByteArray")
    ba.FromAsciiString(ZStr(reply.id) + Chr(10) + ZStr(reply.updatedAt) + Chr(10) + ZStr(reply.message))
    digest = CreateObject("roEVPDigest")
    digest.Setup("sha256")
    return Left(digest.Process(ba), 24)
end function

function ZSeenRepliesKey() as string
    a = ZActiveAccount()
    if a = invalid then return ""
    return "seen:" + a.key
end function

function ZSeenReplies() as object
    key = ZSeenRepliesKey()
    if key = "" then return {}
    saved = ZRegRead(key)
    out = {}
    if ZIsArray(saved) then
        for each k in saved
            out[k] = true
        end for
    end if
    return out
end function

sub ZMarkRepliesSeen(replies as object)
    if replies.count() = 0 then return
    key = ZSeenRepliesKey()
    if key = "" then return
    seen = ZSeenReplies()
    list = []
    for each k in seen
        list.push(k)
    end for
    for each r in replies
        k = ZReplyKey(r)
        if seen[k] <> true then list.push(k)
    end for
    ' Bounded so the registry stays small.
    while list.count() > 200
        list.shift()
    end while
    ZRegWrite(key, list)
end sub

function ZUnreadReplies(replies as dynamic) as integer
    if not ZIsArray(replies) then return 0
    settings = ZSettings()
    if settings.showUnreadBadge = false then return 0
    seen = ZSeenReplies()
    count = 0
    for each r in replies
        if seen[ZReplyKey(r)] <> true then count = count + 1
    end for
    return count
end function

' The last server looks seen per server, so the first frame after launch
' already wears them.
function ZCachedLooks(server as string) as object
    saved = ZRegRead("looks")
    if ZIsMap(saved) and ZIsMap(saved[server]) then return saved[server]
    return { accent: "", cardScale: 0.0 }
end function

sub ZSaveLooks(server as string, looks as object)
    saved = ZRegRead("looks")
    if not ZIsMap(saved) then saved = {}
    saved[server] = { accent: ZStr(looks.accent), cardScale: ZNum(looks.cardScale, 0.0), defaultCardScale: ZNum(looks.defaultCardScale, 0.0) }
    ZRegWrite("looks", saved)
end sub

' Catch Up titles this viewer skipped, on this Roku only (as the web keeps
' them per browser). Capped so the registry stays small.
function ZCatchUpSkips() as object
    saved = ZRegRead("catchUpSkips:" + ZCatchUpAccount())
    if ZIsArray(saved) then return saved
    return []
end function

sub ZSaveCatchUpSkips(skips as object)
    ZRegWrite("catchUpSkips:" + ZCatchUpAccount(), skips)
end sub

function ZCatchUpAccount() as string
    s = m.global.session
    if s = invalid then return ""
    return ZStr(s.serverId) + ":" + ZStr(s.userId)
end function


' Bounded device fallback/migration receipts. The server stores full account
' history; Roku's small registry stores no titles or message text here.
function ZLocalRequestReads() as object
    key = ZSeenRepliesKey()
    saved = ZRegRead("requests:" + key)
    state = { initialized: false, requests: {} }
    if key = "" or not ZIsMap(saved) then return state
    state.initialized = saved.initialized = true
    if ZIsArray(saved.ids) then
        for each id in saved.ids
            state.requests[id.toStr()] = true
        end for
    end if
    return state
end function

sub ZMarkRequestsSeen(ids as object, initialize = false as boolean)
    if ids.count() = 0 and not initialize then return
    key = ZSeenRepliesKey()
    if key = "" then return
    state = ZLocalRequestReads()
    ordered = []
    for each id in state.requests
        ordered.push(id.toInt())
    end for
    for each id in ids
        if state.requests[id.toStr()] <> true then
            ordered.push(id)
            state.requests[id.toStr()] = true
        end if
    end for
    while ordered.count() > 200
        ordered.shift()
    end while
    ZRegWrite("requests:" + key, { initialized: initialize or state.initialized, ids: ordered })
end sub
