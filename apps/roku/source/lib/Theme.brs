' Design tokens shared with apps/apple/App/Theme.swift and apps/tv/lib/ui/theme.dart.
function ZTheme() as object
    return {
        background: "0x111513FF",
        panel: "0x1B211EFF",
        panelHigh: "0x262E2AFF",
        border: "0x39423CFF",
        text: "0xF5F7F5FF",
        muted: "0xBBC5BDFF",
        jade: "0x72E79BFF",
        play: "0x1CB956FF",
        avatar: "0x24543EFF",
        gold: "0xFFD60AFF",
        white: "0xFFFFFFFF",
        black: "0x000000FF",
        scrim: "0x000000D9",
        gutter: 96,
        regular: "pkg:/fonts/Inter-Regular.ttf",
        semibold: "pkg:/fonts/Inter-SemiBold.ttf",
        bold: "pkg:/fonts/Inter-Bold.ttf"
    }
end function

' Font node in Inter, snapped to the type scale (ZTypeStyle in Utils.brs).
' Weight is "regular", "semibold" or "bold".
function ZFont(size as integer, weight = "regular" as string) as object
    style = ZTypeStyle(size, weight)
    f = CreateObject("roSGNode", "Font")
    f.uri = "pkg:/fonts/Inter-Regular.ttf"
    if style.weight = "semibold" then f.uri = "pkg:/fonts/Inter-SemiBold.ttf"
    if style.weight = "bold" then f.uri = "pkg:/fonts/Inter-Bold.ttf"
    f.size = style.size
    return f
end function

' A Poster at [x, y] with the given size.
function ZPoster(uri as string, width as integer, height as integer, x = 0 as integer, y = 0 as integer) as object
    p = CreateObject("roSGNode", "Poster")
    p.uri = uri
    p.width = width
    p.height = height
    p.translation = [x, y]
    return p
end function

' Rendered width of text in a font, from a throwaway Label.
function ZTextWidth(text as string, font as object) as integer
    l = CreateObject("roSGNode", "Label")
    l.font = font
    l.text = text
    return Int(l.localBoundingRect().width + 0.5)
end function

' Apple TV SectionTitle: a 4 x 30 jade bar and a 30 pt bold title.
function ZSectionTitle(text as string, x = 96 as integer, y = 0 as integer) as object
    g = CreateObject("roSGNode", "Group")
    g.translation = [x, y]
    bar = CreateObject("roSGNode", "Rectangle")
    bar.width = 4
    bar.height = 30
    bar.translation = [0, 3]
    bar.color = ZTheme().jade
    label = CreateObject("roSGNode", "Label")
    label.font = ZFont(30, "bold")
    label.color = ZTheme().text
    label.text = text
    label.translation = [14, 0]
    label.height = 36
    label.vertAlign = "center"
    g.appendChild(bar)
    g.appendChild(label)
    return g
end function
