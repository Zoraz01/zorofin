' Live now events and scores (same cases as support-agent/tests/live-events.test.js).

function LiveIso(seconds as integer) as string
    d = CreateObject("roDateTime")
    d.FromSeconds(seconds)
    return d.ToISOString()
end function

function LiveChannel(name as string, patch = invalid as dynamic, extra = invalid as dynamic) as object
    now = 1791828000
    p = { Id: "p-" + name, Name: name, StartDate: LiveIso(now - 3600), EndDate: LiveIso(now + 3600) }
    if patch <> invalid then p.append(patch)
    c = { Id: name, Name: "Test Sports", ChannelNumber: "1", CurrentProgram: p }
    if extra <> invalid then c.append(extra)
    return c
end function

function LiveNames(events as object) as object
    out = []
    for each e in events
        out.push(e.name)
    end for
    return out
end function

sub Test_LiveEvents_SportOrder()
    now = 1791828000
    fav = { UserData: { IsFavorite: true } }
    c = [LiveChannel("Live: Cricket"), LiveChannel("Live: Soccer"), LiveChannel("Live: NBA Basketball"), LiveChannel("Live: NFL Football"), LiveChannel("Live: CFL Football", invalid, fav)]
    AssertEqual(LiveNames(ZLiveSelect(c, now)), ["NBA Basketball", "NFL Football", "Soccer", "CFL Football", "Cricket"], "sport ranking keeps soccer ahead of CFL")
    c = [LiveChannel("Live: College Football", invalid, fav), LiveChannel("Live: NFL Football", invalid, fav), LiveChannel("Live: College Basketball"), LiveChannel("Live: WNBA Basketball"), LiveChannel("Live: NBA Basketball")]
    ranked = ZLiveSelect(c, now)
    AssertEqual(ranked[0].name, "NBA Basketball", "NBA leads")
    AssertEqual(LiveNames(ranked), ["NBA Basketball", "College Football", "NFL Football", "College Basketball", "WNBA Basketball"], "other basketball not promoted")
    genresOnly = LiveChannel("Live: Celtics vs Knicks", { IsLive: true, Genres: ["Sports", "NBA"] })
    AssertEqual(ZLiveSelect([c[0], genresOnly], now)[0].name, "Celtics vs Knicks", "NBA by genre")
    AssertEqual(LiveNames(ZLiveSelect([LiveChannel("Live: CFL Football", invalid, fav), LiveChannel("Live: Premier League Soccer")], now)), ["Premier League Soccer", "CFL Football"], "Premier League before CFL")
end sub

sub Test_LiveEvents_Rejects()
    now = 1791828000
    for each name in ["Law & Order", "College Football", "US| UFC HD", "NBA TV", "ESPN News"]
        AssertTrue(ZLiveEventFor(LiveChannel(name, { IsSports: true }), now) = invalid, "not live: " + name)
    end for
    AssertTrue(ZLiveEventFor(LiveChannel("Live: Soccer", { IsRepeat: true }), now) = invalid, "repeat")
    AssertTrue(ZLiveEventFor(LiveChannel("Live: Soccer", { IsLive: false }), now) = invalid, "IsLive false")
    AssertEqual(ZLiveEventFor(LiveChannel("Soccer", { IsLive: true }), now).kind, "soccer", "IsLive soccer")
    AssertTrue(ZLiveEventFor(LiveChannel("Test Sports", { IsLive: true }), now) = invalid, "channel name as title")
    for each name in ["SEC Now", "B1G Live", "MLB Tonight", "NBA Today", "SportsCenter", "Premier League Live", "Tiki + Tierney", "Monday Night Countdown", "College Football Highlights", "Nuggets Postgame Live"]
        AssertTrue(ZLiveEventFor(LiveChannel("Live: " + name + " — Alpha Team vs Beta Team", { IsSports: true }), now) = invalid, "studio: " + name)
    end for
    AssertTrue(ZLiveEventFor(LiveChannel("Live: NFL Football", { Overview: "A preview show with studio analysis." }), now) = invalid, "discussion overview")
    for each patch in [{ StartDate: "invalid" }, { EndDate: invalid }, { StartDate: LiveIso(now + 1) }, { EndDate: LiveIso(now) }, { StartDate: LiveIso(now - 86400) }]
        AssertTrue(ZLiveEventFor(LiveChannel("Live: Soccer", patch), now) = invalid, "time window " + FormatJson(patch))
    end for
    AssertEqual(ZLiveEventFor(LiveChannel("Live: Opening Ceremony"), now).kind, "event", "ceremony")
    AssertTrue(ZLiveEventFor(LiveChannel("Live: Something"), now) = invalid, "generic live label")
    for each title in ["Live: 7News ON YOUR SIDE at 5AM", "Live: MLB on TBS: Leadoff", "Live: Premier League Goal Zone", "Live: Cricket Preview"]
        AssertTrue(ZLiveEventFor(LiveChannel(title), now) = invalid, title)
    end for
