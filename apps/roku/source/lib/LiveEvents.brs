' Live now: playable guide events, filtered/ordered by the advertised
' companion feed. Artwork never supplies additional games.
' Pure functions; times are epoch seconds.

function ZLiveRules() as object
    if m.zLiveRules <> invalid then return m.zLiveRules
    r = function(pattern as string) as object
        return CreateObject("roRegex", pattern, "i")
    end function
    m.zLiveRules = {
        nonWord: CreateObject("roRegex", "[^a-z0-9]+", ""),
        versus: r("\s+(?:vs\.?|v\.?|versus|at)\s+"),
        notTeam: r("\b(?:[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)|afc (?:east|west|north|south)|nfc (?:east|west|north|south)|\d*news)\b"),
        clock: r("^\d+(?::\d+)?(?:\s*(?:am|pm))?$"),
        livePrefix: r("^live\s*:\s*"),
        placeholder: r("^(?:[a-z]{2,6}\||threadfin:)"),
        threadfin: r("^threadfin:"),
        studio: r("\b(sportscenter|sports centre|first take|the herd|jim rome|foxworth|schrager|finebaum|tiki|tierney|sec now|b1g live|mlb (?:now|tonight)|nba today|nfl live|acc pm|matchday live|premier league live|countdown|overreaction|pregame|pre-game|postgame|post-game|highlights?|replays?|rewind|classics?|review|yankeeography|in 60|encore|paid programming|goal zone|mlb central|leadoff|closer|learning center|preview)\b"),
        discussion: r("\b(?:discussion and analysis|debate show|news and (?:information|updates)|sports (?:news|stories|topics)|rotating panelists|preview show|studio analysis|highlights of|replay of|rebroadcast|delayed coverage)\b"),
        notEvent: r("\b(?:news|talk show|documentary)\b"),
        otherEvent: r("\b(olympics?|opening ceremony|closing ceremony|awards|concert|festival|marathon|rugby|volleyball|swimming|cycling|athletics|track and field)\b"),
        cfl: r("\b(cfl|canadian football league)\b"),
        digits: CreateObject("roRegex", "^\d{1,3}$", ""),
        hex: r("^#[0-9a-f]{6}$"),
        art: CreateObject("roRegex", "^/live-tv-logos/art/[a-z0-9][a-z0-9-]*\.(?:png|jpe?g|webp)$", ""),
        sports: [
            { kind: "soccer", re: r("\b(soccer|premier league|efl championship|english league championship|english championship|uefa|champions league|europa league|conference league|la liga|bundesliga|serie a|mls|nwsl|wsl|women['’]?s super league|fifa|concacaf|copa|ligue 1)\b") },
            { kind: "football", re: r("\b(football|nfl|cfl|super bowl)\b") },
            { kind: "basketball", re: r("\b(basketball|nba|wnba|fiba|euroleague)\b") },
            { kind: "baseball", re: r("\b(baseball|mlb|world series)\b") },
            { kind: "hockey", re: r("\b(hockey|nhl)\b") },
            { kind: "cricket", re: r("\b(cricket|ipl)\b") },
            { kind: "tennis", re: r("\b(tennis|atp|wta|wimbledon|roland garros)\b") },
            { kind: "golf", re: r("\b(golf|pga|lpga|ryder cup)\b") },
            { kind: "racing", re: r("\b(formula (?:1|one)|f1|nascar|indycar|grand prix|motogp)\b") },
            { kind: "combat", re: r("\b(ufc|boxing|mma|wwe|wrestling)\b") }
        ],
        leagues: [
            { league: "unsupported", re: r("\b(college|ncaa|youth|under \d+|u\d{2}|u \d{2}|cfl|canadian|cricket|wnba|nwsl)\b") },
            { league: "soccer/eng.w.1", re: r("\b(wsl|women(?: s|s)? super league)\b") },
            { league: "unsupported", re: r("\b(women|womens|female)\b") },
            { league: "football/nfl", re: r("\b(nfl|super bowl)\b") },
            { league: "basketball/nba", re: r("\bnba\b") },
            { league: "baseball/mlb", re: r("\bmlb\b") },
            { league: "hockey/nhl", re: r("\bnhl\b") },
            { league: "soccer/uefa.europa.conf", re: r("\bconference league\b") },
            { league: "soccer/uefa.europa", re: r("\beuropa league\b") },
            { league: "soccer/uefa.champions", re: r("\b(champions league|uefa champions)\b") },
            { league: "soccer/ita.1", re: r("\b(serie a|italian soccer)\b") },
            { league: "soccer/fra.1", re: r("\b(ligue 1|french soccer)\b") },
            { league: "unsupported", re: r("\bscottish\b") },
            { league: "soccer/eng.1", re: r("\b(premier league|epl)\b") },
            { league: "soccer/eng.2", re: r("\b(efl championship|english league championship|english championship)\b") }
        ],
        priority: { football: 0, basketball: 1, soccer: 2, baseball: 3, hockey: 4, cricket: 5, tennis: 6, golf: 7, racing: 8, combat: 9, event: 10 },
        labels: { football: "Football", basketball: "Basketball", soccer: "Soccer", baseball: "Baseball", hockey: "Hockey", cricket: "Cricket", tennis: "Tennis", golf: "Golf", racing: "Motorsport", combat: "Fight night", event: "Live event" },
        folds: { "á": "a", "à": "a", "â": "a", "ä": "a", "ã": "a", "å": "a", "ç": "c", "é": "e", "è": "e", "ê": "e", "ë": "e", "í": "i", "ì": "i", "î": "i", "ï": "i", "ñ": "n", "ó": "o", "ò": "o", "ô": "o", "ö": "o", "õ": "o", "ø": "o", "ú": "u", "ù": "u", "û": "u", "ü": "u", "ý": "y", "ÿ": "y", "æ": "ae", "ß": "ss", "ł": "l", "š": "s", "ž": "z", "č": "c", "ć": "c", "ğ": "g", "ş": "s", "ı": "i" }
    }
    return m.zLiveRules
