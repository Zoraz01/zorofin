' Settings pages from the Apple app's NativeSettingsView. Rows show their
' value on the right: OK flips a switch or opens a list of choices.

sub init()
    m.top.findNode("title").font = ZFont(36, "bold")
    m.rows = m.top.findNode("rows")
    m.rows.observeField("selected", "onRow")
    m.prefs = ZSettings()
    m.account = invalid
    m.accountError = ""
    m.languages = invalid
    m.dialog = invalid
    m.busy = false
end sub

sub load()
    titles = { account: "Account", display: "Home & display", playback: "Playback", subtitles: "Subtitles", controls: "Controls", notifications: "Notifications", storage: "Storage & app", help: "Help & about" }
    title = titles[m.top.page]
    if title = invalid then title = "Settings"
    m.top.findNode("title").text = title
    if UsesAccount() then fetchAccount()
    paint()
end sub

function UsesAccount() as boolean
    p = m.top.page
    return p = "account" or p = "playback" or p = "subtitles"
end function

sub fetchAccount()
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "viewerSettings" }
    task.observeField("response", "onAccount")
    task.control = "RUN"
    m.accountTask = task
end sub

sub onAccount(event as object)
    r = event.getData()
    if r.ok then
        m.account = r
        m.accountError = ""
        syncLocal()
    else if r.error = "unauthorized" then
        m.top.sessionExpired = true
        return
    else
        m.accountError = "Account settings couldn't load. " + ZErrorText(r.error)
    end if
    paint()
end sub

' The player reads two account defaults from this Roku's settings.
sub syncLocal()
    v = m.account.values
    ' Re-read: another Settings page may have saved since this one opened.
    p = ZSettings()
    p.autoplayNext = v.EnableNextEpisodeAutoPlay = true
    mode = v.SubtitleMode
    if mode = "None" then
        p.subtitles = "off"
    else if mode = "Always" then
        p.subtitles = "always"
    else
        p.subtitles = "default"
    end if
    saveLocal(p)
end sub

sub saveLocal(p as object)
    m.prefs = p
    ZSaveSettings(p)
    m.global.settings = p
end sub

function OnOff(value as boolean) as string
    if value then return "On"
    return "Off"
end function

' MARK: Pages

sub paint()
    m.prefs = ZSettings()
    rows = []
    page = m.top.page
    if page = "account" then
        rows = AccountRows()
    else if page = "display" then
        rows = DisplayRows()
    else if page = "playback" then
        rows = PlaybackRows()
    else if page = "subtitles" then
        rows = SubtitleRows()
    else if page = "controls" then
        rows = ControlRows()
    else if page = "notifications" then
        rows = NotificationRows()
    else if page = "storage" then
        rows = StorageRows()
    else if page = "help" then
        rows = HelpRows()
    end if
    focus = m.rows.focusedId
    m.rows.rows = rows
    if focus <> "" then m.rows.callFunc("focusRow", focus)
end sub

function AccountRows() as object
    s = m.global.session
    rows = [{ header: true, title: "Signed in" }]
    name = ZStr(s.userName)
    if m.account <> invalid then name = m.account.name
    rows.push({ id: "info:name", title: "Name", value: name })
    rows.push({ id: "info:server", title: "Server", value: ZStr(s.serverName) })
    rows.push({ id: "info:address", title: "Address", value: ZStr(s.server) })
    rows.push({ header: true, title: "Change password" })
    if m.account = invalid then
        rows.append(AccountStatus())
    else if not m.account.canEdit then
        rows.push({ note: "Your server administrator manages this account's settings." })
    else
        rows.push({ id: "password", title: "Update password", icon: "lock" })
        rows.push({ note: "Other devices may need to sign in again after you change your password." })
    end if
    rows.push({ header: true, title: "Other devices" })
    rows.push({ id: "quickConnect", title: "Quick Connect", icon: "phone" })
    rows.push({ note: "Sign in a phone, tablet or computer with a six-digit code." })
    return rows