end sub

sub Test_LiveEvents_Titles()
    now = 1791828000
    AssertEqual(ZLiveCleanTitle("Live: Canadian Premier League Soccer — Newcastle United vs Coventry City", "From Hamilton Stadium in Hamilton, Ontario.", invalid), "Canadian Premier League Soccer", "unproven suffix dropped")
    AssertEqual(ZLiveCleanTitle("Live: Premier League Soccer — Newcastle United vs Coventry City", "Coventry City hosts Newcastle United at Coventry Building Society Arena.", invalid), "Premier League Soccer — Newcastle United vs Coventry City", "grounded suffix kept")
    AssertEqual(ZLiveCleanTitle("Live: Soccer — York vs New York", "New York plays today.", invalid), "Soccer", "word boundaries")
    AssertTrue(ZLiveEventFor(LiveChannel("Live: NFL Football — AFC East vs NFC West", { Overview: "AFC East meets NFC West." }), now).matchup = invalid, "division pair")
    AssertEqual(ZLiveEventFor(LiveChannel("Live: NBA Basketball — 76ers vs Nets", { Overview: "The 76ers host the Nets." }), now).matchup, ["76ers", "Nets"], "matchup")
    AssertEqual(ZLiveNormalized("Lillestrøm  São-Paulo"), "lillestrom sao paulo", "folds accents")
    a = LiveChannel("Live: NFL Football — Alpha Team vs Beta Team", { Overview: "Alpha Team hosts Beta Team." })
    b = LiveChannel("Live: NFL Football — Alpha Team vs Beta Team", { Overview: "Alpha Team hosts Beta Team." }, { Id: "other-channel", Name: "Other channel", UserData: { IsFavorite: true } })
    picked = ZLiveSelect([a, b], now)
    AssertEqual(picked.count(), 1, "simulcast merged")
    AssertEqual(picked[0].id, "other-channel", "favorite simulcast kept")
    c = LiveChannel("Live: NFL Football — Alpha Team vs Beta Team", { Overview: "Alpha Team hosts Beta Team.", EndDate: LiveIso(now + 7200) }, { Id: "later" })
    AssertEqual(ZLiveSelect([a, c], now).count(), 2, "different slot kept")
    AssertEqual(ZLiveSelect([LiveChannel("Live: College Football"), LiveChannel("Live: College Football", invalid, { Id: "another" })], now).count(), 2, "generic titles not merged")
end sub

function LiveGame() as object
    return { id: "nba:1", state: "in", start: "2026-11-09T00:30:00.000Z", detail: "Q3 4:12", score: { home: "88", away: "64" }, home: { name: "Dallas Mavericks", short: "Mavericks", abbreviation: "DAL" }, away: { name: "Brooklyn Nets", short: "Nets", abbreviation: "BKN" }, channels: [] }
end function

function LiveWith(base as object, patch as object) as object
    out = {}
    out.append(base)
    out.append(patch)
    return out
end function