end function

' Lower case, accents folded, every run of other characters one space.
function ZLiveNormalized(value as dynamic) as string
    rules = ZLiveRules()
    text = LCase(ZStr(value))
    folded = ""
    plain = true
    for i = 0 to Len(text) - 1
        if Asc(Mid(text, i + 1, 1)) > 127 then plain = false
    end for
    if plain then
        folded = text
    else
        for i = 1 to Len(text)
            ch = Mid(text, i, 1)
            swap = rules.folds[ch]
            if swap <> invalid then ch = swap
            folded = folded + ch
        end for
    end if
    return rules.nonWord.replaceAll(folded, " ").trim()
end function

' "Nets at Mavericks" -> ["Nets", "Mavericks"]; invalid unless two teams.
function ZLiveTeams(value as dynamic) as dynamic
    rules = ZLiveRules()
    parts = rules.versus.split(ZStr(value))
    if parts.count() <> 2 then return invalid
    pair = []
    for each part in parts
        if Len(ZLiveNormalized(part)) <= 2 or rules.notTeam.isMatch(part) or rules.clock.isMatch(part.trim()) then return invalid
        pair.push(part)
    end for
    return pair
end function

' Splits on the exact " — " separator (tokenize splits on characters).
function ZLiveSplitExact(text as string) as object
    sep = " — "
    parts = []
    rest = text
    at = Instr(1, rest, sep)
    while at > 0
        parts.push(Left(rest, at - 1))
        rest = Mid(rest, at + Len(sep))
        at = Instr(1, rest, sep)
    end while
    parts.push(rest)
    return parts
end function

' Drops an enrichment suffix ("— A At B") unless the guide's own text
' names both teams: a scoreboard alone doesn't prove which game airs.
function ZLiveCleanTitle(name as dynamic, overview as dynamic, episodeTitle as dynamic) as string
    rules = ZLiveRules()
    title = rules.livePrefix.replaceAll(ZStr(name).trim(), "")
    parts = ZLiveSplitExact(title)
    if parts.count() > 1 then
        pair = ZLiveTeams(parts[parts.count() - 1])
        keep = pair <> invalid
        if keep then
            evidence = " " + ZLiveNormalized(ZStr(overview) + " " + ZStr(episodeTitle)) + " "
            names = [pair[0], pair[1]]
            if Len(names[1]) > Len(names[0]) then names = [pair[1], pair[0]]
            for each team in names
                needle = " " + ZLiveNormalized(team) + " "
                at = Instr(1, evidence, needle)
                if at = 0 then
                    keep = false
                    exit for
                end if
                evidence = Left(evidence, at - 1) + " " + Mid(evidence, at + Len(needle))
            end for
        end if
        if not keep then parts.pop()
    end if
    return ZJoin(parts, " — ")