end function

function AccountStatus() as object
    if m.accountError <> "" then return [{ id: "retry", title: "Try again", icon: "refresh" }, { note: m.accountError }]
    return [{ note: "Loading account settings…" }]
end function

function DisplayRows() as object
    p = m.prefs
    sizes = { "0.85": "Compact", "1": "Comfortable", "1.2": "Large" }
    size = sizes[PosterKey(ZPosterScale())]
    if size = invalid then size = "Comfortable"
    poster = { id: "posterScale", title: "Poster size", value: size }
    ' The server's looks pick the card size for every viewer.
    if m.global.cardScale > 0 then poster = { id: "posterLocked", title: "Poster size", value: "Set by your server" }
    return [
        { header: true, title: "On this device" },
        poster,
        { id: "toggle:showTitles", title: "Show titles under posters", value: OnOff(p.showTitles) },
        { id: "toggle:showProgress", title: "Show watching progress", value: OnOff(p.showProgress) },
        { id: "toggle:showRatings", title: "Show ratings", value: OnOff(p.showRatings) },
        { id: "toggle:showQualityBadges", title: "Show quality badges", value: OnOff(p.showQualityBadges) },
        { id: "toggle:reduceMotion", title: "Reduce motion", value: OnOff(p.reduceMotion) },
        { note: "Your Roku's accessibility settings are always respected." },
        { header: true, title: "Home" },
        { id: "toggle:autoplayPreviews", title: "Autoplay trailer previews on Home", value: OnOff(p.autoplayPreviews) },
        { id: "toggle:showUnreadBadge", title: "Show unread badge", value: OnOff(p.showUnreadBadge) }
    ]
end function

function PosterKey(scale as dynamic) as string
    if scale < 0.9 then return "0.85"
    if scale > 1.1 then return "1.2"
    return "1"
end function

function QualityLabel(bitrate as dynamic) as string
    if bitrate = invalid or bitrate <= 0 then return "Automatic"
    return Int(bitrate / 1000000).toStr() + " Mbps"
end function

function PlaybackRows() as object
    p = m.prefs
    ' Controls folds into Playback (docs/design/TV_PROFILE_MENU.md).
    rows = [
        { header: true, title: "On this device" },
        { id: "quality", title: "Streaming quality", value: QualityLabel(p.maxBitrate) },
        { note: "Streaming quality is a maximum bitrate. Your server and connection determine the available quality." },
        { header: true, title: "In the player" },
        { id: "toggle:skipIntro", title: "Show Skip intro", value: OnOff(p.skipIntro) },
        { id: "skipBack", title: "Instant replay", value: p.skipBack.toStr() + " seconds" },
        { id: "toggle:showChapters", title: "Show chapters", value: OnOff(p.showChapters) },
        { note: "Chapter names in the player can give the story away. Off by default." }
    ]
    rows.push({ header: true, title: "Account defaults" })
    if m.account = invalid then
        rows.append(AccountStatus())
        return rows
    end if
    v = m.account.values
    rows.append([
        { id: "lang:AudioLanguagePreference", title: "Preferred audio", value: LanguageName(v.AudioLanguagePreference) },
        { id: "account:PlayDefaultAudioTrack", title: "Prefer the original default audio track", value: OnOff(v.PlayDefaultAudioTrack) },
        { id: "account:RememberAudioSelections", title: "Remember audio selections", value: OnOff(v.RememberAudioSelections) },
        { id: "account:EnableNextEpisodeAutoPlay", title: "Play the next episode automatically", value: OnOff(v.EnableNextEpisodeAutoPlay) }
    ])
    if not m.account.canEdit then rows.push({ note: "Your server administrator manages these account defaults." })
    return rows
end function

function SubtitleModes() as object
    return [
        { id: "Default", title: "Default" },
        { id: "Always", title: "Always" },
        { id: "Smart", title: "Smart" },
        { id: "OnlyForced", title: "Forced only" },
        { id: "None", title: "Off" }
    ]
