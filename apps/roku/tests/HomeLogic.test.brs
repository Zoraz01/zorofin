' Home rules shared with the Apple and Flutter apps.

sub Test_Home_ContinueWatchingPrefersNextUpOncePerShow()
    resume = [
        { Id: "e2", Name: "Ep 2", Type: "Episode", SeriesId: "s1" },
        { Id: "m1", Name: "Movie", Type: "Movie" }
    ]
    nextUp = [
        { Id: "e5", Name: "Ep 5", Type: "Episode", SeriesId: "s2" },
        { Id: "e3", Name: "Ep 3", Type: "Episode", SeriesId: "s1" }
    ]
    ids = []
    for each item in ZContinueWatching(resume, nextUp)
        ids.push(item.Id)
    end for
    AssertEqual(ids, ["e5", "e2", "m1"], "Next Up order, resume record for the same show, one card per show")
end sub

sub Test_Home_FeedHidesEmptyRowsAndRejectsDuplicates()
    feed = ZParseHomeFeed({ schemaVersion: 1, sections: [
        { id: "a", title: "Popular", cards: [{ item: { Id: "1" }, badges: ["4K", 3] }] },
        { id: "b", title: "Empty", cards: [] }
    ] })
    AssertEqual(feed.count(), 1, "empty row hidden")
    AssertEqual(feed[0].cards[0].badges, ["4K"], "non-string badges dropped")
    AssertTrue(ZParseHomeFeed({ schemaVersion: 1, rows: [{ id: "a", title: "x" }, { id: "a", title: "y" }] }) = invalid, "duplicate ids")
    AssertTrue(ZParseHomeFeed({ schemaVersion: 2, rows: [] }) = invalid, "unknown schema")
end sub

sub Test_Utils_Formatting()
    AssertEqual(ZEpisodeLabel(1, 3), "S1 E3", "episode label")
    AssertEqual(ZRuntimeText(ZSecondsToTicks(5400)), "1h 30m", "runtime")
end sub

sub Test_Utils_DetailText()
    AssertEqual(ZStripTags("A <b>bold</b> move<br/>."), "A bold move.", "tags removed")
    AssertEqual(ZOneDecimalText(7), "7.0", "whole rating")
    AssertEqual(ZOneDecimalText(8.44), "8.4", "rounded rating")
    AssertEqual(ZKindName("TvChannel"), "Channel", "channel label")
    AssertEqual(ZMax(3, 9), 9, "max")
end sub

sub Test_HomeLogic_SearchPicks()
    items = [
        { Id: "m1", Name: "Seen", Type: "Movie", UserData: { Played: true }, ImageTags: { Primary: "t" }, CommunityRating: 9 },
        { Id: "m2", Name: "No art", Type: "Movie", CommunityRating: 9.5 },
        { Id: "m3", Name: "Good", Type: "Movie", ImageTags: { Primary: "t" }, CommunityRating: 8 },
        { Id: "m4", Name: "Better", Type: "Movie", ImageTags: { Primary: "t" }, CommunityRating: 8.5 },
        { Id: "s1", Name: "Show", Type: "Series", ImageTags: { Primary: "t" } },
        { Id: "e1", Name: "Episode", Type: "Episode" },
        { Id: "m4", Name: "Better", Type: "Movie" },
        { Id: "", Name: "Broken", Type: "Movie" }
    ]
    picks = ZSearchPicks(items)
    ids = []
    for each p in picks
        ids.push(p.Id)
    end for
    AssertEqual(ZJoin(ids, ","), "m4,s1,m3,m2,m1", "ranked and alternating")
    AssertEqual(ZSearchPicks(items, 2).count(), 2, "limit")
end sub

