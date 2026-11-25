' Chapters and per-show track memory, the same cases as the Apple and
' Flutter player extras tests.

sub Test_PlayerExtras_ChaptersSortedAndNumbered()
    chapters = ZChapters({ Chapters: [
        { StartPositionTicks: 6000000000, Name: "The heist" },
        { StartPositionTicks: 0, Name: " " }
    ] })
    AssertEqual(chapters.count(), 2, "two chapters")
    AssertEqual(chapters[0].name, "Chapter 1", "unnamed is numbered in time order")
    AssertEqual(chapters[1].name, "The heist", "named")
    AssertEqual(chapters[1].start, 600, "seconds")
    AssertEqual(ZChapterIndex(chapters, 599), 0, "before the second")
    AssertEqual(ZChapterIndex(chapters, 600), 1, "at the second")
    AssertEqual(ZChapters({ Chapters: [{ StartPositionTicks: 0, Name: "Only" }] }).count(), 0, "one chapter is none")
    AssertEqual(ZChapters({}).count(), 0, "no chapters")
end sub

sub Test_PlayerExtras_PicksRememberedLanguages()
    audio = [{ index: 1, language: "eng" }, { index: 2, language: "jpn" }]
    subtitles = [{ index: 3, language: "eng", forced: true }, { index: 4, language: "eng", forced: false }, { index: 5, language: "spa", forced: false }]
    pick = ZPickTracks({ audio: "JPN", subtitle: "eng", forced: false }, audio, subtitles)
    AssertEqual(pick.audio, 2, "audio by language")
    AssertEqual(pick.subtitle, 4, "full subtitles, not forced")
    AssertEqual(ZPickTracks({ subtitle: "eng", forced: true }, audio, subtitles).subtitle, 3, "forced")
    AssertEqual(ZPickTracks({ off: true, subtitle: "eng" }, audio, subtitles).subtitle, -1, "off wins")
    none = ZPickTracks({ audio: "fra", subtitle: "fra" }, audio, subtitles)
    AssertTrue(none.audio = invalid and none.subtitle = invalid, "no track in that language")
    AssertTrue(ZPickTracks(invalid, audio, subtitles).audio = invalid, "nothing remembered")
end sub

sub Test_PlayerExtras_BuildsPlaybackProblemReports()
    on = { playbackReports: 1 }
    info = { id: "abc", title: "Dune", playMethod: "DirectPlay", isLive: false }
    body = ZPlaybackProblemBody("fallback", "bad codec", info, on, { sendPlaybackReports: true }, {}, "1.5.0", "Den Roku", 42.7)
    AssertEqual(body.kind, "fallback", "kind")
    AssertEqual(body.itemId, "abc", "item")
    AssertEqual(body.title, "Dune", "title")
    AssertEqual(body.platform, "Roku", "platform")
    AssertEqual(body.appVersion, "1.5.0", "version")
    AssertEqual(body.method, "direct", "method")
    AssertEqual(body.positionSeconds, 42, "position")
    AssertEqual(ZPlaybackProblemBody("stopped", "x", { id: "c", playMethod: "Transcode", isLive: true }, on, {}, {}, "1", "r").method, "live", "live")
    AssertEqual(ZPlaybackProblemMethod({ playMethod: "DirectStream" }), "remux", "remux")
    AssertTrue(ZPlaybackProblemBody("stopped", "x", info, {}, {}, {}, "1", "r") = invalid, "server doesn't collect")
    AssertTrue(ZPlaybackProblemBody("stopped", "x", info, on, { sendPlaybackReports: false }, {}, "1", "r") = invalid, "viewer said no")
    AssertTrue(ZPlaybackProblemBody("stopped", "x", info, on, {}, { refused: true }, "1", "r") = invalid, "server refused")
    AssertTrue(ZPlaybackProblemBody("stopped", "x", info, on, {}, { sent: 30 }, "1", "r") = invalid, "run limit")
    AssertTrue(ZPlaybackProblemBody("stopped", "x", invalid, on, {}, {}, "1", "r") = invalid, "nothing playing")
end sub

sub Test_PlayerExtras_StepsQualityDown()
    AssertEqual(ZLowerQuality(0, 80000000, 0), 40000000, "auto on a 4K Roku")
    AssertEqual(ZLowerQuality(0, 20000000, 0), 12000000, "auto on an HD Roku")
    AssertEqual(ZLowerQuality(0, 80000000, 9000000), 8000000, "under what the server sends")
    AssertEqual(ZLowerQuality(8000000, 80000000, 0), 4000000, "from a chosen limit")
    AssertEqual(ZLowerQuality(2000000, 80000000, 0), 0, "nothing lower")
    AssertTrue(ZShouldLowerQuality([100], 103, 6), "a 6 second stall")
    AssertTrue(ZShouldLowerQuality([50, 100], 104, 1), "twice in a minute")
    AssertTrue(not ZShouldLowerQuality([10, 100], 104, 1), "twice, far apart")
    AssertTrue(not ZShouldLowerQuality([100], 104, 3), "one short buffer")
end sub

sub Test_PlayerExtras_ShiftsSubtitles()
    AssertEqual(ZTimingLabel(0), "In sync", "in sync")
    AssertEqual(ZTimingLabel(3), "+0.3 s", "later")
    AssertEqual(ZTimingLabel(-12), "−1.2 s", "earlier")
    AssertEqual(ZClampTiming(250), 100, "at most 10 s later")
    AssertEqual(ZClampTiming(-250), -100, "at most 10 s earlier")
    url = "https://example.com/Videos/abc/abc/Subtitles/3/0/Stream.vtt?api_key=k"
    AssertEqual(ZSubtitleUrlShifted(url, 0), url, "unchanged in sync")
    AssertEqual(ZSubtitleUrlShifted(url, 5), "https://example.com/Videos/abc/abc/Subtitles/3/-5000000/Stream.vtt?api_key=k", "later")
    AssertEqual(ZSubtitleUrlShifted(url, -12), "https://example.com/Videos/abc/abc/Subtitles/3/12000000/Stream.vtt?api_key=k", "earlier")
    AssertEqual(ZSubtitleUrlShifted(ZSubtitleUrlShifted(url, 5), -12), "https://example.com/Videos/abc/abc/Subtitles/3/12000000/Stream.vtt?api_key=k", "replaces an earlier shift")
    AssertEqual(ZSubtitleUrlShifted("https://example.com/other.vtt", 5), "https://example.com/other.vtt", "another shape")
end sub