end function

function SubtitleRows() as object
    rows = [
        { header: true, title: "Appearance on this device" },
        { note: "Subtitle size, colour and background follow your Roku's settings: Settings > Accessibility > Captions style." },
        { header: true, title: "Account defaults" }
    ]
    if m.account = invalid then
        rows.append(AccountStatus())
        return rows
    end if
    v = m.account.values
    mode = "Default"
    for each o in SubtitleModes()
        if o.id = v.SubtitleMode then mode = o.title
    end for
    rows.append([
        { id: "lang:SubtitleLanguagePreference", title: "Preferred language", value: LanguageName(v.SubtitleLanguagePreference) },
        { id: "subtitleMode", title: "Subtitle mode", value: mode },
        { id: "account:RememberSubtitleSelections", title: "Remember subtitle selections", value: OnOff(v.RememberSubtitleSelections) },
        { note: "Smart uses subtitles when the audio differs from your preferred subtitle language. Forced only shows required translations. A track chosen on a title overrides these defaults." }
    ])
    if not m.account.canEdit then rows.push({ note: "Your server administrator manages these account defaults." })
    return rows
end function

function ControlRows() as object
    return [
        { header: true, title: "On this device" },
        { id: "skipBack", title: "Instant replay", value: m.prefs.skipBack.toStr() + " seconds" },
        { note: "How far the Instant replay button jumps back in the player. Left and Right on the remote scrub through the timeline." }
    ]
end function

function NotificationRows() as object
    ' The unread badge switch is on Home & display.
    return [
        { note: "Email and push alerts can be set up in the Zorofin app on your phone or on the web." }
    ]
end function

' Help & about: support, privacy, problem reports, then this Roku.
function HelpRows() as object
    rows = [{ header: true, title: "Help" }]
    features = m.global.features
    if features <> invalid and ZNum(features.support, 0) = 1 then rows.push({ id: "support", title: "Message your server owner", icon: "support" })
    rows.push({ id: "appSupport", title: "App Support", icon: "help" })
    rows.push({ id: "privacy", title: "Privacy Policy", icon: "privacy" })
    ' Only on servers that collect reports; the server owner can turn it off for everyone.
    if features <> invalid and ZNum(features.playbackReports, 0) = 1 then
        rows.push({ header: true, title: "Problem reports" })
        rows.push({ id: "toggle:sendPlaybackReports", title: "Send playback problem reports to this server", value: OnOff(m.prefs.sendPlaybackReports <> false) })
        rows.push({ note: "When a title won't start or keeps buffering, the app tells your server owner the title, app version and what went wrong. Nothing leaves your server." })
    end if
    rows.append(StorageRows())
    return rows
end function

function StorageRows() as object
    return [
        { header: true, title: "This Roku" },
        { id: "info:version", title: "Zorofin version", value: ZStr(m.global.appVersion) },
        { id: "reset", title: "Reset app preferences", icon: "refresh" },
        { note: "Resets Home & display and Playback on this Roku. Your accounts and your server's settings stay." }
    ]
end function

function LanguageName(code as dynamic) as string
    c = ZStr(code)
    if c = "" then return "Automatic"
    if m.languages <> invalid then
        for each l in m.languages
            if l.id = c then return l.name
        end for
    end if
    return UCase(c)
end function

' MARK: Actions

