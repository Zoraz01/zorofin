sub init()
    m.grid = m.top.findNode("grid")
    m.top.findNode("title").font = ZFont(56, "bold")
    m.top.findNode("hint").font = ZFont(24)
    m.grid.observeField("itemSelected", "onSelected")
    m.top.findNode("hint").text = "Press * on an account to remove it from this Roku."
end sub

sub build()
    content = CreateObject("roSGNode", "ContentNode")
    for each a in m.top.accounts
        node = content.createChild("ContentNode")
        node.id = a.key
        node.title = ZStr(a.userName)
        node.description = ZStr(a.serverName)
        node.HDPosterUrl = ZUserImageUrl(a.server, a.userId, a.imageTag, 240)
    end for
    add = content.createChild("ContentNode")
    add.id = "add"
    add.title = "Add account"
    add.description = "Another server or user"
    m.grid.content = content
    count = content.getChildCount()
    if count > 5 then count = 5
    width = count * 260 + (count - 1) * 60
    m.grid.translation = [(1920 - width) / 2, 420]
end sub

sub restoreFocus()
    m.grid.setFocus(true)
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
