' Calendar and Catch Up helpers (mirrors support-agent extras page tests).

sub Test_Extras_Manifest()
    AssertEqual(ZParseExtras({ calendar: true, catchUp: false }), { calendar: true, catchUp: false }, "manifest")
    AssertEqual(ZParseExtras(invalid), { calendar: false, catchUp: false }, "missing route")
    AssertEqual(ZParseExtras({ calendar: "yes" }).calendar, false, "only true counts")
end sub

sub Test_Extras_Calendar()
    ' 2026-11-09 16:00 UTC, viewer five hours behind (11:00 local).
    now = 1794240000
    offset = -5 * 3600
    items = [
        { kind: "movie", title: "Later Movie", at: "2026-11-11", allDay: true, release: "digital" },
        { kind: "episode", title: "Late Show", subtitle: "S2:E4 · Night", at: "2026-11-10T03:00:00Z", allDay: false, release: "airing" },
        { kind: "episode", title: "Pilot", subtitle: "S1:E1 · Pilot", at: "2026-11-10T18:30:00Z", allDay: false, premiere: true },
        { kind: "episode", title: "Yesterday", subtitle: "S1:E2", at: "2026-11-08T18:30:00Z", allDay: false },
        { kind: "episode", title: "", at: "2026-11-10T18:30:00Z" }
    ]
    groups = ZCalendarGroups(items, now, offset)
    AssertEqual(groups.count(), 3, "three local days from today")
    AssertEqual(groups[0].day, "2026-11-09", "a 03:00 UTC show is the evening before locally")
    AssertEqual(groups[0].label, "Today · Monday, November 9", "today label")
    AssertEqual(groups[0].events[0].title, "Late Show", "late show today")
    AssertEqual(groups[1].label, "Tomorrow · Tuesday, November 10", "tomorrow label")
    AssertEqual(groups[2].label, "Wednesday, November 11", "later label")
    AssertEqual(ZCalendarGroups(items, now, offset, "movies").count(), 1, "movies filter")
    AssertEqual(ZCalendarGroups(items, now, offset, "shows").count(), 2, "shows filter")
    AssertEqual(ZCalendarCaption(items[1], offset), "10:00 PM · S2:E4 · Night", "caption with time")
    AssertEqual(ZCalendarCaption(items[0], offset), "", "movie without subtitle")
    AssertEqual(ZCalendarBadge(items[2]), "Series premiere", "series premiere")
    AssertEqual(ZCalendarBadge({ premiere: true, subtitle: "S3:E1" }), "Season premiere", "season premiere")
    AssertEqual(ZCalendarBadge(items[0]), "Digital release", "release kind")
    AssertEqual(ZCalendarBadge({ release: "odd" }), "", "unknown kind")
end sub

sub Test_Extras_CatchUp()
    items = [{ Id: "a" }, { Id: "b", UserData: { Likes: true } }, { Id: "c" }, { Name: "no id" }]
    AssertEqual(ZCatchUpQueue(items, ["c"], { b: true }).count(), 1, "skipped and liked dropped")
    AssertEqual(ZCatchUpQueue(items, [], { b: true })[1].Id, "c", "order kept")
    skips = ZCatchUpSkip(["a", "b"], "a")
    AssertEqual(skips, ["b", "a"], "re-skip moves to the end")
    AssertEqual(ZCatchUpSkip(["a", "b", "c"], "d", 3), ["b", "c", "d"], "oldest dropped")
    AssertEqual(ZCatchUpKeyAction("left"), "skip", "left skips")
    AssertEqual(ZCatchUpKeyAction("right"), "like", "right likes")
    AssertEqual(ZCatchUpKeyAction("up"), "", "up leaves the card")
    AssertEqual(ZCatchUpKeyAction("down"), "", "down leaves the card")
    AssertEqual(ZCatchUpKeyAction("OK"), "detail", "OK opens details")
end sub

sub Test_Calendar_FourWeeksIncludesEmptyDaysAndBounds()
    now = 1794240000
    items = [
        { kind: "movie", title: "Last day", at: "2026-12-06", allDay: true },
        { kind: "movie", title: "Outside", at: "2026-12-07", allDay: true }
    ]
    groups = ZCalendarGroups(items, now, -18000, "all", 28)
    AssertEqual(groups.count(), 28, "four weeks, including empty days")
    AssertEqual(groups[0].events.count(), 0, "empty today retained")
    AssertEqual(groups[27].day, "2026-12-06", "inclusive final day")
    AssertEqual(groups[27].events.count(), 1, "out-of-window title excluded")
    AssertEqual(ZCalendarGroups(invalid, now, 0, "all", 28).count(), 28, "empty response still exposes dates")
    AssertEqual(ZCalendarGroups(items, now, 0, "shows", 28)[27].events.count(), 0, "filter keeps empty dates")
    AssertEqual(ZCalendarGroups([], now, 0, "all", 90).count(), 28, "bounded response")
end sub

sub Test_RequestSeasonsRespectSpecialsReceiptsAndAvailability()
    title = { seasons: [{seasonNumber:0, episodeCount:1}, {seasonNumber:1, episodeCount:8}, {seasonNumber:2, episodeCount:10}, {seasonNumber:3, episodeCount:2}, {seasonNumber:4, episodeCount:0}] }
    title.mediaInfo = { requests:[{status:1, seasons:[{seasonNumber:1}]}], seasons:[{seasonNumber:2, status:5}] }
    AssertEqual(FormatJson(ZRequestAvailableSeasons(title, false)), "[3]", "pending, available, empty and specials excluded")
    AssertEqual(FormatJson(ZRequestAvailableSeasons(title, true)), "[0,3]", "server permits specials")
    title.mediaInfo.status = 5
    AssertEqual(ZRequestAvailableSeasons(title, true).count(), 0, "fully available series cannot be requested again")
end sub
