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
