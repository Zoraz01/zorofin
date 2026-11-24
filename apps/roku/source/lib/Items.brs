' Converts Jellyfin item JSON into ZItem content nodes and derives the
' card captions and quality badges the Apple and Flutter apps show.

' Fields asked for on every list read so cards can show badges and progress.
function ZItemFields() as string
    return "Overview,Genres,MediaStreams,PrimaryImageAspectRatio,ProductionYear"
end function

function ZVideoStream(json as object) as dynamic
    streams = json.MediaStreams
    if not ZIsArray(streams) then
        sources = json.MediaSources
        if ZIsArray(sources) and sources.count() > 0 then streams = sources[0].MediaStreams
    end if
    if not ZIsArray(streams) then return invalid
    for each s in streams
        if ZIsMap(s) and s.Type = "Video" and s.IsAttachedPicture <> true then return s
    end for
    return invalid
end function

' Card badges: resolution plus HDR format (DV for Dolby Vision).
function ZThumbnailBadges(json as object) as object
    badges = []
    video = ZVideoStream(json)
    if video = invalid then return badges
    res = ZResolution(video.Width, video.Height, ZBool(video.IsInterlaced))
    if res <> "" then badges.push(res)
    range = ZDynamicRange(video)
    if range = "Dolby Vision" then range = "DV"
    if range <> "" and range <> "SDR" then badges.push(range)
    return badges
end function

' Builds a ZItem from Jellyfin JSON. base is the server base URL.
function ZItemNode(json as object, base as string) as object
    node = CreateObject("roSGNode", "ZItem")
    ZFillItem(node, json, base)
    return node
end function

sub ZFillItem(node as object, json as object, base as string)
    id = ZStr(json.Id)
    kind = ZStr(json.Type)
    node.id = id
    node.itemType = kind
    node.mediaType = ZStr(json.MediaType)
    node.collectionType = ZStr(json.CollectionType)
    node.title = ZStr(json.Name)
    node.description = ZStr(json.Overview)
    node.seriesId = ZStr(json.SeriesId)
    node.seriesName = ZStr(json.SeriesName)
    node.seasonId = ZStr(json.SeasonId)
    node.seasonIndex = Int(ZNum(json.ParentIndexNumber, -1))
    node.episodeIndex = Int(ZNum(json.IndexNumber, -1))
    node.year = Int(ZNum(json.ProductionYear, 0))
    node.communityRating = ZNum(json.CommunityRating, 0)
    node.officialRating = ZStr(json.OfficialRating)
    node.runtimeTicks = ZNum(json.RunTimeTicks, 0)
    node.isFolder = ZBool(json.IsFolder)
    if ZIsArray(json.Genres) then node.genres = json.Genres

    data = json.UserData
    if ZIsMap(data) then
        node.positionTicks = ZNum(data.PlaybackPositionTicks, 0)
        node.played = ZBool(data.Played)
        node.favorite = ZBool(data.IsFavorite)
        node.unplayedCount = Int(ZNum(data.UnplayedItemCount, 0))
        pct = ZNum(data.PlayedPercentage, 0)
        if pct <= 0 and node.runtimeTicks > 0 and node.positionTicks > 0 then pct = 100 * node.positionTicks / node.runtimeTicks
        node.progress = ZClamp(pct / 100, 0, 1)
    end if

    tags = json.ImageTags
    if not ZIsMap(tags) then tags = {}
    primary = ZImageUrl(base, id, "Primary", tags.Primary, 320)
    thumb = ZImageUrl(base, id, "Thumb", tags.Thumb, 540)
    backdrop = ""
    if ZIsArray(json.BackdropImageTags) and json.BackdropImageTags.count() > 0 then
        backdrop = ZImageUrl(base, id, "Backdrop", json.BackdropImageTags[0], 1280)
    end if
    ' Episodes and seasons borrow the show's artwork when they have none.
    if backdrop = "" and ZIsArray(json.ParentBackdropImageTags) and json.ParentBackdropImageTags.count() > 0 then
        backdrop = ZImageUrl(base, json.ParentBackdropItemId, "Backdrop", json.ParentBackdropImageTags[0], 1280)
    end if
    if thumb = "" and json.ParentThumbItemId <> invalid then
        thumb = ZImageUrl(base, json.ParentThumbItemId, "Thumb", json.ParentThumbImageTag, 540)
    end if
    if primary = "" and kind = "Episode" and json.SeriesPrimaryImageTag <> invalid then
        primary = ZImageUrl(base, json.SeriesId, "Primary", json.SeriesPrimaryImageTag, 320)
    end if
    if tags.Logo <> invalid then
        node.logoUrl = ZImageUrl(base, id, "Logo", tags.Logo, 800)
    else if json.ParentLogoItemId <> invalid then
        node.logoUrl = ZImageUrl(base, json.ParentLogoItemId, "Logo", json.ParentLogoImageTag, 800)
    end if

    node.HDPosterUrl = primary
    node.FHDPosterUrl = primary
    node.backdropUrl = backdrop
    node.thumbUrl = thumb

    ' 16:9 card art: an episode's own still, else thumb, else backdrop.
    landscape = ""
    if kind = "Episode" then
        landscape = ZImageUrl(base, id, "Primary", tags.Primary, 540)
    end if
    if landscape = "" then landscape = thumb
    if landscape = "" then landscape = ZImageUrl(base, id, "Backdrop", ZFirst(json.BackdropImageTags), 540)
    if landscape = "" then landscape = backdrop
    node.landscapeUrl = landscape

    node.badges = ZThumbnailBadges(json)
    node.caption = ZCaption(json)

    if kind = "TvChannel" then
        node.channelNumber = ZStr(json.ChannelNumber)
        program = json.CurrentProgram
        if ZIsMap(program) then
            node.programName = ZStr(program.Name)
            node.programStart = ZIsoToSeconds(program.StartDate)
            node.programEnd = ZIsoToSeconds(program.EndDate)
        end if
    end if
end sub

function ZFirst(list as dynamic) as dynamic
    if ZIsArray(list) and list.count() > 0 then return list[0]
    return invalid
end function

' Second line under a card title (Apple MediaCard caption).
function ZCaption(json as object) as string
    kind = ZStr(json.Type)
    if kind = "Episode" then
        ' Apple MediaItem.episodeLabel: "S1 E2 · Name".
        return ZJoin([ZEpisodeLabel(json.ParentIndexNumber, json.IndexNumber), ZStr(json.Name)], " · ")
    end if
    if kind = "TvChannel" then
        program = json.CurrentProgram
        if ZIsMap(program) then return ZStr(program.Name)
        return "Live TV"
    end if
    if kind = "Series" then
        year = ZNum(json.ProductionYear, 0)
        if year > 0 then return Int(year).toStr()
        return "Series"
    end if
    year = ZNum(json.ProductionYear, 0)
    if year > 0 then return Int(year).toStr()
    return ""
end function

' Card title: episodes show their series name, like the Apple app.
function ZCardTitle(item as object) as string
    if item.itemType = "Episode" and item.seriesName <> "" then return item.seriesName
    return item.title
end function

' Detail-page badges (Apple MediaQuality.badges subset).
