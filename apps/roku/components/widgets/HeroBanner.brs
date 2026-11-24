sub init()
    m.top.focusable = true
    m.title = m.top.findNode("title")
    m.meta = m.top.findNode("meta")
    m.overview = m.top.findNode("overview")
    m.actions = m.top.findNode("actions")
    m.title.font = ZFont(48, "bold")
    m.overview.font = ZFont(20)
    m.actions.observeField("selected", "onAction")
    m.top.observeField("focusedChild", "onFocusChange")
end sub

sub onItem()
    item = m.top.item
    if item = invalid then return
    art = item.backdropUrl
    if art = "" then art = item.landscapeUrl
    m.top.findNode("art").uri = art
    m.title.text = item.title
    ZMetadataLine(m.meta, item, 22)
    m.overview.text = item.description
    m.top.favorite = item.favorite
    label = "Play"
    if item.positionTicks > 0 then label = "Resume"
    m.actions.buttons = [
        { id: "play", text: label, icon: "play-filled", style: "white" },
        { id: "info", icon: "info", style: "glass" },
        { id: "favorite", icon: FavoriteIcon(), style: "glass", tint: FavoriteTint() }
    ]
    layout()
end sub

function FavoriteIcon() as string
    if m.top.favorite then return "heart-filled"
    return "heart"
end function

function FavoriteTint() as string
    if m.top.favorite then return ZTheme().jade
    return ""
end function

sub paintFavorite()
    m.actions.callFunc("setLabel", { id: "favorite", icon: FavoriteIcon(), tint: FavoriteTint() })
end sub

' Stacks the text from the bottom up with Apple's 14 px spacing and 40 px padding.
sub layout()
    y = 480 - 40 - 60
    m.actions.translation = [0, y]
    if m.overview.text <> "" then
        lines = 1
        if ZTextWidth(m.overview.text, m.overview.font) > 620 then lines = 2
        y = y - 14 - lines * 26
        m.overview.translation = [0, y]
        m.overview.visible = true
    else
        m.overview.visible = false
    end if
    y = y - 14 - 30
    m.meta.translation = [0, y]
    titleLines = 1
    if ZTextWidth(m.title.text, m.title.font) > 1300 then titleLines = 2
    y = y - 14 - titleLines * 58
    m.title.translation = [0, y]
end sub

sub onAction(event as object)
    m.top.action = event.getData()
end sub

sub onFocusChange()
    if m.top.hasFocus() then m.actions.setFocus(true)
end sub
