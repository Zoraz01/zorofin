sub init()
    m.top.findNode("resultIcon").blendColor = ZAccent()
    m.top.findNode("resultTitle").color = ZAccent()
    m.top.findNode("title").font = ZFont(32, "bold")
    m.top.findNode("intro").font = ZFont(22)
    m.top.findNode("sender").font = ZFont(20, "semibold")
    m.top.findNode("consentText").font = ZFont(18)
    m.top.findNode("resultTitle").font = ZFont(24, "semibold")
    m.top.findNode("resultDetail").font = ZFont(22)
    m.issue = m.top.findNode("issue")
    m.media = m.top.findNode("media")
    m.description = m.top.findNode("description")
    m.consent = m.top.findNode("consent")
    m.send = m.top.findNode("send")
    m.again = m.top.findNode("again")
    m.issues = ["Playback / buffering problem", "Live TV issue", "Download not appearing / slow",
                "Request a 4K movie upgrade", "Subtitle or captions problem", "Corrupted video or audio",
                "Feature request", "Other"]
    m.issueText = m.issues[0]
    m.agreed = false
    m.sending = false
    m.order = [m.issue, m.media, m.description, m.consent, m.send]
    m.issue.observeField("selected", "chooseIssue")
    m.media.observeField("selected", "editMedia")
    m.description.observeField("selected", "editDescription")
    m.consent.observeField("selected", "toggleConsent")
    m.send.observeField("selected", "sendReport")
    m.again.observeField("selected", "startAgain")
    m.again.buttons = [{ id: "again", text: "Start another report" }]
    s = m.global.session
    m.top.findNode("sender").text = "Sending as " + ZStr(s.userName)
    paint()
end sub

sub paint()
    m.issue.rows = [{ id: "issue", title: m.issueText, icon: "message", value: "Change" }]
    check = "check"
    if m.agreed then check = "check-filled"
    m.consent.rows = [{ id: "consent", title: "I agree to share this report for server support and possible AI processing", icon: check, tint: ZTheme().jade }]
    valid = m.description.value.trim() <> "" and Len(m.description.value) <= 1500 and Len(m.media.value) <= 200
    m.send.buttons = [{ id: "send", text: "Send report", style: "primary", disabled: not valid or not m.agreed or m.sending }]
end sub

sub restoreFocus()
    if m.top.findNode("result").visible then
        m.again.setFocus(true)
    else
        m.issue.setFocus(true)
    end if
end sub

sub chooseIssue()
    picker = CreateObject("roSGNode", "PickerDialog")
    picker.title = "Issue"
    options = []
    for each i in m.issues
        options.push({ id: i, title: i, checked: i = m.issueText })
    end for
    picker.options = options
    picker.observeField("result", "onIssue")
    m.top.appendChild(picker)
    picker.focusIn = true
    m.picker = picker
end sub

sub onIssue(event as object)
    r = event.getData()
    m.top.removeChild(m.picker)
    m.picker = invalid
    if r <> invalid and r.id <> invalid then m.issueText = r.id
    paint()
    m.issue.setFocus(true)
end sub

sub openEntry(title as string, value as string, target as string)
    entry = CreateObject("roSGNode", "TextEntry")
    entry.title = title
    entry.text = value
    entry.observeField("result", "onEntry")
    m.entryTarget = target
    m.entry = entry
    m.top.modal = true
    m.top.appendChild(entry)
    entry.focusIn = true
end sub

sub onEntry(event as object)
    r = event.getData()
    m.top.removeChild(m.entry)
    m.entry = invalid
    m.top.modal = false
    if m.entryTarget = "media" then
        if r.ok then m.media.value = Left(r.text.trim(), 200)
        m.media.setFocus(true)
    else
        if r.ok then m.description.value = Left(r.text.trim(), 1500)
        m.description.setFocus(true)
    end if
    paint()
end sub

sub editMedia()
    openEntry("Movie, show or channel", m.media.value, "media")
end sub

sub editDescription()
    openEntry("What happened?", m.description.value, "description")
end sub

sub toggleConsent()
    m.agreed = not m.agreed
    paint()
    m.consent.setFocus(true)
end sub

sub sendReport()
    if m.sending or not m.agreed then return
    m.sending = true
    m.agreed = false
    paint()
    task = CreateObject("roSGNode", "JellyfinTask")
    task.request = { cmd: "submitSupport", issueType: m.issueText, description: m.description.value, affectedMedia: m.media.value }
    task.observeField("response", "onSent")
    task.control = "RUN"
    m.task = task
end sub

sub onSent(event as object)
    r = event.getData()
    m.sending = false
    resultIcon = m.top.findNode("resultIcon")
    title = m.top.findNode("resultTitle")
    detail = m.top.findNode("resultDetail")
    if r.ok then
        resultIcon.uri = "pkg:/images/icons/check-filled.png"
        title.text = "Report received"
        detail.text = "Reference: " + r.ticketId + Chr(10) + "Your server’s support agent will review it. Watch Notifications for a reply."
        m.description.value = ""
        m.media.value = ""
    else if r.error = "rejected" or r.error = "invalidReport" then
        resultIcon.uri = "pkg:/images/icons/alert.png"
        title.text = "Not sent"
        detail.text = "The server did not accept this report. Check your connection and account access before trying again."
    else
        resultIcon.uri = "pkg:/images/icons/alert.png"
        title.text = "Delivery unconfirmed"
        detail.text = "Delivery could not be confirmed. Your report may have arrived. Check Notifications or contact your server owner before sending it again."
    end if
    m.top.findNode("form").visible = false
    m.top.findNode("result").visible = true
    m.again.setFocus(true)
end sub

sub startAgain()
    m.top.findNode("result").visible = false
    m.top.findNode("form").visible = true
    paint()
    m.issue.setFocus(true)
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if not press then return false
    if m.top.findNode("result").visible then return false
    index = -1
    for i = 0 to m.order.count() - 1
        if m.order[i].isInFocusChain() then index = i
    end for
    if index < 0 then return false
    if key = "down" and index < m.order.count() - 1 then
        m.order[index + 1].setFocus(true)
        return true
    else if key = "up" and index > 0 then
        m.order[index - 1].setFocus(true)
        return true
    end if
    return false
end function