sub Test_LiveEvents_Scores()
    start = 1794184200
    game = LiveGame()
    event = { matchup: ["Brooklyn Nets", "Dallas Mavericks"], start: start, channel: "NBA — Nets At Mavericks" }
    score = ZLiveScore(event, [game])
    AssertEqual(score, { away: "BKN", awayScore: "64", home: "DAL", homeScore: "88", detail: "Q3 4:12", final: false, live: true, league: "", awayName: "Nets", homeName: "Mavericks", awayColor: "", homeColor: "" }, "score")
    AssertEqual(ZLiveStatus(score, "NBA"), "NBA · Q3 4:12", "status")
    AssertEqual(ZLiveStatus(score), "Q3 4:12", "status without league")
    AssertEqual(ZLiveStatus(ZLiveScore(event, [LiveWith(game, { leagueName: "NBA" })]), "NBA Basketball"), "NBA · Q3 4:12", "feed league name first")
    AssertEqual(ZLiveChannelLine("ESPN", "206", true), "Your teams · ESPN · Ch 206", "favorite channel line")
    AssertEqual(ZLiveChannelLine("ESPN", "", false), "ESPN", "plain channel line")
    AssertEqual(ZLiveTint(score), "0x1E3A5FFF", "tint without colours")
    AssertEqual(ZLiveTint({ homeColor: "0x0053BCFF", awayColor: "" }), "0x002555FF", "darkened team tint")
    AssertTrue(ZLiveScore(LiveWith(event, { matchup: ["Nets", "Mavericks"] }), [game]) <> invalid, "short names match")
    AssertTrue(ZLiveScore(LiveWith(event, { channel: "Test Sports", matchup: ["Brooklyn Nets", "Miami Heat"] }), [game]) = invalid, "one team is not enough")
    AssertTrue(ZLiveScore(LiveWith(event, { start: start + 12 * 3600 }), [game]) = invalid, "different day")
    noScore = LiveWith(game, {})
    noScore.delete("score")
    AssertTrue(ZLiveScore(event, [noScore]) = invalid, "spoiler-free")
    AssertTrue(ZLiveScore(event, [LiveWith(game, { state: "pre" })]) = invalid, "pre game")
    AssertTrue(ZLiveScore(event, [LiveWith(game, { score: { home: "<b>", away: "1" } })]) = invalid, "plain numbers only")
    AssertEqual(ZLiveScore({ matchup: invalid, start: start, channel: "ESPN" }, [LiveWith(game, { channels: [{ name: "ESPN" }] })]).final, false, "channel match")
    final = ZLiveScore(event, [LiveWith(game, { state: "post", detail: "Final" })])
    AssertEqual(final.final, true, "final")
    AssertEqual(ZLiveStatus(final, "NBA"), "NBA · Final", "final status")
    AssertEqual(ZLiveScore({ matchup: invalid, start: start, channel: "NBA — Nets At Mavericks" }, [game]).home, "DAL", "event channel name")
    AssertTrue(ZLiveScore({ matchup: invalid, start: start, channel: "NBA — Heat At Kings" }, [game]) = invalid, "other event channel")
    AssertTrue(ZLiveScore({ matchup: invalid, start: start, channel: "NBA 7" }, [game]) = invalid, "plain channel")
    AssertEqual(ZLiveTeamColor("#0053bc"), "0x0053BCFF", "team colour")
    AssertEqual(ZLiveTeamColor("#000000"), "0xD9DEDBFF", "dark colour lightened")
    AssertEqual(ZLiveTeamColor("red"), "", "bad colour")
end sub

sub Test_LiveEvents_Arrange()
    start = 1794184200
    iso = "2026-11-09T00:30:00.000Z"
    games = [
        { state: "in", start: iso, home: { name: "Sacramento Kings", short: "Kings", abbreviation: "SAC", favorite: true }, away: { name: "Miami Heat", short: "Heat", abbreviation: "MIA", favorite: false } },
        { state: "in", start: iso, home: { name: "Dallas Mavericks", short: "Mavericks", abbreviation: "DAL", favorite: false }, away: { name: "Brooklyn Nets", short: "Nets", abbreviation: "BKN", favorite: false } }
    ]
    make = function(channel as string, context as string, start as integer) as object
        return { channel: channel, start: start, leagueContext: context, matchup: invalid, name: channel, favoriteTeam: false, score: invalid }
    end function
    specs = [["NBA — Nets At Mavericks", "NBA Basketball"], ["NBA — Celtics At Bucks", "NBA Basketball"], ["ESPN", "Boxing"], ["NBA — Heat At Kings", "NBA Basketball"]]
    events = []
    for each s in specs
        events.push(make(s[0], s[1], start))
    end for
    out = ZLiveArrange(events, { games: games, leagues: ["basketball/nba"] })
    channels = []
    for each e in out
        channels.push(e.channel)
    end for
    AssertEqual(channels, ["NBA — Heat At Kings", "NBA — Nets At Mavericks", "ESPN"], "feed order, cap drops, boxing kept")
    AssertEqual(out[0].favoriteTeam, true, "favorite team")
    AssertEqual(out[1].favoriteTeam, false, "not favorite")
    AssertTrue(out[0].score = invalid, "spoiler-free")
    events = []
    for each s in specs
        events.push(make(s[0], s[1], start))
    end for
    AssertEqual(ZLiveArrange(events, { games: games, leagues: [] }).count(), 4, "unfollowed leagues stay")
    AssertEqual(ZLiveArrange(events, invalid).count(), 4, "no feed keeps the row")
    AssertTrue(ZLiveParseFeed({ games: [], updatedAt: invalid }) = invalid, "no read yet")
    feed = ZLiveParseFeed({ games: [games[0], { id: "broken" }], updatedAt: "2026-11-09T00:31:00Z", leagues: ["basketball/nba"] })
    AssertEqual(feed.games.count(), 1, "drops games without teams")