end function

function ZLiveSport(title as string, genres as dynamic) as string
    text = title
    if ZIsArray(genres) then
        for each g in genres
            text = text + " " + ZStr(g)
        end for
    end if
    for each s in ZLiveRules().sports
        if s.re.isMatch(text) then return s.kind
    end for
    return "event"
end function

' The ESPN league path a guide title names, "unsupported", or "".
function ZLiveLeague(text as dynamic) as string
    t = ZLiveNormalized(text)
    for each l in ZLiveRules().leagues
        if l.re.isMatch(t) then return l.league
    end for
    return ""
end function

function ZLiveGenres(p as object) as string
    out = ""
    if ZIsArray(p.Genres) then
        for each g in p.Genres
            out = out + " " + ZStr(g)
        end for
    end if
    return out
end function

' One Live TV channel JSON (with CurrentProgram) -> an event, or invalid
' when it isn't a live sports or event broadcast airing now.
function ZLiveEventFor(channel as dynamic, now as integer) as dynamic
    if not ZIsMap(channel) then return invalid
    p = channel.CurrentProgram
    if not ZIsMap(p) then return invalid
    rules = ZLiveRules()
    start = ZIsoToSeconds(p.StartDate)
    finish = ZIsoToSeconds(p.EndDate)
    rawName = ZStr(p.Name)
    if ZStr(channel.Id) = "" or rawName = "" or start <= 0 or finish <= 0 or start > now or finish <= now or finish - start > 12 * 3600 then return invalid
    if p.IsRepeat = true or p.IsLive = false then return invalid
    if not (p.IsLive = true or rules.livePrefix.isMatch(rawName)) then return invalid
    overview = ZStr(p.Overview)
    name = ZLiveCleanTitle(rawName, overview, p.EpisodeTitle)
    parts = ZLiveSplitExact(name)
    base = parts[0]
    if rules.placeholder.isMatch(base) or rules.threadfin.isMatch(overview) or ZLiveNormalized(base) = ZLiveNormalized(channel.Name) then return invalid
    if rules.studio.isMatch(base) or rules.discussion.isMatch(overview) or rules.notEvent.isMatch(base) then return invalid
    kind = ZLiveSport(base, p.Genres)
    featured = false
    if ZIsArray(p.Genres) then
        for each genre in p.Genres
            if LCase(ZStr(genre).trim()) = "featured live event" then featured = true
        end for
    end if
    if not featured and kind = "event" and ZLiveTeams(base) = invalid and not rules.otherEvent.isMatch(base) then return invalid
    genres = ZLiveGenres(p)
    priority = rules.priority[kind]
    ' NBA games lead the row; CFL sits after soccer.
    if kind = "basketball" and ZLiveLeague(base + genres) = "basketball/nba" then priority = -1
    if kind = "football" and rules.cfl.isMatch(base) then priority = 2.5
    if featured then priority = -100
    if parts.count() > 1 then
        matchup = ZLiveTeams(parts[parts.count() - 1])
    else
        matchup = ZLiveTeams(base)
    end if
    title = name
    competition = rules.labels[kind]
    if matchup <> invalid then
        title = matchup[0] + " vs " + matchup[1]
        if parts.count() > 1 then competition = base
    end if
    return {
        id: ZStr(channel.Id), externalId: ZStr(channel.ExternalId), programId: ZStr(p.Id), name: title, competition: competition,
        kind: kind, priority: priority, start: start, finish: finish,
        channel: ZStr(channel.Name, "Live TV"), number: ZStr(channel.ChannelNumber),
        favorite: ZBool(ZGet(channel, "UserData", "IsFavorite")), favoriteTeam: false,
        matchup: matchup, context: base, leagueContext: base + genres, score: invalid,
        evidence: overview + " " + ZStr(p.EpisodeTitle)
    }
