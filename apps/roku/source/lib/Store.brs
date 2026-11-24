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
        if a.key <> key then list.push(a)
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
        ' Display, as in the Apple app's NativePreferences.
        showTitles: true,
        showProgress: true,
        showRatings: false,
        showQualityBadges: true,
        showUnreadBadge: true,
        posterScale: 1.0,
        reduceMotion: false,
        ' Controls.
        skipBack: 10,
        skipForward: 30
    }
    saved = ZRegRead("settings")
    if ZIsMap(saved) then
        for each k in defaults
            if saved[k] <> invalid then defaults[k] = saved[k]
        end for
    end if
    return defaults
end function

sub ZSaveSettings(settings as object)
    ZRegWrite("settings", settings)
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