sub onRow(event as object)
    id = event.getData()
    if m.busy or Left(id, 5) = "info:" then return
    ' Start from what is stored, not this page's copy from when it opened:
    ' Settings pages stay alive in the stack, and saving a stale copy undid
    ' Show chapters and the report opt-out (Roku task 227, Nov 24).
    m.prefs = ZSettings()
    p = m.prefs
    if Left(id, 7) = "toggle:" then
        key = Mid(id, 8)
        p[key] = not (p[key] = true)
        saveLocal(p)
        paint()
    else if Left(id, 8) = "account:" then
        if m.account = invalid or not m.account.canEdit then return
        key = Mid(id, 9)
        changes = {}
        changes[key] = not (m.account.values[key] = true)
        save(changes)
    else if Left(id, 5) = "lang:" then
        if m.account = invalid or not m.account.canEdit then return
        m.langKey = Mid(id, 6)
        if m.languages = invalid then
            task = CreateObject("roSGNode", "JellyfinTask")
            task.request = { cmd: "languages" }
            task.observeField("response", "onLanguages")
            task.control = "RUN"
            m.langTask = task
        else
            chooseLanguage()
        end if
    else if id = "posterScale" then
        current = PosterKey(ZPosterScale())
        choose("posterScale", "Poster size", [
            { id: "0.85", title: "Compact", checked: current = "0.85" },
            { id: "1", title: "Comfortable", checked: current = "1" },
            { id: "1.2", title: "Large", checked: current = "1.2" }
        ])
    else if id = "quality" then
        options = [{ id: "0", title: "Automatic", checked: p.maxBitrate <= 0 }]
        for each mbps in [2, 4, 8, 12, 20, 40]
            options.push({ id: (mbps * 1000000).toStr(), title: mbps.toStr() + " Mbps", checked: p.maxBitrate = mbps * 1000000 })
        end for
        choose("quality", "Streaming quality", options)
    else if id = "subtitleMode" then
        if m.account = invalid or not m.account.canEdit then return
        options = []
        for each o in SubtitleModes()
            options.push({ id: o.id, title: o.title, checked: o.id = m.account.values.SubtitleMode })
        end for
        choose("subtitleMode", "Subtitle mode", options)
    else if id = "skipBack" then
        options = []
        for each s in [5, 10, 15, 30, 60]
            options.push({ id: s.toStr(), title: s.toStr() + " seconds", checked: p.skipBack = s })
        end for
        choose("skipBack", "Instant replay", options)
    else if id = "password" then
        m.passwords = []
        m.passwordStep = 0
        if m.account.hasPassword then
            askPassword("Current password")
        else
            m.passwords.push("")
            askPassword("New password")
        end if
    else if id = "quickConnect" or id = "support" then
        ' MainScene opens these screens.
        m.top.action = id
    else if id = "privacy" then
        choose("info", "Privacy Policy", [{ id: "ok", title: "OK" }], "Zorofin connects only to the Jellyfin server you choose and has no ads, tracking or analytics. Read the full policy at zorofin.app/privacy on your phone or computer.")
    else if id = "appSupport" then
        choose("info", "App Support", [{ id: "ok", title: "OK" }], "Zorofin " + ZStr(m.global.appVersion) + " for Roku, by Vitality Labs LLC. For help, visit zorofin.app/support on your phone or computer. Zorofin is independently developed and is not affiliated with the Jellyfin project.")
    else if id = "reset" then
        choose("reset", "Reset app preferences?", [{ id: "yes", title: "Reset" }, { id: "no", title: "Cancel" }], "Display, Playback and Controls on this Roku go back to their defaults.")
    else if id = "retry" then
        m.accountError = ""
        paint()
        fetchAccount()
    end if
end sub

sub onLanguages(event as object)
    r = event.getData()
    if not r.ok then
        m.top.toast = "Languages couldn't load. " + ZErrorText(r.error)
        return
    end if
    m.languages = r.languages
    chooseLanguage()
end sub

sub chooseLanguage()
    current = ZStr(m.account.values[m.langKey])
    options = [{ id: "", title: "Automatic", checked: current = "" }]
    for each l in m.languages
        options.push({ id: l.id, title: l.name, checked: l.id = current })
    end for
    title = "Preferred audio"
    if m.langKey = "SubtitleLanguagePreference" then title = "Preferred language"
    choose("lang", title, options)
end sub

