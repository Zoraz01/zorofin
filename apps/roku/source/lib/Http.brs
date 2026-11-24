' Blocking HTTP for task threads only (roUrlTransfer is not allowed on the
' render thread). Every authenticated call is pinned to the session's server.

' Returns { ok, status, text, json, error } where error is one of
' "network", "unauthorized", "forbidden", "notFound", "server", "invalid".
function ZHttp(method as string, url as string, headers as object, body = invalid as dynamic, timeoutMs = 20000 as integer) as object
    if url = "" then return { ok: false, status: 0, error: "invalid", text: "" }
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    xfer.EnableEncodings(true)
    xfer.RetainBodyOnError(true)
    if LCase(Left(url, 6)) = "https:" then
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.InitClientCertificates()
    end if
    xfer.AddHeader("Accept", "application/json")
    for each key in headers
        xfer.AddHeader(key, headers[key])
    end for
    xfer.SetRequest(method)
    started = false
    if body <> invalid then
        xfer.AddHeader("Content-Type", "application/json")
        payload = body
        if type(body) <> "roString" and type(body) <> "String" then payload = FormatJson(body)
        started = xfer.AsyncPostFromString(payload)
    else if method = "GET" then
        started = xfer.AsyncGetToString()
    else
        started = xfer.AsyncPostFromString("")
    end if
    if not started then return { ok: false, status: 0, error: "network", text: "" }

    msg = wait(timeoutMs, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        return { ok: false, status: 0, error: "network", text: "" }
    end if
    status = msg.GetResponseCode()
    text = msg.GetString()
    result = { ok: false, status: status, text: text, json: invalid, error: "" }
    if status >= 200 and status < 300 then
        result.ok = true
        if text <> "" then result.json = ParseJson(text)
        return result
    end if
    if status = 401 then
        result.error = "unauthorized"
    else if status = 403 then
        result.error = "forbidden"
    else if status = 404 then
        result.error = "notFound"
    else if status <= 0 then
        result.error = "network"
    else
        result.error = "server"
    end if
    return result
end function

