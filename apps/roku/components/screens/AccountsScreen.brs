sub init()
    m.grid = m.top.findNode("grid")
    m.art = m.top.findNode("art")
    m.card = m.top.findNode("card")
    m.top.findNode("title").font = ZFont(64, "bold")
    m.top.findNode("was").font = ZFont(22)
    m.top.findNode("line").font = ZFont(30, "semibold")
    m.top.findNode("hint").font = ZFont(22)
    m.top.findNode("hint").text = "Press * on an account to remove it from this Roku."
    m.spots = {}
    m.grid.observeField("itemSelected", "onSelected")
    m.grid.observeField("itemFocused", "onFocused")
end sub

sub build()
    content = CreateObject("roSGNode", "ContentNode")
    m.spots = {}
    for each a in m.top.accounts
        node = content.createChild("ContentNode")
        node.id = a.key
        node.title = ZStr(a.userName)
        node.HDPosterUrl = ZUserImageUrl(a.server, a.userId, a.imageTag, 240)
        ' Built-in scene for the backdrop when the profile has no history.
        node.SDPosterUrl = "pkg:/images/scenes/scene-" + ZSceneAvatarName(a.userId) + ".jpg"
        spot = ReadSpotlight(LCase(ZStr(a.key)))
        if ZIsMap(spot) then m.spots[a.key] = spot
    end for
    add = content.createChild("ContentNode")
    add.id = "add"
    add.title = "Add"
    m.grid.content = content
    showSpotlight(0)
end sub

function ReadSpotlight(key as string) as dynamic
    sec = CreateObject("roRegistrySection", "zorofin")
    name = "spotlight:" + key
    if not sec.Exists(name) then return invalid
    return ParseJson(sec.Read(name))
end function

sub restoreFocus()
    m.grid.setFocus(true)
end sub

sub onFocused()
    showSpotlight(m.grid.itemFocused)
end sub

' Shows the remembered "was watching" art for the focused profile. Roku only
' reads what each profile's own Home saved, so focus never waits on the network.
sub showSpotlight(index as integer)
    if m.grid.content = invalid then return
    item = m.grid.content.getChild(index)
    if item = invalid or item.id = "add" then return
    spot = m.spots[item.id]
    if spot <> invalid and ZStr(spot.backdrop) <> "" then
        m.art.uri = spot.backdrop
        m.art.opacity = 1
    else
        m.art.uri = item.SDPosterUrl
        m.art.opacity = 0.35
    end if
    if spot = invalid then
        m.card.visible = false
        return
    end if
    m.card.visible = true
    m.top.findNode("thumb").uri = ZStr(spot.thumb)
    m.top.findNode("was").text = item.title + " was watching"
    m.top.findNode("line").text = ZStr(spot.line)
    progress = ZNum(spot.progress, 0)
    m.top.findNode("track").visible = progress > 0
    m.top.findNode("bar").width = 208 * ZClamp(progress, 0, 1)
end sub

sub onSelected()
    item = m.grid.content.getChild(m.grid.itemSelected)
    if item = invalid then return
    if item.id = "add" then
        m.top.chosen = { action: "add" }
    else
        m.top.chosen = { action: "use", key: item.id }
    end if
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    if press and key = "options" then
        item = m.grid.content.getChild(m.grid.itemFocused)
        if item <> invalid and item.id <> "add" then
            m.top.chosen = { action: "forget", key: item.id }
            return true
        end if
    end if
    return false
end function
