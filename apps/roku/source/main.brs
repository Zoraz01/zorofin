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
        settings: {}
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