end sub

sub Test_LiveEvents_ProgramImage()
    c = { Id: "c1", Name: "Sports 1", ImageTags: { Primary: "logo" }, CurrentProgram: { Id: "p1", Name: "Live: Arsenal vs Chelsea", ImageTags: { Primary: "logo", Thumb: "match" }, BackdropImageTags: ["wide"] } }
    AssertEqual(ZLiveProgramImage(c), { item: "p1", kind: "Thumb", tag: "match" }, "thumb first")
    c.CurrentProgram.ImageTags.Thumb = "logo"
    AssertEqual(ZLiveProgramImage(c), { item: "p1", kind: "Backdrop", tag: "wide" }, "channel logo skipped")
    c.CurrentProgram.BackdropImageTags = []
    AssertTrue(ZLiveProgramImage(c) = invalid, "only the logo")
    c.CurrentProgram.Id = "c1"
    AssertTrue(ZLiveProgramImage(c) = invalid, "programme is the channel")
end sub

' Fixture artwork catalogue (same cases as the web artworkDetailsFor tests).
function LiveFixture(league as string, sport as string, startAt as integer, away as object, home as object, image as string, logos as object) as object
    return { league: league, sport: sport, start: LiveIso(startAt), away: away, home: home, image: image, logos: logos }
end function

sub Test_LiveEvents_ArtworkTeams()
    now = 1791828000
    e = ZLiveEventFor(LiveChannel("Live: NFL Football — The Rams vs Bills", { IsLive: true, Overview: "The Rams host the Bills." }), now)
    f = LiveFixture("football/nfl", "football", now - 3600, { id: "b", name: "Buffalo Bills", aliases: ["buffalo bills", "bills"] }, { id: "r", name: "Los Angeles Rams", aliases: ["los angeles rams", "rams"] }, "", ["/live-tv-logos/art/bills.png", "/live-tv-logos/art/rams.png"])
    manifest = { version: 2, events: [f] }
    art = ZLiveArtwork(e, manifest)
    AssertEqual(art.logos, ["/live-tv-logos/art/rams.png", "/live-tv-logos/art/bills.png"], "crests in title order")
    AssertEqual(art.image, "", "no photo")
    generic = ZLiveEventFor(LiveChannel("Live: NFL Football", { IsLive: true, Overview: "The Rams host the Bills." }), now)
    AssertTrue(ZLiveArtwork(generic, manifest) <> invalid, "teams from the description")
    AssertEqual(ZLiveArtwork(LiveWith(generic, { evidence: "An AFC East team plays an NFC West team." }), manifest), invalid, "no named teams")
    AssertEqual(ZLiveArtwork(e, { version: 2, events: [f, LiveWith(f, { id: "ambiguous" })] }), invalid, "ambiguous")
    AssertEqual(ZLiveArtwork(e, { version: 2, events: [LiveWith(f, { start: LiveIso(now + 86400) })] }), invalid, "another day")
    AssertEqual(ZLiveArtwork(LiveWith(e, { leagueContext: "Women NFL" }), manifest), invalid, "women")
    AssertEqual(ZLiveArtwork(LiveWith(e, { leagueContext: "College football" }), manifest), invalid, "college")
    AssertEqual(ZLiveArtwork(e, { version: 2, events: [LiveWith(f, { logos: ["https://evil.example/a.png", "/live-tv-logos/art/rams.png"] })] }), invalid, "unsafe path")
    AssertEqual(ZLiveArtwork(e, { version: 1, events: [f] }), invalid, "v2 only")
