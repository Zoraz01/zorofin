' Pick Together on the TV: the same session rules as the Apple and Flutter apps.

sub Test_Pick_SessionSkipsTheDisplayAndWaitsForTwoVoters()
    json = { schemaVersion: 1, id: "abcdef0123456789abcdef0123456789", code: "abc def", kind: "movie", status: "lobby", version: 2, host: true, seat: "tv1",
        members: [{ seat: "tv1", name: "TV", display: true, host: true }, { seat: "p1", name: "Alex", swiped: 3, total: 20 }, { seat: "bad seat!", name: "x" }],
        matches: [{ itemId: "aa11", title: "Fargo", likes: 2, of: 2, imageTag: "t" }, { itemId: "not hex", title: "x" }] }
    s = ZPickSession(json)
    AssertEqual(s.code, "ABCDEF", "code normalized")
    AssertEqual(s.members.count(), 1, "display and invalid seats left out")
    AssertEqual(s.voters, 1, "voters from members when the server leaves it out")
    AssertTrue(not s.canStart, "Start waits for two voters")
    AssertEqual(s.matches.count(), 1, "invalid item ids dropped")
    AssertEqual(s.matches[0].tally, "2 of 2", "tally")
    AssertEqual(ZPickItemJson(s.matches[0]).ImageTags.Primary, "t", "artwork tag")
    json.voters = 2
    AssertTrue(ZPickSession(json).canStart, "host can start with two voters")
end sub

sub Test_Pick_RejectsMalformedSessionsAndWordsErrors()
    AssertTrue(ZPickSession({ schemaVersion: 2 }) = invalid, "unknown schema")
    AssertTrue(ZPickSession({ schemaVersion: 1, id: "short", code: "ABCDEF", kind: "movie", version: 1 }) = invalid, "bad id")
    AssertEqual(ZPickCode("ab1 23i"), "", "I and 1 are not in the alphabet")
    AssertEqual(ZPickSpaced("ABCDEF"), "ABC DEF", "spaced code")
    AssertTrue(ZPickError(404).ended, "404 ends the session")
    AssertTrue(not ZPickError(429).ended, "busy keeps it")
end sub

sub Test_Pick_TrailerPreviewsAreDirectPlayOnly()
    ok = { Container: "mov,mp4,m4a", MediaStreams: [{ Type: "Video", Codec: "h264", Height: 1080 }, { Type: "Audio", Codec: "aac" }] }
    AssertTrue(ZTrailerCompatible(ok), "mp4 h264 1080p aac")
    AssertTrue(not ZTrailerCompatible({ Container: "mkv", MediaStreams: ok.MediaStreams }), "mkv needs a remux")
    AssertTrue(not ZTrailerCompatible({ Container: "mp4", MediaStreams: [{ Type: "Video", Codec: "h264", Height: 2160 }] }), "4K is too big for a preview")
    AssertTrue(not ZTrailerCompatible({ Container: "mp4", MediaStreams: [{ Type: "Video", Codec: "hevc", Height: 720 }, { Type: "Audio", Codec: "dts" }] }), "DTS-only audio")
end sub
