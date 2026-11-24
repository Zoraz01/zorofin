' Home rules shared with the Apple and Flutter apps (HomeBanner,
' ContinueWatchingFeed). Works on raw Jellyfin JSON so it is unit-testable.

' Server-ranked Next Up first, using a matching resume record at that rank;
' remaining resume titles follow. One card per show, at most limit cards.
function ZContinueWatching(resume as object, nextUp as object, limit = 20 as integer) as object
    resumable = []
    byId = {}
    bySeries = {}
    for each item in resume
        kind = ZStr(item.Type)
        if ZStr(item.Id) <> "" and ZStr(item.Name) <> "" and (kind = "Movie" or kind = "Episode") then
            resumable.push(item)
            if kind = "Episode" then
                if not byId.DoesExist(item.Id) then byId[item.Id] = item
                show = ZStr(item.SeriesId).trim()
                if show <> "" and not bySeries.DoesExist(show) then bySeries[show] = item
            end if
        end if
    end for
    candidates = []
    for each item in nextUp
        played = ZBool(ZGet(item, "UserData", "Played"))
        if ZStr(item.Id) <> "" and ZStr(item.Name) <> "" and ZStr(item.Type) = "Episode" and not played then
            show = ZStr(item.SeriesId).trim()
            if byId.DoesExist(item.Id) then
                candidates.push(byId[item.Id])
            else if show <> "" and bySeries.DoesExist(show) then
                candidates.push(bySeries[show])
            else
                candidates.push(item)
            end if
        end if
    end for
    for each item in resumable
        candidates.push(item)
    end for
    seenIds = {}
    seenShows = {}
    selected = []
    cap = ZClamp(limit, 0, 40)
    for each item in candidates
        if selected.count() >= cap then exit for
        id = ZStr(item.Id)
        if not seenIds.DoesExist(id) then
            show = ""
            if ZStr(item.Type) = "Episode" then show = ZStr(item.SeriesId).trim()
            if show = "" or not seenShows.DoesExist(show) then
                seenIds[id] = true
                if show <> "" then seenShows[show] = true
                selected.push(item)
            end if
        end if
    end for
    return selected
end function

' Picks the Home banner: highly rated (7+) titles with a backdrop first,
' then any with a poster; a random pick from the top eight finalists.
function ZPickBanner(candidates as object, seed = -1 as integer) as dynamic
    eligible = []
    for each item in candidates
        kind = ZStr(item.Type)
        if (kind = "Movie" or kind = "Series") and ZStr(item.Id).trim() <> "" and ZStr(item.Name).trim() <> "" then eligible.push(item)
    end for
    rated = []
    for each item in eligible
        if ZNum(item.CommunityRating, 0) >= 7 then rated.push(item)
    end for
    pool = rated
    if pool.count() = 0 then pool = eligible
    best = 0
    for each item in pool
        r = ZArtworkRank(item)
        if r > best then best = r
    end for
    finalists = []
    for each item in pool
        if ZArtworkRank(item) = best and finalists.count() < 8 then finalists.push(item)
    end for
    if finalists.count() = 0 then return invalid
    if seed >= 0 then return finalists[seed mod finalists.count()]
    return finalists[Rnd(finalists.count()) - 1]
end function

function ZArtworkRank(item as object) as integer
    tags = item.BackdropImageTags
    if ZIsArray(tags) and tags.count() > 0 and ZStr(tags[0]) <> "" then return 2
    if ZStr(ZGet(item, "ImageTags", "Primary")) <> "" then return 1
    return 0
end function

' Validates a plugin Home feed (Zorofin/Home/Sections or Rows) and returns
' [{ id, title, cards: [{ item, subtitle, badges }] }]; invalid on bad shape.
function ZParseHomeFeed(json as dynamic) as dynamic
    if not ZIsMap(json) or ZNum(json.schemaVersion, 0) <> 1 then return invalid
    list = json.sections
    if list = invalid then list = json.rows
    if not ZIsArray(list) then return invalid
    out = []
    seen = {}
    for each entry in list
        if not ZIsMap(entry) then return invalid
        id = ZStr(entry.id)
        title = ZStr(entry.title)
        if id = "" or title = "" or seen.DoesExist(id) then return invalid
        seen[id] = true
        state = ZStr(entry.state, "ready")
        cards = []
        if ZIsArray(entry.cards) and state = "ready" then
            for each c in entry.cards
                if ZIsMap(c) and ZIsMap(c.item) and ZStr(c.item.Id) <> "" then
                    badges = []
                    if ZIsArray(c.badges) then
                        for each b in c.badges
                            if type(b) = "roString" or type(b) = "String" then badges.push(b)
                        end for
                    end if
                    cards.push({ item: c.item, subtitle: ZStr(c.subtitle), badges: badges })
                end if
                if cards.count() >= 40 then exit for
            end for
        end if
        ' Empty rows are hidden (UI rule shared with the web and Apple apps).
        if cards.count() > 0 then out.push({ id: id, title: title, cards: cards })
    end for
    return out
end function

' Splits server card badges into quality badges and context badges.
function ZSplitBadges(badges as object) as object
    formats = { "4K": 1, "8K": 1, "1080p": 1, "720p": 1, "HDR": 1, "HDR10": 1, "HDR10+": 1, "Dolby Vision": 1, "HLG": 1 }
    quality = []
    context = []
    for each b in badges
        if formats.DoesExist(b) then
            if b = "Dolby Vision" then quality.push("DV") else quality.push(b)
        else
            context.push(b)
        end if
    end for
    return { quality: quality, context: context }
end function

' Search's "Recommended" picks (Apple SearchRecommendations.select): unwatched
' first, then titles with artwork, then higher rated, keeping server order on
' ties; movies and shows alternate, at most `limit` (24).
function ZSearchPicks(items as object, limit = 24 as integer) as object
    ranked = []
    seen = {}
    i = 0
    for each it in items
        id = ZStr(it.Id)
        kind = ZStr(it.Type)
        if id <> "" and ZStr(it.Name) <> "" and (kind = "Movie" or kind = "Series") and not seen.doesExist(id) then
            seen[id] = true
            played = ZBool(ZGet(it, "UserData", "Played"))
            art = ZStr(ZGet(it, "ImageTags", "Primary")) <> ""
            rating = ZNum(it.CommunityRating, 0)
            if rating < 0 or rating > 10 then rating = 0
            ranked.push({ item: it, played: played, art: art, rating: rating, order: i, kind: kind })
        end if
        i = i + 1
    end for
    for a = 1 to ranked.count() - 1
        x = ranked[a]
        b = a - 1
        while b >= 0 and ZSearchBefore(x, ranked[b])
            ranked[b + 1] = ranked[b]
            b = b - 1
        end while
        ranked[b + 1] = x
    end for
    movies = []
    shows = []
    for each r in ranked
        if r.kind = "Movie" then movies.push(r.item) else shows.push(r.item)
    end for
    cap = ZClamp(limit, 0, 24)
    out = []
    n = ZMax(movies.count(), shows.count())
    for k = 0 to n - 1
        if k < movies.count() and out.count() < cap then out.push(movies[k])
        if k < shows.count() and out.count() < cap then out.push(shows[k])
        if out.count() >= cap then exit for
    end for
    return out
end function

function ZSearchBefore(a as object, b as object) as boolean
    if a.played <> b.played then return not a.played
    if a.art <> b.art then return a.art
    if a.rating <> b.rating then return a.rating > b.rating
    return a.order < b.order
end function