end sub

sub Test_LiveEvents_ArtworkUnlabelled()
    now = 1791828000
    e = ZLiveEventFor(LiveChannel("Live: Copenhagen vs Braga", { IsLive: true }), now)
    f = LiveFixture("soccer/uefa.europa.conf", "soccer", now - 3600, { id: "a", name: "Braga", aliases: ["braga"] }, { id: "b", name: "F.C. København", aliases: ["copenhagen", "f c kobenhavn"] }, "", ["/live-tv-logos/art/a.png", "/live-tv-logos/art/b.png"])
    m = { version: 2, events: [f] }
    AssertEqual(ZLiveArtwork(e, m).sport, "soccer", "sport from fixture")
    AssertEqual(ZLiveArtwork(e, m).logos, ["/live-tv-logos/art/b.png", "/live-tv-logos/art/a.png"], "crests follow title order")
    AssertEqual(ZLiveArtwork(LiveWith(e, { kind: "basketball" }), m), invalid, "sport mismatch")
    AssertEqual(ZLiveArtwork(LiveWith(e, { leagueContext: "UEFA Europa League" }), m), invalid, "league mismatch")
    AssertTrue(ZLiveArtwork(LiveWith(e, { leagueContext: "UEFA Conference League" }), m) <> invalid, "league match")
    AssertEqual(ZLiveArtwork(LiveWith(e, { leagueContext: "Women Copenhagen vs Braga" }), m), invalid, "women")
    nordic = LiveWith(f, { home: { id: "b", name: "Lillestrom", aliases: ["lillestrom"] } })
    AssertTrue(ZLiveArtwork(LiveWith(e, { matchup: ["Lillestrøm", "Braga"] }), { version: 2, events: [nordic] }) <> invalid, "accents folded")
    AssertEqual(ZLiveArtwork(e, { version: 2, events: [f, LiveWith(f, { league: "basketball/nba", sport: "basketball" })] }), invalid, "two candidates")
    events = [e]
    ZLiveApplyArtwork(events, m)
    AssertEqual(events[0].kind, "soccer", "bare event takes the sport")
    AssertEqual(events[0].competition, "Soccer", "and its label")
end sub

sub Test_LiveEvents_ArtworkLeagues()
    now = 1791828000
    e = ZLiveEventFor(LiveChannel("Live: Arsenal vs. Birmingham City", { IsLive: true }), now)
    f = LiveFixture("soccer/eng.w.1", "soccer", now - 35 * 60, { id: "19968", name: "Birmingham City", aliases: ["birmingham city"] }, { id: "19973", name: "Arsenal", aliases: ["arsenal"] }, "", ["/live-tv-logos/art/birmingham-women.png", "/live-tv-logos/art/arsenal-women.png"])
    men = LiveWith(f, { league: "soccer/eng.1", home: { id: "359", name: "Arsenal", aliases: ["arsenal"] }, away: { id: "392", name: "Birmingham City", aliases: ["birmingham city"] } })
    m = { version: 2, events: [f] }
    AssertEqual(ZLiveArtwork(e, m).league, "soccer/eng.w.1", "WSL fixture")
    labelled = ZLiveEventFor(LiveChannel("Live: WSL", { IsLive: true, Overview: "Arsenal vs. Birmingham City" }), now)
    AssertEqual(labelled.kind, "soccer", "WSL is soccer")
    AssertEqual(ZLiveArtwork(labelled, m).league, "soccer/eng.w.1", "labelled WSL")
    AssertEqual(ZLiveArtwork(labelled, { version: 2, events: [men] }), invalid, "men's fixture rejected")
    AssertEqual(ZLiveArtwork(LiveWith(e, { leagueContext: "Premier League" }), m), invalid, "league mismatch")
    AssertEqual(ZLiveArtwork(LiveWith(e, { leagueContext: "WSL U21" }), m), invalid, "youth")
    AssertEqual(ZLiveArtwork(e, { version: 2, events: [f, men] }), invalid, "competing identities")
    c = ZLiveEventFor(LiveChannel("Live: English League Championship — Alpha Team vs Beta Team", { IsLive: true, Overview: "Alpha Team hosts Beta Team." }), now)
    g = LiveFixture("soccer/eng.2", "soccer", now - 3600, { id: "a", name: "Alpha Team", aliases: ["alpha team"] }, { id: "b", name: "Beta Team", aliases: ["beta team"] }, "/live-tv-logos/art/championship.jpg", [])
    AssertEqual(ZLiveArtwork(c, { version: 2, events: [g] }).image, "/live-tv-logos/art/championship.jpg", "event photo")
    AssertEqual(ZLiveArtwork(c, { version: 2, events: [LiveWith(g, { league: "soccer/eng.1" })] }), invalid, "other league")
    AssertEqual(ZLiveArtUrl("https://media.example.com/", g.image), "https://media.example.com/web/zorofin/live-tv-logos/art/championship.jpg", "art url")
