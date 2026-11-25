' Mirrors apps/apple/Core/Tests/ZorofinCoreTests/LiveTVStreamsTests.swift so
' the Roku app says exactly what Apple TV and the Flutter apps say.

function LtsFullJson() as string
    espn = String(32, "e")
    fox = String(32, "f")
    return "{""version"":1,""state"":""full"",""limit"":1,""inUse"":1,""free"":0,""otherUse"":0,""message"":""1 of 1 Live TV stream in use: ESPN.""," + "
 ""streams"":[{""channelId"":""" + espn + """,""channelName"":""ESPN"",""channelNumber"":""206"",""programme"":{""title"":""SportsCenter"",""endsAt"":""2026-11-07T16:00:00.0000000Z""}," + "
 ""startedAt"":""2026-11-07T15:00:00.000Z"",""viewers"":2,""paused"":false,""yours"":false}]," + "
 ""request"":{""channelId"":""" + fox + """,""playing"":false,""canStart"":false,""reason"":""full"",""message"":""""}}"
end function

sub Test_LiveTvStreams_NamesTheChannelUsingTheOnlyStream()
    espn = String(32, "e")
    fox = String(32, "f")
    status = ZLtsParse(ParseJson(LtsFullJson()))
    AssertTrue(status <> invalid, "parses the companion response")
    AssertEqual(ZLtsSummary(status), "1 of 1 Live TV stream in use. Anyone can join a channel that’s already playing.", "summary")
    AssertEqual(ZLtsChannelLine(status, fox), "ESPN is using the only Live TV stream.", "line for a blocked channel")
    AssertEqual(ZLtsChannelLine(status, espn), "Already playing for 2 people. Joining doesn’t use another stream.", "line for the playing channel")
    blocked = ZLtsBlocked(status, fox)
    AssertTrue(blocked <> invalid, "blocked")
    AssertEqual(blocked.title, "Live TV is in use", "alert title")
    AssertEqual(blocked.text, "ESPN is using the only Live TV stream right now.", "alert text")
    AssertEqual(blocked.hint, "You can watch ESPN instead, or try again when a stream is free.", "alert hint")
    AssertEqual(blocked.join.channelId, espn, "join offers ESPN")
    AssertTrue(ZLtsBlocked(status, espn) = invalid, "joining a playing channel is never blocked")
    now = ZIsoToSeconds("2026-11-07T15:42:00Z")
    AssertEqual(ZLtsDetail(status.streams[0], now), "2 watching · 18 min left", "card detail")
end sub

sub Test_LiveTvStreams_FreeStreamsBlockNothing()
    espn = String(32, "e")
    fox = String(32, "f")
    status = ZLtsParse({ version: 1, limit: 2, inUse: 1, free: 1, streams: [{ channelId: espn, channelName: "ESPN" }] })
    AssertTrue(ZLtsBlocked(status, fox) = invalid, "not blocked")
    AssertEqual(ZLtsChannelLine(status, fox), "", "no line")
    AssertEqual(ZLtsSummary(status), "1 of 2 Live TV streams in use. 1 stream free for another channel.", "summary")
end sub

sub Test_LiveTvStreams_ListsSeveralChannelsAndOtherApps()
    status = ZLtsParse({ version: 1, limit: 3, inUse: 3, free: 0, otherUse: 1, streams: [
        { channelId: "a", channelName: "ESPN", viewers: 1 },
        { channelId: "b", channelName: "CNN", viewers: 1, yours: true }
    ] })
    AssertEqual(ZLtsChannelLine(status, "c"), "ESPN, CNN and another app are using all 3 Live TV streams.", "line")
    AssertEqual(ZLtsChannelLine(status, "b"), "You’re watching this channel.", "own stream")
    blocked = ZLtsBlocked(status, "c")
    AssertEqual(blocked.hint, "You can watch one of those channels instead, or try again when a stream is free.", "hint for several")
    AssertTrue(blocked.join = invalid, "no single channel to join")
end sub

sub Test_LiveTvStreams_MatchesIdsWithOrWithoutDashes()
    status = ZLtsParse({ version: 1, limit: 1, inUse: 1, free: 0, streams: [{ channelId: "ABCD-1234", channelName: "ESPN" }] })
    AssertTrue(ZLtsStream(status, "abcd1234") <> invalid, "dashes and case are ignored")
end sub

sub Test_LiveTvStreams_RejectsBadResponses()
    AssertTrue(ZLtsParse(invalid) = invalid, "missing body")
    AssertTrue(ZLtsParse({ version: 2, limit: 1, inUse: 0, free: 1 }) = invalid, "unknown version")
    AssertTrue(ZLtsParse({ version: 1, limit: 0, inUse: 0, free: 0 }) = invalid, "zero limit")
    AssertTrue(ZLtsParse({ version: 1, limit: 1, inUse: -1, free: 1 }) = invalid, "negative count")
end sub

sub Test_LiveTvStreams_TimeLeft()
    now = ZIsoToSeconds("2026-11-07T15:00:00Z")
    AssertEqual(ZLtsTimeLeft("2026-11-07T16:30:00Z", now), "1 hr 30 min left", "hours and minutes")
    AssertEqual(ZLtsTimeLeft("2026-11-07T17:00:00Z", now), "2 hr left", "whole hours")
    AssertEqual(ZLtsTimeLeft("2026-11-07T14:00:00Z", now), "", "already ended")
end sub


sub Test_LiveTvStreams_UsesServerCapacityNotVisibleChannelCount()
    status = ZLtsParse({ version: 1, limit: 2, inUse: 2, free: 0, otherUse: 1, streams: [{ channelId: "a", channelName: "Sports", viewers: 9 }] })
    AssertEqual(ZLtsSummary(status), "2 of 2 Live TV streams in use. Anyone can join a channel that’s already playing.", "server count; neither viewer count nor visible channel count")
end sub


sub Test_LiveTvStreams_LegacyOnlyForOlderServers()
    AssertEqual(ZLtsRoute({ liveTvStreams: 1, liveTVAvailability: 1 }), "companion", "pool counts win")
    AssertEqual(ZLtsRoute({ liveTVAvailability: 1 }), "legacy", "old adapter")
    AssertEqual(ZLtsRoute({}), "", "ordinary Jellyfin")
    s = ZLtsParseLegacy({ limit: 2, state: "busy", sameChannel: false, differentChannel: true, ownStream: false }, "c")
    AssertTrue(ZLtsBlocked(s, "c") <> invalid, "older adapter blocks a different channel")
    AssertTrue(Instr(1, ZLtsSummary(s), "of 2") = 0, "does not invent a precise usage count")
    s = ZLtsParseLegacy({ limit: 2, state: "busy", sameChannel: true, differentChannel: false, ownStream: false }, "c")
    AssertTrue(ZLtsBlocked(s, "c") = invalid, "joining existing channel allowed")
    AssertTrue(ZLtsParseLegacy({ limit: 2, state: "available" }, "c") = invalid, "bad legacy response")
end sub
