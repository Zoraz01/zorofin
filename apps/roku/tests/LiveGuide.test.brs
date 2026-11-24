' Live TV guide logic (mirrors apps/apple Core LiveGuideTests).

function GuideProgram(id as string, channelId as string, start as integer, finish as integer) as object
    return { id: id, name: id, channelId: channelId, start: start, finish: finish }
end function

sub Test_LiveGuide_Window()
    ' 2026-11-07 19:47:10 UTC, five hours behind UTC (14:47 local).
    now = 1794080830
    offset = -5 * 3600
    start = ZGuideWindowStart(now, offset)
    AssertEqual(start, 1794079800, "starts at the current half hour")
    AssertEqual(ZGuideTime(start, offset), "2:30 PM", "local half hour")
    ' A 45 minute zone floors to its own half hour.
    AssertEqual(ZGuideTime(ZGuideWindowStart(now, 20700), 20700), "1:30 AM", "Nepal half hour")
    day = ZGuideDayStart(now, offset)
    AssertEqual(ZGuideTime(day, offset), "12:00 AM", "local midnight")
    AssertEqual(ZGuideClampStart(day - 3600, now, offset), day, "not before today")
    AssertEqual(ZGuideClampStart(day + 30 * 86400, now, offset), day + 7 * 86400 - 7200, "not past seven days")
    AssertEqual(ZGuideDayLabel(start, now, offset), "Today", "today")
    AssertEqual(ZGuideDayLabel(start + 86400, now, offset), "Tomorrow", "tomorrow")
    AssertEqual(ZGuideDayLabel(start + 2 * 86400, now, offset), "Mon, Nov 9", "later day")
    AssertEqual(ZGuideRange(start, start + 1800, offset), "2:30 PM – 3:00 PM", "range")
    AssertTrue(Abs(ZGuideFraction(start, start + 1800) - 0.25) < 0.001, "fraction")
    AssertEqual(ZGuideFraction(start, start - 10), 0, "fraction clamps")
end sub

sub Test_LiveGuide_Slots()
    s = 1000000
    e = s + 7200
    programs = [
        GuideProgram("late", "a", s + 3600, s + 5400),
        GuideProgram("early", "a", s - 600, s + 1800),
        GuideProgram("overlap", "a", s + 1200, s + 2400),
        GuideProgram("other", "b", s, e),
        GuideProgram("after", "a", e, e + 600)
    ]
    slots = ZGuideSlots("a", programs, s, e)
    AssertEqual(slots.count(), 5, "slot count")
    AssertEqual(slots[0].program.id, "early", "clipped first program")
    AssertEqual(slots[0].start, s, "clipped to window start")
    AssertEqual(slots[1].program.id, "overlap", "overlap trimmed to free time")
    AssertEqual(slots[1].start, s + 1800, "overlap starts after the earlier show")
    AssertTrue(slots[2].program = invalid, "gap kept")
    AssertEqual(slots[3].program.id, "late", "later program")
    AssertTrue(slots[4].program = invalid and slots[4].finish = e, "trailing gap")
    empty = ZGuideSlots("z", programs, s, e)
    AssertEqual(empty.count(), 1, "no listings is one empty slot")
    AssertEqual(ZGuideSlotAt(slots, s + 3700), 3, "slot at a time")
    AssertEqual(ZGuideSlotAt(slots, e + 50), 4, "past the end picks the last slot")
    AssertTrue(ZGuideAiring(slots[0].program, s + 10), "airing")
    AssertTrue(not ZGuideAiring(slots[2].program, s + 10), "empty slot not airing")
end sub

sub Test_LiveGuide_Match()
    channels = [
        { id: "1", name: "News One", number: "4.1", favorite: true },
        { id: "2", name: "Sports", number: "7", favorite: false },
        { id: "1", name: "News One", number: "4.1", favorite: true },
        { id: "", name: "Broken", number: "9" }
    ]
    AssertEqual(ZGuideMatch(channels, "", false).count(), 2, "dedupes and drops empty ids")
    AssertEqual(ZGuideMatch(channels, "", true).count(), 1, "favorites")
    AssertEqual(ZGuideMatch(channels, " sport ", false)[0].id, "2", "name query")
    AssertEqual(ZGuideMatch(channels, "4.1", false)[0].id, "1", "number query")
    AssertEqual(ZGuideMatch(channels, "sport", true).count(), 0, "both filters")
end sub