end sub


sub Test_LiveEvents_FeedMappingsOverrideGuessedCarriage()
    game = LiveWith(LiveGame(), { channels: [{ guideId: "guide-a", name: "Original slot" }], leagueName: "NBA" })
    event = { id: "a", externalId: "guide-a", channel: "Renamed channel", start: ZIsoToSeconds(game.start) }
    AssertEqual(ZLiveFeedGameIndex(event, [game]), 0, "explicit guide mapping")
    event.externalId = "other"
    event.channel = "Original slot"
    AssertEqual(ZLiveFeedGameIndex(event, [game]), 0, "original mapped name")
    event.channel = "NBA — Nets at Mavericks"
    AssertEqual(ZLiveFeedGameIndex(event, [game]), 0, "companion renamed channel")
    event.channel = "NFL — Nets at Mavericks"
    AssertEqual(ZLiveFeedGameIndex(event, [game]), -1, "wrong league")
    game.channels = []
    event.channel = "NBA — Nets at Mavericks"
    AssertEqual(ZLiveFeedGameIndex(event, [game]), -1, "empty mapping cannot invent carriage")
    game.channels = [{ channelId: "a" }]
    AssertEqual(ZLiveFeedGameIndex(event, [game]), 0, "explicit Jellyfin id")
    event.start += 86400
    AssertEqual(ZLiveFeedGameIndex(event, [game]), -1, "different day")
end sub

sub Test_LiveEvents_AuthoritativeFeedKeepsOnlyCarriedGuideGames()
    now = 1791828000
    first = LiveChannel("Live: NBA Basketball — Nets vs Mavericks", { Overview: "Nets host Mavericks." }, { Id: "a", Name: "Sports A" })
    guessed = LiveWith(first, { Id: "guess", Name: "Sports B", UserData: { IsFavorite: true } })
    boxing = LiveChannel("Live: Boxing", invalid, { Id: "boxing" })
    future = LiveWith(LiveGame(), { id: "unmapped", start: LiveIso(now - 3600), channels: [] })
    carried = LiveWith(future, { id: "mapped", channels: [{ name: "Sports A" }], home: { name: "Dallas Mavericks", favorite: true } })
    feed = ZLiveParseFeed({ games: [future, carried], leagues: ["basketball/nba"], updatedAt: "ready", spoilerFree: true, maxGames: 20 })
    events = ZLiveSelect([guessed, first, boxing], now, false)
    AssertEqual(events.count(), 3, "retain alternate guide channels before matching")
    out = ZLiveArrange(events, feed)
    AssertEqual(out.count(), 2, "carried game plus uncovered boxing")
    AssertEqual(out[0].id, "a", "uses feed channel rather than a guessed favorite simulcast")
    AssertTrue(out[0].favoriteTeam, "server favorite flag")
    AssertTrue(out[0].score = invalid, "spoiler-free even with score fields")
    AssertEqual(out[1].id, "boxing", "other sport after feed games")
    feed.games = []
    AssertEqual(ZLiveArrange(events, feed)[0].id, "boxing", "empty feed drops covered league only")
    AssertEqual(ZLiveArrange([], feed).count(), 0, "no invented games without guide channels")
    AssertEqual(ZLiveArrange(events, invalid).count(), 3, "no feed keeps guide-only events")