sub Test_HomeLogic_Looks()
    AssertEqual(ZLooksUrl("https://media.example.com/"), "https://media.example.com/Zorofin/Web/ui/looks.json", "saved address with slash")
    AssertEqual(ZLooksUrl("http://10.0.0.2:8096"), "http://10.0.0.2:8096/Zorofin/Web/ui/looks.json", "address without slash")
    looks = ZParseLooks({ version: 1, colors: "custom", accent: "#72e79b", cardSize: "large" })
    AssertEqual(looks.accent, "0x72E79B", "accent")
    AssertEqual(looks.cardScale, 1.2, "large")
    looks = ZParseLooks({ version: 1, accent: "red", cardSize: "huge" })
    AssertEqual(looks.accent, "", "bad accent ignored")
    AssertEqual(looks.cardScale, 0.0, "bad size ignored")
    AssertEqual(ZParseLooks({ version: 1, cardSize: "compact" }).cardScale, 0.85, "compact")
    AssertTrue(ZParseLooks({ version: 2, accent: "#ffffff" }) = invalid, "unknown version")
    AssertEqual(ZParseLooks({ version: 1, colors: "zorofin", accent: "#42d779", cardSize: "standard" }).accent, "", "server's Zorofin green keeps the app's green")
    AssertEqual(ZParseLooks({ version: 1, colors: "custom", accent: "#42D779" }).accent, "", "the web green is the app's green")
    AssertEqual(ZParseLooks({ version: 1, colors: "ocean", accent: "#3b82f6", cardSize: "large", enforced: false }).cardScale, 0.0, "not enforced: viewer's size")
    AssertEqual(ZParseLooks({ version: 1, colors: "ocean", accent: "#3b82f6", cardSize: "large", enforced: true }).cardScale, 1.2, "enforced size")
    AssertTrue(ZParseLooks(invalid) = invalid, "no body")
    dark = ZParseLooks({ version: 1, accent: "#102030" }).accent
    n = Val(Mid(dark, 3), 16)
    luma = (Int(n / 65536) * 299 + (Int(n / 256) mod 256) * 587 + (n mod 256) * 114) / 1000
    AssertTrue(luma >= 110, "dark accent lifted: " + dark)
end sub

sub Test_Looks_UnlockedDefaultAndPersonalChoice()
    looks = ZParseLooks({ version: 1, cardSize: "large", enforced: false })
    AssertEqual(looks.defaultCardScale, 1.2, "unlocked server size retained")
    AssertEqual(ZEffectivePosterScale(looks.cardScale, looks.defaultCardScale, 1.0, false), 1.2, "new viewer starts with server size")
    AssertEqual(ZEffectivePosterScale(0, 1.2, 1.0, true), 1.0, "explicit standard choice beats unlocked large")
    AssertEqual(ZEffectivePosterScale(0.85, 1.2, 1.0, true), 0.85, "enforcement wins without overwriting personal choice")
    AssertEqual(ZEffectivePosterScale(0, 0, 1.2, true), 1.2, "removing looks restores personal choice")
    AssertEqual(ZEffectivePosterScale(0, 0, 0.85, false), 1.0, "another account does not inherit personal size")
end sub

sub Test_HomeDisplayRows()
    movies = { id: "movies" }
    live = { id: "live-now" }
    resume = { id: "continue-watching" }
    rows = [resume, movies]
    AssertEqual(ZHomeDisplayRows(rows, live), [resume, live, movies], "resume precedes live")
    AssertEqual(rows, [resume, movies], "late live refresh preserves cached row order")
    AssertEqual(ZHomeDisplayRows([movies], live), [live, movies], "live leads when no resume shelf")
    AssertEqual(ZHomeDisplayRows(rows, invalid), rows, "server order without live")
end sub

sub Test_SceneAvatarMatchesOtherApps()
    AssertEqual(ZSceneAvatarName("a"), "lastlight", "97 mod 7 = 6")
    AssertEqual(ZSceneAvatarName("ABC"), ZSceneAvatarName("abc"), "case-insensitive")
end sub