end function

function ZLiveBefore(a as object, b as object) as boolean
    if a.priority <> b.priority then return a.priority < b.priority
    if a.favorite <> b.favorite then return a.favorite
    if a.start <> b.start then return a.start < b.start
    return LCase(a.channel) < LCase(b.channel)
end function

' Live events across the channels, in sport order (NBA first), favorite
' channels first within a sport, simulcasts of one named game merged.
function ZLiveSelect(channels as dynamic, now as integer, deduplicate = true as boolean) as object
    events = []
    if not ZIsArray(channels) then return events
    for each c in channels
        e = ZLiveEventFor(c, now)
        if e <> invalid then
            ' Insertion sort: a guide has at most a few dozen live events.
            i = events.count()
            events.push(e)
            while i > 0 and ZLiveBefore(e, events[i - 1])
                events[i] = events[i - 1]
                i = i - 1
            end while
            events[i] = e
        end if
    end for
    if not deduplicate then return events
    seen = {}
    out = []
    for each e in events
        if e.matchup = invalid then
            out.push(e)
        else
            key = e.kind + ":" + ZLiveNormalized(e.name) + ":" + e.start.toStr() + ":" + e.finish.toStr()
            if not seen.doesExist(key) then
                seen[key] = true
                out.push(e)
            end if
        end if
    end for
    return out
end function

' Whether a guide team name means this side of a feed game.
function ZLiveSameTeam(guide as dynamic, side as dynamic) as boolean
    g = ZLiveNormalized(guide)
    if g = "" or not ZIsMap(side) then return false
    for each value in [side.name, side.short]
        v = ZLiveNormalized(value)
        if v <> "" then
            if g = v then return true
            if Len(g) > 3 and (Right(v, Len(g) + 1) = " " + g or Right(g, Len(v) + 1) = " " + v) then return true
        end if
    end for
    return ZLiveNormalized(side.abbreviation) = g
end function

' Index of the feed game this event shows, or -1. Both teams must name the
' same game (from the title or an event channel named "League — A At B"),
' or the companion matched the game to this channel; the game starts within
' six hours of the listing.
function ZLiveGameIndex(event as object, games as dynamic) as integer
    if not ZIsArray(games) then return -1
    named = ZLiveSplitExact(ZStr(event.channel))
    channel = ZLiveNormalized(event.channel)
    pairs = []
    if event.matchup <> invalid then pairs.push(event.matchup)
    if named.count() > 1 then
        fromName = ZLiveTeams(named[named.count() - 1])
        if fromName <> invalid then pairs.push(fromName)
    end if
    for i = 0 to games.count() - 1
        game = games[i]
        if ZIsMap(game) and ZIsMap(game.home) and ZIsMap(game.away) then
            start = ZIsoToSeconds(game.start)
            if start > 0 and Abs(start - event.start) <= 6 * 3600 then
                for each pair in pairs
                    a = pair[0]
                    b = pair[1]
                    aHome = ZLiveSameTeam(a, game.home)
                    aAway = ZLiveSameTeam(a, game.away)
                    bHome = ZLiveSameTeam(b, game.home)
                    bAway = ZLiveSameTeam(b, game.away)
                    if (aHome or aAway) and (bHome or bAway) and not (aHome and bHome) and not (aAway and bAway) then return i
                end for
                if channel <> "" and ZIsArray(game.channels) then
                    for each c in game.channels
                        if ZIsMap(c) and ZLiveNormalized(c.name) = channel then return i
                    end for
                end if
            end if
        end if
    end for
    return -1
end function

' Roku colour for a team edge; very dark colours (Nets black) would vanish.
function ZLiveTeamColor(value as dynamic) as string
    c = ZStr(value)
    if not ZLiveRules().hex.isMatch(c) then return ""
    n = Val(Mid(c, 2), 16)
    r = Int(n / 65536)
    g = Int(n / 256) mod 256
    b = n mod 256
    if (r * 299 + g * 587 + b * 114) / 1000 < 40 then return "0xD9DEDBFF"
    return "0x" + UCase(Mid(c, 2)) + "FF"
end function

function ZLiveScore(event as object, games as dynamic) as dynamic
    at = ZLiveGameIndex(event, games)
    if at < 0 then return invalid
    game = games[at]
    return ZLiveGameScore(game)
