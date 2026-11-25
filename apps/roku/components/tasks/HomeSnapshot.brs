' Optional local library metadata. The path is scoped to this login and reads
' happen on the Home task after the app has authenticated the saved viewer.
function HomeSnapshotPath() as string
    if m.session.remembered <> true then return ""
    scope = ZNotificationScope(m.session)
    if scope = "" then return ""
    return "cachefs:/zorofin-home-v1-" + scope + ".json"
end function

function CacheableRow(id as string) as boolean
    return ZContains(["continue-watching", "latest-movies", "latest-shows", "recent-movies", "recent-shows", "recently-added-movies", "recently-added-shows"], id)
end function

function SnapshotFields() as object
    return ["id", "title", "itemType", "seriesId", "seriesName", "seasonId", "seasonIndex", "episodeIndex", "year", "communityRating", "runtimeTicks", "positionTicks", "progress", "played", "favorite"]
end function

sub WriteHomeSnapshot(path as string, root as object)
    if path = "" or ZNotificationScope(m.session) <> ZNotificationScope(m.global.session) then return
    rows = []
    fields = SnapshotFields()
    for each row in root.getChildren(-1, 0)
        if CacheableRow(row.id) and row.getChildCount() > 0 then
            cards = []
            for each node in row.getChildren(-1, 0)
                if ZContains(["Movie", "Series", "Episode"], node.itemType) then
                    item = {}
                    for each k in fields
                        item[k] = node[k]
                    end for
                    cards.push(item)
                end if
                if cards.count() >= 12 then exit for
            end for
            if cards.count() > 0 then rows.push({ id: row.id, title: row.title, cards: cards })
        end if
    end for
    data = FormatJson({ updated: ZNowSeconds(), rows: rows })
    if Len(data) <= 64000 then WriteAsciiFile(path, data)
end sub

sub ReadHomeSnapshot(path as string)
    if path = "" then return
    raw = ReadAsciiFile(path)
    if raw = "" or Len(raw) > 64000 then return
    data = ParseJson(raw)
    if not ZIsMap(data) or not ZIsArray(data.rows) then return
    age = ZNowSeconds() - ZNum(data.updated, 0)
    if age < 0 or age > 43200 then return
    root = CreateObject("roSGNode", "ContentNode")
    fields = SnapshotFields()
    for each stored in data.rows
        if ZIsMap(stored) and CacheableRow(ZStr(stored.id)) and ZIsArray(stored.cards) then
            row = MakeRow(ZStr(stored.title), stored.id, stored.id = "continue-watching")
            for each item in stored.cards
                if ZIsMap(item) and ZStr(item.id) <> "" and ZContains(["Movie", "Series", "Episode"], item.itemType) then
                    node = CreateObject("roSGNode", "ZItem")
                    for each k in fields
                        if item[k] <> invalid then node[k] = item[k]
                    end for
                    node.HDPosterUrl = ZEndpoint(ServerBase(), ["Items", node.id, "Images", "Primary"], { maxWidth: 320 })
                    node.landscapeUrl = ZEndpoint(ServerBase(), ["Items", node.id, "Images", "Thumb"], { maxWidth: 540 })
                    row.appendChild(node)
                end if
            end for
            if row.getChildCount() > 0 then root.appendChild(row)
        end if
    end for
    if root.getChildCount() > 0 then m.top.cachedHome = root
end sub