sub choose(kind as string, title as string, options as object, message = "" as string)
    d = CreateObject("roSGNode", "PickerDialog")
    d.title = title
    d.message = message
    d.options = options
    d.observeField("result", "onChoice")
    m.choiceKind = kind
    showDialog(d)
end sub

sub showDialog(d as object)
    m.top.appendChild(d)
    m.dialog = d
    m.top.modal = true
    d.focusIn = true
end sub

sub closeDialog()
    if m.dialog <> invalid then m.top.removeChild(m.dialog)
    m.dialog = invalid
    m.top.modal = false
    m.rows.setFocus(true)
end sub

sub onChoice(event as object)
    r = event.getData()
    closeDialog()
    if r = invalid or r.id = invalid then return
    m.prefs = ZSettings()
    p = m.prefs
    kind = m.choiceKind
    if kind = "posterScale" then
        p.posterScale = r.id.toFloat()
        p.posterSizeChosen = true
        saveLocal(p)
    else if kind = "quality" then
        p.maxBitrate = r.id.toInt()
        saveLocal(p)
    else if kind = "skipBack" then
        p.skipBack = r.id.toInt()
        saveLocal(p)
    else if kind = "subtitleMode" then
        save({ SubtitleMode: r.id })
    else if kind = "lang" then
        changes = {}
        changes[m.langKey] = r.id
        save(changes)
    else if kind = "reset" and r.id = "yes" then
        ZSaveSettings({})
        saveLocal(ZSettings())
        if m.account <> invalid then syncLocal()
        m.top.toast = "App preferences reset"
    end if
    paint()
end sub

sub save(changes as object)
    m.busy = true
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "saveViewerSettings", changes: changes }
    task.observeField("response", "onSaved")
    task.control = "RUN"
    m.saveTask = task
end sub

sub onSaved(event as object)
    m.busy = false
    r = event.getData()
    if r.ok then
        m.account = r
        syncLocal()
        m.top.toast = "Saved"
    else if r.error = "unauthorized" then
        m.top.sessionExpired = true
        return
    else if r.error = "forbidden" then
        m.top.toast = "Your server administrator manages these settings."
    else
        m.top.toast = "Couldn't save that. " + ZErrorText(r.error)
    end if
    paint()
end sub

' MARK: Password

sub askPassword(title as string)
    entry = CreateObject("roSGNode", "TextEntry")
    entry.title = title
    entry.secure = true
    entry.observeField("result", "onPassword")
    m.dialog = entry
    m.top.modal = true
    m.top.appendChild(entry)
    entry.focusIn = true
end sub

sub onPassword(event as object)
    r = event.getData()
    closeDialog()
    if r = invalid or not r.ok then return
    m.passwords.push(r.text)
    if m.passwords.count() = 1 then
        askPassword("New password")
    else if m.passwords.count() = 2 then
        if m.passwords[1] = "" then
            m.top.toast = "Enter a new password."
            return
        end if
        askPassword("Confirm new password")
    else
        if m.passwords[2] <> m.passwords[1] then
            m.top.toast = "The new passwords don't match."
            return
        end if
        m.busy = true
        task = CreateObject("roSGNode", "JellyfinTask")
        task.request = { cmd: "changePassword", current: m.passwords[0], newPassword: m.passwords[1] }
        task.observeField("response", "onPasswordSaved")
        task.control = "RUN"
        m.passwordTask = task
        m.passwords = []
    end if
end sub

sub onPasswordSaved(event as object)
    m.busy = false
    r = event.getData()
    if r.ok then
        m.top.toast = "Password updated"
    else if r.error = "unauthorized" or r.error = "forbidden" then
        ' Jellyfin answers a wrong current password with 401 or 403 here.
        m.top.toast = "That password didn't work."
    else
        m.top.toast = "Couldn't update the password. " + ZErrorText(r.error)
    end if
end sub

sub restoreFocus()
    if m.dialog <> invalid then
        m.dialog.focusIn = true
    else
        m.rows.setFocus(true)
    end if
end sub