end function

function ZLiveGameScore(game as object, spoilerFree = false as boolean) as dynamic
    if spoilerFree or not ZIsMap(game.score) or game.state = "pre" then return invalid
    home = ZStr(game.score.home)
    away = ZStr(game.score.away)
    rules = ZLiveRules()
    if not rules.digits.isMatch(home) or not rules.digits.isMatch(away) then return invalid
    ' Soccer is written home first ("Arsenal 1–0 Dortmund"), matching the match
    ' art, which puts the home crest on the left; US sports stay away first.
    a = game.away
    h = game.home
    if ZStr(game.sport) = "soccer" then
        a = game.home
        h = game.away
        t = away
        away = home
        home = t
    end if
    return {
        away: ZLiveLabel(a), awayScore: away, home: ZLiveLabel(h), homeScore: home,
        detail: Left(ZStr(game.detail), 40), final: game.state = "post", live: game.state = "in",
        league: Left(ZStr(game.leagueName), 24),
        awayName: Left(ZStr(a.short, ZStr(a.name)), 24),
        homeName: Left(ZStr(h.short, ZStr(h.name)), 24),
        awayColor: ZLiveTeamColor(a.color), homeColor: ZLiveTeamColor(h.color)
    }
end function

function ZLiveLabel(side as object) as string
    label = ZStr(side.abbreviation)
    if label = "" then label = ZStr(side.short)
    if label = "" then label = ZStr(side.name)
    return Left(label, 12)
end function

' The companion feed body -> { games, leagues }, or invalid before the
' companion's first scoreboard read (updatedAt null).
function ZLiveParseFeed(body as dynamic) as dynamic
    if not ZIsMap(body) or not ZIsArray(body.games) or ZStr(body.updatedAt) = "" then return invalid
    games = []
    for each g in body.games
        if ZIsMap(g) and ZIsMap(g.home) and ZIsMap(g.away) then games.push(g)
    end for
    leagues = []
    if ZIsArray(body.leagues) then leagues = body.leagues
    return { games: games, leagues: leagues, spoilerFree: body.spoilerFree = true, maxGames: Int(ZClamp(ZNum(body.maxGames, 100), 1, 100)) }
end function

' A companion mapping must name this visible guide channel. Prefer explicit
' identity; accept original names or the companion's renamed league/team slot.
' Do not infer carriage merely from a broadcaster or an artwork match.
function ZLiveFeedGameIndex(event as object, games as object) as integer
    for i = 0 to games.count() - 1
        game = games[i]
        if Abs(ZIsoToSeconds(game.start) - event.start) <= 6 * 3600 then
            if not ZIsArray(game.channels) then
                ' Older feed variants had no channel mappings.
                if ZLiveGameIndex(event, [game]) = 0 then return i
            else if game.channels.count() > 0 then
                for each ref in game.channels
                    if ZIsMap(ref) then
                        if ZStr(ref.id) <> "" and ZStr(ref.id) = ZStr(event.id) then return i
                        if ZStr(ref.channelId) <> "" and ZStr(ref.channelId) = ZStr(event.id) then return i
                        if ZStr(ref.guideId) <> "" and ZStr(ref.guideId) = ZStr(event.externalId) then return i
                        if ZLiveNormalized(ref.name) <> "" and ZLiveNormalized(ref.name) = ZLiveNormalized(event.channel) then return i
                    end if
                end for
                named = ZLiveSplitExact(ZStr(event.channel))
                if named.count() = 2 and ZLiveNormalized(named[0]) = ZLiveNormalized(game.leagueName) then
                    pair = ZLiveTeams(named[1])
                    if pair <> invalid then
                        if (ZLiveSameTeam(pair[0], game.home) and ZLiveSameTeam(pair[1], game.away)) or (ZLiveSameTeam(pair[0], game.away) and ZLiveSameTeam(pair[1], game.home)) then return i
                    end if
                end if
            end if
        end if
    end for
    return -1
end function

