' Shared RowList setup for Home, Details and Search (Apple TV row metrics).
' Item sizes include MediaCard's 12 px focus inset on the top and left.

function ZPosterSize() as object
    return [224, 421]
end function

function ZLandscapeSize() as object
    return [372, 306]
end function

' Configures a RowList for the given content. Each row's "landscape" field
' picks 16:9 cards (Continue Watching, episodes, channels) or 2:3 posters.
sub ZSetupRows(list as object, content as object, labelSize = 30 as integer, width = 1920 as integer, offset = 96 as integer)
    sizes = []
    heights = []
    spacing = []
    for i = 0 to content.getChildCount() - 1
        row = content.getChild(i)
        landscape = row.hasField("landscape") and row.landscape = true
        if landscape then
            sizes.push(ZLandscapeSize())
            heights.push(ZLandscapeSize()[1] + 64)
        else
            sizes.push(ZPosterSize())
            heights.push(ZPosterSize()[1] + 64)
        end if
        spacing.push([16, 0])
    end for
    list.itemComponentName = "MediaCard"
    list.drawFocusFeedback = false
    list.rowFocusAnimationStyle = "floatingFocus"
    list.vertFocusAnimationStyle = "fixedFocus"
    list.focusXOffset = [offset - 12]
    list.rowLabelOffset = [[offset, 2]]
    list.showRowLabel = [true]
    list.rowLabelColor = "0xF5F7F5FF"
    list.rowLabelFont = ZFont(labelSize, "bold")
    list.itemSize = [width, 460]
    list.rowItemSize = sizes
    list.rowHeights = heights
    list.rowItemSpacing = spacing
    list.itemSpacing = [0, 18]
    list.numRows = 4
    list.content = content
end sub

' Meta line under a title: year · rating · runtime · official rating.
function ZMetaLine(item as object) as string
    parts = []
    if item.itemType = "Episode" then
        label = ZEpisodeLabel(item.seasonIndex, item.episodeIndex)
        if label <> "" then parts.push(label)
    end if
    if item.year > 0 then parts.push(item.year.toStr())
    if item.communityRating > 0 then parts.push("★ " + ZRating(item.communityRating))
    runtime = ZRuntimeText(item.runtimeTicks)
    if runtime <> "" and item.itemType <> "Series" then parts.push(runtime)
    if item.officialRating <> "" then parts.push(item.officialRating)
    if item.itemType = "TvChannel" and item.programName <> "" then
        parts.push(item.programName)
        if item.programEnd > 0 then parts.push("until " + ZLocalTime(item.programEnd))
    end if
    return ZJoin(parts, "  ·  ")
end function

function ZRating(value as float) as string
    tenths = Int(value * 10 + 0.5)
    whole = Int(tenths / 10)
    return whole.toStr() + "." + (tenths - whole * 10).toStr()
end function

' Where a card goes when selected.
function ZCardAction(item as object) as object
    kind = item.itemType
    if kind = "TvChannel" then return { to: "player", id: item.id, live: true }
    if kind = "Episode" then return { to: "detail", id: item.id }
    if kind = "CollectionFolder" or kind = "UserView" or kind = "Folder" or kind = "BoxSet" or kind = "Playlist" then
        return { to: "library", config: { title: item.title, parentId: item.id, sortBy: "SortName", sortOrder: "Ascending" } }
    end if
    return { to: "detail", id: item.id }
end function

' Bottom scrim from y to the bottom of the screen, so no hard edge shows.
sub ZPlaceScrim(scrim as object, y as integer)
    scrim.translation = [0, y]
    scrim.height = 1080 - y
end sub

' Apple MetadataLine: year, duration and the official rating in a small
' chip, 12 px apart, medium weight in the muted colour. Fills group.
sub ZMetadataLine(group as object, item as object, size = 22 as integer)
    group.removeChildrenIndex(group.getChildCount(), 0)
    parts = []
    if item.year > 0 then parts.push(item.year.toStr())
    if item.itemType <> "Series" and item.itemType <> "TvChannel" then
        runtime = ZRuntimeText(item.runtimeTicks)
        if runtime <> "" then parts.push(runtime)
    end if
    font = ZFont(size, "semibold")
    x = 0
    h = size + 10
    for each text in parts
        label = CreateObject("roSGNode", "Label")
        label.font = font
        label.color = ZTheme().muted
        label.text = text
        label.height = h
        label.vertAlign = "center"
        label.translation = [x, 0]
        group.appendChild(label)
        x = x + ZTextWidth(text, font) + 12
    end for
    if item.officialRating <> "" then
        w = ZTextWidth(item.officialRating, font) + 12
        chip = ZPoster("pkg:/images/badge.9.png", w, h - 4, x, 2)
        chip.blendColor = "0xFFFFFF1F"
        label = CreateObject("roSGNode", "Label")
        label.font = font
        label.color = ZTheme().muted
        label.text = item.officialRating
        label.width = w
        label.height = h
        label.horizAlign = "center"
        label.vertAlign = "center"
        label.translation = [x, 0]
        group.appendChild(chip)
        group.appendChild(label)
    end if
end sub
