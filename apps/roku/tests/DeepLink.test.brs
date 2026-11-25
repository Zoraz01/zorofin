' Roku deep links: mediaType actions, item ids and series smart bookmarks.

sub Test_DeepLink_Actions()
    for each t in ["movie", "episode", "shortFormVideo", "tvSpecial", "special", "live", "MOVIE"]
        AssertEqual(ZDeepLinkAction(t), "play", t + " plays")
    end for
    AssertEqual(ZDeepLinkAction("series"), "series", "series")
    AssertEqual(ZDeepLinkAction("season"), "season", "season")
    AssertEqual(ZDeepLinkAction(""), "item", "no type")
    AssertEqual(ZDeepLinkAction(invalid), "item", "missing type")
    AssertEqual(ZDeepLinkAction("podcast"), "invalid", "unknown type")
end sub

sub Test_DeepLink_Ids()
    AssertEqual(ZDeepLinkId("4216013f95730304f9d9979a8c67a36f"), "4216013f95730304f9d9979a8c67a36f", "plain id")
    AssertEqual(ZDeepLinkId("4216013F-9573-0304-F9D9-979A8C67A36F"), "4216013f95730304f9d9979a8c67a36f", "dashed upper case")
    AssertEqual(ZDeepLinkId(" 4216013f95730304f9d9979a8c67a36f "), "4216013f95730304f9d9979a8c67a36f", "trimmed")
    AssertEqual(ZDeepLinkId("12345"), "", "too short")
    AssertEqual(ZDeepLinkId("../Users/x"), "", "path rejected")
    AssertEqual(ZDeepLinkId(invalid), "", "missing")
end sub

sub Test_DeepLink_Bookmark()
    watched = { Id: "1", UserData: { Played: true } }
    fresh = { Id: "2", UserData: { Played: false } }
    partway = { Id: "3", UserData: { Played: false, PlaybackPositionTicks: 5000 } }
    AssertEqual(ZBookmarkEpisode([watched, fresh, partway]).Id, "3", "in progress first")
    AssertEqual(ZBookmarkEpisode([watched, fresh]).Id, "2", "then first unwatched")
    AssertEqual(ZBookmarkEpisode([watched, { Id: "4", UserData: { Played: true } }]).Id, "1", "all watched starts over")
    AssertEqual(ZBookmarkEpisode([]), invalid, "no episodes")
    AssertEqual(ZBookmarkEpisode(invalid), invalid, "missing")
end sub

sub Test_DeepLink_Targets()
    for each t in ["Movie", "Episode", "Video", "MusicVideo", "TvChannel"]
        AssertEqual(ZDeepLinkTarget(t), "play", t)
    end for
    AssertEqual(ZDeepLinkTarget("Series"), "details", "show without episodes")
    AssertEqual(ZDeepLinkTarget("Season"), "details", "season without episodes")
    for each t in ["UserRootFolder", "CollectionFolder", "Folder", "Person", "BoxSet", ""]
        AssertEqual(ZDeepLinkTarget(t), "", "not a link target: " + t)
    end for
end sub
