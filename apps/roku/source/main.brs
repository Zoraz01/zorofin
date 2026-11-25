' Zorofin for Roku: channel entry point.
' Owns the SceneGraph screen and forwards deep links (launch and roInput)
' to MainScene, which does all navigation.
sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)

    m.global = screen.getGlobalNode()
    m.global.addFields({
        session: {},
        features: {},
        appVersion: AppVersion(),
        settings: {},
        ' Server looks (looks.json): "0xRRGGBB" accent, card scale (0 = viewer's own).
        accent: "",
        ' Plugin extras the server turned on: { calendar, catchUp }.
        extras: {},
        ' Playback problem reports this run: { sent, refused }.
        playbackProblems: {},
        cardScale: 0.0,
        defaultCardScale: 0.0
    })

    scene = screen.CreateScene("MainScene")
    screen.show()
    scene.observeField("exitApp", port)
    ' roTextureManager only works on this thread: the scene hands over the
    ' image URLs of screens it hides or closes and they are unloaded here.
    scene.observeField("unloadImages", port)
    textures = CreateObject("roTextureManager")
    scene.launchArgs = DeepLinkArgs(args)

    input = CreateObject("roInput")
    input.setMessagePort(port)

    ' Roku's memory monitor: log warnings with the channel's headroom so low
    ' memory shows up in the developer console and crash reports.
    ' Low general memory comes from roDeviceInfo (roAppMemoryMonitor has no
    ' such method on Roku OS 15.3 and stops the channel at launch).
    memory = CreateObject("roAppMemoryMonitor")
    if memory <> invalid then
        memory.SetMessagePort(port)
        memory.EnableMemoryWarningEvent(true)
        print "[memory] limit "; FormatJson(memory.GetChannelMemoryLimit()); ", available "; memory.GetChannelAvailableMemory(); " KB"
    end if
    device = CreateObject("roDeviceInfo")
    device.SetMessagePort(port)
    device.EnableLowGeneralMemoryEvent(true)

    while true
        msg = wait(0, port)
        kind = type(msg)
        if kind = "roSGScreenEvent"
            if msg.isScreenClosed() then return
        else if kind = "roSGNodeEvent"
            if msg.getField() = "exitApp" and msg.getData() = true then
                screen.close()
                return
            else if msg.getField() = "unloadImages" then
                urls = msg.getData()
                if type(urls) = "roArray" and textures <> invalid then
                    for each url in urls
                        if type(url) = "roString" or type(url) = "String" then textures.UnloadBitmap(url)
                    end for
                    print "[textures] unloaded "; urls.count()
                end if
            end if
        else if kind = "roAppMemoryWarningEvent" or kind = "roAppMemoryNotificationEvent" or kind = "roDeviceInfoEvent"
            if memory <> invalid then
                print "[memory] "; kind; " used "; memory.GetMemoryLimitPercent(); "% , available "; memory.GetChannelAvailableMemory(); " KB"
            end if
        else if kind = "roInputEvent"
            if msg.isInput() then
                scene.inputArgs = DeepLinkArgs(msg.getInfo())
            end if
        end if
    end while
end sub

' Keeps only the deep-link keys Roku certification defines.
function DeepLinkArgs(args as dynamic) as object
    result = {}
    if type(args) <> "roAssociativeArray" then return result
    for each key in ["contentId", "mediaType"]
        value = args[key]
        if value <> invalid then result[key] = value.toStr().trim()
    end for
    return result
end function

function AppVersion() as string
    info = CreateObject("roAppInfo")
    return info.GetVersion()
end function