sub Test_ProfileSpotlightPrefersBackdropAndFormatsEpisodes()
    cards = [
        { itemType: "Movie", title: "Bare", backdropUrl: "" },
        { itemType: "Episode", title: "The Long Dark", seriesName: "Northbound", seasonIndex: 2, episodeIndex: 4, progress: 0.3, backdropUrl: "b", landscapeUrl: "t" }
    ]
    s = ZProfileSpotlight(cards)
    AssertEqual(s.line, "Northbound · S2 E4 · The Long Dark", "episode line")
    AssertEqual(s.backdrop, "b", "backdrop")
    AssertEqual(s.thumb, "t", "thumb")
    AssertTrue(ZProfileSpotlight([]) = invalid, "empty is invalid")
    AssertEqual(ZProfileSpotlight([{ itemType: "Movie", title: "Bare" }]).line, "Bare", "no art still names it")
end sub

sub Test_Home_GameNeedsTwoNamesAndTwoCrests()
    a = "Zorofin/Web/ui/live-tv-logos/art/sports-0123456789abcdef01234567-89abcdef.png"
    b = "Zorofin/Web/ui/live-tv-logos/art/sports-fedcba9876543210fedcba98-01234567.jpg"
    g = ZHomeGame({ matchup: ["Wizards", "Celtics"], crests: [a, b], badges: ["Starting soon"] })
    AssertEqual(g.title, "Wizards vs Celtics", "title keeps the server order")
    AssertEqual(g.crests, [a, b], "both crests kept in order")
    AssertEqual(g.status, "Starting soon", "badge decides without a start time")
    AssertEqual(ZHomeGame({ matchup: ["A", "B"], crests: [a, b], startsAt: "2020-01-01T00:00:00Z" }).status, "On now", "started game")
    AssertEqual(ZHomeGame({ matchup: ["A", "B"], crests: [a, b], startsAt: "2999-01-01T00:00:00Z" }).status, "Starting soon", "future game")
    AssertTrue(ZHomeGame({ matchup: ["A", "B"], crests: [a] }) = invalid, "one crest")
    AssertTrue(ZHomeGame({ matchup: ["A"], crests: [a, b] }) = invalid, "one team")
    AssertTrue(ZHomeGame({ matchup: ["A", " "], crests: [a, b] }) = invalid, "blank team")
    AssertTrue(ZHomeGame({ matchup: ["A", String(81, "x")], crests: [a, b] }) = invalid, "long team")
    AssertTrue(ZHomeGame({ matchup: ["A", 4], crests: [a, b] }) = invalid, "team is not text")
    AssertTrue(ZHomeGame({ matchup: ["A", "B"], crests: [a, "https://example.com/x.png"] }) = invalid, "other host")
    AssertTrue(ZHomeGame({ matchup: ["A", "B"], crests: [a, "../" + b] }) = invalid, "path escape")
    AssertTrue(ZHomeGame({ matchup: ["A", "B"], crests: [a, b + "?x=1"] }) = invalid, "query")
    AssertTrue(ZHomeGame({ matchup: ["A", "B"], crests: [a, b + Chr(10)] }) = invalid, "trailing newline")
    AssertTrue(ZHomeGame({ matchup: ["A", "B"], crests: [a, "Zorofin/Web/ui/live-tv-logos/art/sports-0123456789ABCDEF01234567-89abcdef.png"] }) = invalid, "uppercase id")
    AssertTrue(ZHomeGame({ item: { Id: "1" } }) = invalid, "old server")
    feed = ZParseHomeFeed({ schemaVersion: 1, sections: [{ id: "sports", title: "Your teams", cards: [
        { item: { Id: "1" }, matchup: ["A", "B"], crests: [a, b] },
        { item: { Id: "2" }, matchup: ["A", "B"], crests: [a, "bad"] }
    ] }] })
    AssertEqual(feed[0].cards[0].game.title, "A vs B", "feed carries the game")
    AssertTrue(feed[0].cards[1].game = invalid, "bad pair stays a channel card")
end sub