end sub

sub Test_LiveEvents_FeedCapAndOrder()
    games = []
    events = []
    for i = 1 to 35
        id = i.toStr()
        game = LiveWith(LiveGame(), { id: id, channels: [{ channelId: id }] })
        games.push(game)
        events.push({ id: id, channel: "Channel " + id, start: ZIsoToSeconds(game.start), matchup: invalid, leagueContext: "NBA Basketball", name: id, finish: 0, kind: "basketball" })
    end for
    feed = ZLiveParseFeed({ games: games, updatedAt: "ready", maxGames: 30 })
    out = ZLiveArrange(events, feed)
    AssertEqual(out.count(), 30, "server cap above twenty")
    AssertEqual(out[29].id, "30", "retains feed order")
    feed.games = [games[1], games[0]]
    AssertEqual(ZLiveArrange(events, feed)[0].id, "2", "server order beats client NBA/favorite ranking")
end sub

sub Test_LiveEvents_ArtworkOnlyDecorates()
    now = 1791828000
    event = ZLiveEventFor(LiveChannel("Live: NFL Football", { Overview: "The Rams host the Bills." }), now)
    f = LiveFixture("football/nfl", "football", now - 3600, { id: "b", aliases: ["bills"] }, { id: "r", aliases: ["rams"] }, "", ["/live-tv-logos/art/bills.png", "/live-tv-logos/art/rams.png"])
    events = [event]
    ZLiveApplyArtwork(events, { version: 2, events: [f] }, false)
    AssertEqual(events.count(), 1, "art cannot add games")
    AssertEqual(event.name, "NFL Football", "art cannot supply game identity")
    AssertTrue(event.artwork <> invalid, "art may still decorate")
    ZLiveApplyArtwork(events, invalid, false)
    AssertEqual(events.count(), 1, "404 artwork never removes game")
end sub

sub Test_LiveEvents_RepeatedGuideArt()
    a = LiveChannel("a", { ImageTags: { Thumb: "presenter", Primary: "game1" } })
    b = LiveChannel("b", { ImageTags: { Thumb: "presenter" } })
    repeats = ZLiveRepeatedProgramArt([{id:"a"}, {id:"b"}], { a:a, b:b })
    AssertEqual(ZLiveProgramImage(a, repeats).tag, "game1", "use distinct programme image")
    AssertTrue(ZLiveProgramImage(b, repeats) = invalid, "shared presenter falls back to channel logo")
    AssertEqual(ZLiveProgramImage(b).tag, "presenter", "On now still uses its own guide")
end sub

sub Test_LiveEvents_SportIllustration()
    AssertEqual(ZLiveSportArt("basketball"), "pkg:/images/sports/live-sport-basketball.jpg", "basketball illustration")
    AssertEqual(ZLiveSportArt("event"), "pkg:/images/sports/live-sport-event.jpg", "generic live illustration")
    AssertEqual(ZLiveSportArt("curling"), "pkg:/images/sports/live-sport-event.jpg", "unknown sport uses the generic one")
end sub

sub Test_LiveEvents_UnmappedFeedGameMatchesByTeams()
    now = 1791828000
    ' The companion found the game but mapped no channel (as Aston Villa vs
    ' Galatasaray on Nov 24): web, Apple and Flutter still show it by teams.
    slot = LiveChannel("Live: NBA Basketball — Nets vs Mavericks", { Overview: "Nets host Mavericks." }, { Id: "slot", Name: "Event 1" })
    game = LiveWith(LiveGame(), { id: "g", start: LiveIso(now - 1800), channels: [], score: { home: "88", away: "79" } })
    feed = ZLiveParseFeed({ games: [game], leagues: ["basketball/nba"], updatedAt: "ready", maxGames: 20 })
    events = ZLiveSelect([slot], now, false)
    AssertEqual(events.count(), 1, "guide event")
    AssertTrue(events[0].matchup <> invalid, "guide matchup")
    AssertEqual(ZLiveGameIndex(events[0], [game]), 0, "teams match")
    out = ZLiveArrange(events, feed)
    AssertEqual(out.count(), 1, "unmapped game kept by its teams")
    AssertTrue(out[0].score <> invalid, "and it carries the score")
end sub