' With the feed, the row follows the operator's settings: feed order (Live
' now order, favorite teams), its length and its leagues. Games the feed
' covers but left out are dropped; events it can't know (boxing, college)
' keep their order after them.
function ZLiveArrange(events as object, feed as dynamic) as object
    if feed = invalid or not ZIsArray(feed.games) then return events
    games = feed.games
    matched = []
    others = []
    ' Explicit companion carriage first. A game the companion left unmapped can
    ' still match by both teams, as on web, Apple and Flutter (gameIndexFor),
    ' unless another visible channel is the mapped home of that same game.
    strict = []
    mappedGames = {}
    for each event in events
        at = ZLiveFeedGameIndex(event, games)
        strict.push(at)
        if at >= 0 then mappedGames[ZLiveGameKey(games[at])] = true
    end for
    for k = 0 to events.count() - 1
        event = events[k]
        at = strict[k]
        if at < 0 then
            for i = 0 to games.count() - 1
                if ZLiveGameIndex(event, [games[i]]) = 0 and not mappedGames.doesExist(ZLiveGameKey(games[i])) then
                    at = i
                    exit for
                end if
            end for
        end if
        if at >= 0 then
            game = games[at]
            event.favoriteTeam = ZBool(game.home.favorite) or ZBool(game.away.favorite)
            title = ZStr(game.title)
            if event.matchup = invalid and Len(title) >= 3 and Len(title) <= 80 and Instr(1, title, "<") = 0 and Instr(1, title, ">") = 0 then event.name = title
            event.score = ZLiveGameScore(game, feed.spoilerFree = true)
            ' A guide listing without sport words takes the matched game's sport
            ' and competition, as the web does.
            sport = ZStr(game.sport)
            if ZStr(event.kind, "event") = "event" and sport <> "" and sport <> "event" and ZLiveRules().labels.doesExist(sport) then
                event.kind = sport
                if ZStr(game.competition) <> "" then event.competition = ZStr(game.competition)
            end if
            i = matched.count()
            entry = { at: at, event: event }
            matched.push(entry)
            while i > 0 and matched[i - 1].at > at
                matched[i] = matched[i - 1]
                i = i - 1
            end while
            matched[i] = entry
        else if not ZContains(feed.leagues, ZLiveLeague(event.leagueContext)) then
            others.push(event)
        end if
    end for
    out = []
    seen = {}
    limit = Int(ZClamp(ZNum(feed.maxGames, 100), 1, 100))
    for each entry in matched
        key = entry.at.toStr()
        if not seen.doesExist(key) then
            seen[key] = true
            out.push(entry.event)
            if out.count() >= limit then return out
        end if
    end for
    ' Merge other live simulcasts without consulting the private artwork file.
    seen = {}
    for each event in others
        key = ZStr(event.id)
        if event.matchup <> invalid then key = event.kind + ":" + ZLiveNormalized(event.name) + ":" + event.start.toStr() + ":" + event.finish.toStr()
        if not seen.doesExist(key) then
            seen[key] = true
            out.push(event)
            if out.count() >= limit then exit for
        end if
    end for
    return out
end function

' One real game, however many feed entries or slots list it.
function ZLiveGameKey(game as object) as string
    return ZLiveNormalized(ZStr(game.home.name)) + "|" + ZLiveNormalized(ZStr(game.away.name)) + "|" + Left(ZStr(game.start), 13)
end function

' Under a scored card: "NBA · Q3 4:12" or "NBA · Final" ("" without a score).
function ZLiveStatus(score as dynamic, competition = "" as string) as string
    if score = invalid then return ""
    state = score.detail
    if score.final and state = "" then state = "Final"
    if not score.final and state = "" then state = "Live"
    ' The feed's league name ("NBA") reads better than the guide's title.
    league = ZStr(score.league)
    if league = "" then league = competition.trim()
    if league = "" then return state
    return league + " · " + state
end function

' "Your teams · ESPN · Ch 206" or "ESPN · Ch 206".
function ZLiveChannelLine(channel as string, number as string, favoriteTeam as boolean) as string
    line = channel
    if number <> "" then line = line + " · Ch " + number
    if favoriteTeam then line = "Your teams · " + line
    return line
end function

' The fallback card tint for a scored game without art: a team colour
' darkened like the site's (0x1E3A5F without colours).
function ZLiveTint(score as object) as string
    c = score.homeColor
    if c = "" then c = score.awayColor
    if Len(c) <> 10 then return "0x1E3A5FFF"
    n = Val(Mid(c, 3, 6), 16)
    out = "0x"
    for each shift in [65536, 256, 1]
        part = Int((Int(n / shift) mod 256) * 0.45 + 0.5)
        out = out + UCase(Right("0" + StrI(part, 16), 2))
    end for
    return out + "FF"
end function

' The programme's own guide image ({ item, kind, tag }), as the Apple apps
' use it: Thumb, then Backdrop, then Primary. Jellyfin can copy the channel
' logo onto the programme; a tag shared with the channel is the logo, not a
' picture of the event, so it's skipped. invalid when there's none.
function ZLiveProgramImage(channel as dynamic, excluded = invalid as dynamic) as dynamic
    if not ZIsMap(channel) or not ZIsMap(channel.CurrentProgram) then return invalid
    p = channel.CurrentProgram
    id = ZStr(p.Id)
    if id = "" or id = ZStr(channel.Id) then return invalid
    own = {}
    if ZIsMap(channel.ImageTags) then
        for each k in channel.ImageTags
            own[ZStr(channel.ImageTags[k])] = true
        end for
    end if
    for each list in [channel.BackdropImageTags, channel.ParentBackdropImageTags]
        if ZIsArray(list) then
            for each t in list
                own[ZStr(t)] = true
            end for
        end if
    end for
    if excluded <> invalid then own.append(excluded)
    backdrop = invalid
    if ZIsArray(p.BackdropImageTags) and p.BackdropImageTags.count() > 0 then backdrop = p.BackdropImageTags[0]
    safe = CreateObject("roRegex", "^[A-Za-z0-9_-]{1,64}$", "")
    for each pair in [["Thumb", ZGet(p, "ImageTags", "Thumb")], ["Backdrop", backdrop], ["Primary", ZGet(p, "ImageTags", "Primary")]]
        tag = ZStr(pair[1]).trim()
        if tag <> "" and not own.doesExist(tag) and safe.isMatch(tag) then return { item: id, kind: pair[0], tag: tag }
    end for
    return invalid
end function

' Art reused across separate sports cards is usually a network graphic.
function ZLiveRepeatedProgramArt(events as object, byId as object) as object
    seen = {}
    repeated = {}
    for each event in events
        image = ZLiveProgramImage(byId[event.id])
        if image <> invalid then
            if seen.doesExist(image.tag) then repeated[image.tag] = true
            seen[image.tag] = true
        end if
    end for
    return repeated
end function

' Fixture artwork from the server's catalogue (GET /web/zorofin/live-tv-logos/
' art/events.json, version 2), matched as on the web (artworkDetailsFor):
' a unique fixture in the same league and sport, kicking off within three
' hours, whose two teams the guide names. -> { image, logos, teams, league,
' sport } with paths under /live-tv-logos/art/, or invalid.
function ZLiveSafeArt(path as dynamic) as boolean
    if GetInterface(path, "ifString") = invalid then return false
    return ZLiveRules().art.isMatch(path)
end function

function ZLiveArtNames(team as dynamic) as object
    out = []
    if not ZIsMap(team) or not ZIsArray(team.aliases) then return out
    for each a in team.aliases
        n = ZLiveNormalized(a)
        if Len(n) >= 3 then out.push(n)
    end for
    return out
end function

function ZLiveArtMatches(value as dynamic, team as dynamic) as boolean
    v = ZLiveNormalized(value)
    if Left(v, 4) = "the " then v = Mid(v, 5)
    return ZContains(ZLiveArtNames(team), v)
end function

' Both teams named in the guide's description, as separate mentions.
function ZLiveArtMentioned(evidence as string, a as dynamic, b as dynamic) as boolean
    for each first in ZLiveArtNames(a)
        at = Instr(1, evidence, " " + first + " ")
        if at > 0 then
            rest = Left(evidence, at - 1) + " " + Mid(evidence, at + Len(first) + 2)
            for each second in ZLiveArtNames(b)
                if Instr(1, rest, " " + second + " ") > 0 then return true
            end for
        end if
    end for
    return false
end function

function ZLiveArtwork(event as dynamic, manifest as dynamic) as dynamic
    if not ZIsMap(event) or not ZIsMap(manifest) then return invalid
    if manifest.version <> 2 or not ZIsArray(manifest.events) then return invalid
    context = ZStr(event.leagueContext)
    if context = "" then context = ZStr(event.context)
    if context = "" then context = ZStr(event.name)
    league = ZLiveLeague(context)
    if league = "unsupported" then return invalid
    labels = ZLiveRules().labels
    pair = ZIsArray(event.matchup) and event.matchup.count() = 2
    evidence = " " + ZLiveNormalized(ZStr(event.evidence)) + " "
    found = invalid
    for each f in manifest.events
        ok = ZIsMap(f) and ZIsMap(f.home) and ZIsMap(f.away)
        if ok then ok = ZStr(f.home.id) <> ZStr(f.away.id) and labels.doesExist(ZStr(f.sport)) and (league = "" or league = ZStr(f.league))
        if ok then ok = f.sport = event.kind or (event.kind = "event" and pair)
        if ok then
            kickoff = ZIsoToSeconds(ZStr(f.start))
            ok = kickoff > 0 and Abs(kickoff - event.start) <= 3 * 3600
        end if
        if ok then
            if pair then
                ok = (ZLiveArtMatches(event.matchup[0], f.away) and ZLiveArtMatches(event.matchup[1], f.home)) or (ZLiveArtMatches(event.matchup[1], f.away) and ZLiveArtMatches(event.matchup[0], f.home))
            else
                ok = ZLiveArtMentioned(evidence, f.away, f.home) or ZLiveArtMentioned(evidence, f.home, f.away)
            end if
        end if
        if ok then
            ' A generic or conflicting guide never gets an arbitrary fixture.
            if found <> invalid then return invalid
            found = f
        end if
    end for
    if found = invalid then return invalid
    image = ""
    if ZLiveSafeArt(found.image) then image = found.image
    logos = []
    if ZIsArray(found.logos) and found.logos.count() = 2 then
        if ZLiveSafeArt(found.logos[0]) and ZLiveSafeArt(found.logos[1]) then logos = [found.logos[0], found.logos[1]]
    end if
    teams = [ZStr(found.away.name), ZStr(found.home.name)]
    ' Crests follow the title's order.
    if pair then
        if ZLiveArtMatches(event.matchup[0], found.home) and ZLiveArtMatches(event.matchup[1], found.away) then
            if logos.count() = 2 then logos = [logos[1], logos[0]]
            teams = [teams[1], teams[0]]
        end if
    end if
    if image = "" and logos.count() = 0 then return invalid
    return { image: image, logos: logos, teams: teams, league: ZStr(found.league), sport: ZStr(found.sport) }
end function

' Applies matched artwork to the events (as the web row does): a bare
' "event" takes the fixture's sport, and a title without teams takes them.
sub ZLiveApplyArtwork(events as object, manifest as dynamic, decorateNames = true as boolean)
    labels = ZLiveRules().labels
    for each event in events
        art = ZLiveArtwork(event, manifest)
        event.artwork = art
        if art <> invalid and decorateNames then
            if event.kind = "event" and art.sport <> "" then
                event.kind = art.sport
                event.competition = labels[art.sport]
            end if
            if event.matchup = invalid and art.teams[0] <> "" and art.teams[1] <> "" then
                event.name = art.teams[0] + " vs " + art.teams[1]
                event.competition = ZStr(event.context)
            end if
        end if
    end for
end sub

' The catalogue address on the server ("…/web/zorofin/live-tv-logos/art/
' events.json") and an artwork path's full URL.
function ZLiveArtUrl(base as string, path as string) as string
    b = base
    if Right(b, 1) <> "/" then b = b + "/"
    return b + "web/zorofin" + path
end function

' Bundled sport illustration (exported from the Apple/web LiveSport art).
function ZLiveSportArt(kind as string) as string
    known = { football: 1, basketball: 1, soccer: 1, baseball: 1, hockey: 1, cricket: 1, tennis: 1, golf: 1, racing: 1, combat: 1, event: 1 }
    if not known.doesExist(kind) then kind = "event"
    return "pkg:/images/sports/live-sport-" + kind + ".jpg"
end function
