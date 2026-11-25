#!/usr/bin/env node
'use strict';
// A small fake Jellyfin server plus a static host for the app, for screenshot
// validation (tool/validate.cjs) and local development. No real media: artwork
// is generated SVG and /Videos/*/stream serves an empty response.
//
//   node apps/legacy-tv/tool/mock-server.cjs [appPort=8730] [apiPort=8731]
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const appDir = path.join(__dirname, '..', 'tizen');
const TICKS = 10000000;

function hash(text) { let h = 0; for (const c of String(text)) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; }

const MOVIES = ['The Long Night', 'Harbor Lights', 'Silver Coast', 'Red Canyon', 'The Quiet Hour', 'Northbound', 'Glass City',
  'Paper Moons', 'The Last Signal', 'Wild Orchard', 'Midnight Express Line', 'Copper Sky', 'Summer of Kites', 'Dust and Echoes'];
const SHOWS = ['Station Eleven Road', 'The Lighthouse Keepers', 'Kitchen Brigade', 'Orbit', 'Tidewater', 'Dispatch', 'Fieldwork',
  'Neighbours of Elm St', 'The Archive', 'Blue Hour'];

let id = 1;
const items = {};
function add(item) { item.Id = item.Id || 'i' + (id++); item.ImageTags = { Primary: 't' + hash(item.Id) }; item.BackdropImageTags = ['b' + hash(item.Id)]; items[item.Id] = item; return item; }

const movies = MOVIES.map((name, i) => add({ Name: name, Type: 'Movie', ProductionYear: 2010 + (i % 15), RunTimeTicks: (95 + i * 4) * 60 * TICKS,
  CommunityRating: 6.2 + (i % 8) * 0.4, OfficialRating: ['PG', 'PG-13', 'R'][i % 3], Genres: [['Drama', 'Thriller'], ['Comedy'], ['Sci-Fi', 'Adventure']][i % 3],
  Overview: name + ' follows a small group of people through one unforgettable week, told with warmth, sharp humour and a lot of heart.',
  UserData: { Played: i === 4, PlaybackPositionTicks: i === 1 ? 41 * 60 * TICKS : 0, PlayedPercentage: i === 1 ? 38 : 0 } }));

const shows = SHOWS.map((name, i) => {
  const series = add({ Name: name, Type: 'Series', ProductionYear: 2015 + (i % 10), Status: i % 2 ? 'Continuing' : 'Ended', CommunityRating: 7 + (i % 5) * 0.3,
    OfficialRating: 'TV-14', Genres: ['Drama'], Overview: name + ' is a character-driven series about community, ambition and second chances.',
    UserData: { UnplayedItemCount: (i * 3) % 9 } });
  series.seasons = [1, 2].map(n => add({ Name: 'Season ' + n, Type: 'Season', IndexNumber: n, SeriesId: series.Id, UserData: { Played: n === 1 && i % 2 === 0 } }));
  series.episodes = {};
  series.seasons.forEach(season => {
    series.episodes[season.Id] = [1, 2, 3, 4, 5, 6, 7, 8].map(e => add({ Name: ['Pilot', 'The Offer', 'Low Tide', 'Crossing', 'Old Friends', 'The Storm', 'Aftermath', 'Homecoming'][e - 1],
      Type: 'Episode', IndexNumber: e, ParentIndexNumber: season.IndexNumber, SeasonId: season.Id, SeriesId: series.Id, SeriesName: name,
      SeriesPrimaryImageTag: series.ImageTags.Primary, RunTimeTicks: 44 * 60 * TICKS, Overview: 'Episode ' + e + ' of ' + name + '.',
      UserData: { Played: season.IndexNumber === 1 && e < 3, PlaybackPositionTicks: season.IndexNumber === 1 && e === 3 ? 12 * 60 * TICKS : 0, PlayedPercentage: season.IndexNumber === 1 && e === 3 ? 27 : 0 } }));
  });
  return series;
});

const collections = ['Christopher Nolan', 'Fast & Furious', 'Harry Potter', 'Heist Night', 'John Wick', 'Mind-Benders', 'Studio Ghibli', 'The Lord of the Rings']
  .map((name, i) => add({ Name: name, Type: 'BoxSet', ChildCount: 3 + i }));

const CHANNELS = ['NBC Sports', 'ESPN', 'Monumental', 'CBS', 'FOX', 'ABC News', 'Food Network', 'HGTV'];
const HOUR = 3600 * 1000;
const slot = () => { const t = new Date(); t.setMinutes(t.getMinutes() < 30 ? 0 : 30, 0, 0); return t.getTime(); };
const channels = CHANNELS.map((name, i) => add({ Name: name, Type: 'TvChannel', ChannelNumber: String(101 + i) }));
channels.forEach((ch, i) => {
  ch.CurrentProgram = { Id: 'p' + i, Name: ['Wizards at Celtics', 'SportsCenter', 'Capitals Postgame', 'Evening News', 'NFL Countdown', 'World Tonight', 'Chopped', 'House Hunters'][i],
    StartDate: new Date(slot() - 20 * 60 * 1000).toISOString(), EndDate: new Date(slot() + HOUR).toISOString(), ChannelId: ch.Id };
});
const sports = [['Wizards at Celtics', 0, -0.5, 2], ['Man United vs Arsenal', 2, 3, 5], ['Commanders at Eagles', 4, 26, 29.5]].map(([name, c, s, e]) => add({
  Name: name, Type: 'Program', ChannelId: channels[c].Id, ChannelName: channels[c].Name, IsLive: true, IsSports: true,
  StartDate: new Date(slot() + s * HOUR).toISOString(), EndDate: new Date(slot() + e * HOUR).toISOString() }));
const users = {};
let pickSession = null;

const firstEpisode = s => s.episodes[s.seasons[0].Id];
const resume = [movies[1], firstEpisode(shows[0])[2], firstEpisode(shows[2])[2]];
const nextUp = shows.slice(3, 7).map(s => firstEpisode(s)[0]);

function svg(item, kind, width) {
  const h = hash(item.Id + kind), hue = h % 360, hue2 = (hue + 50) % 360;
  const wide = kind !== 'Primary' || item.Type === 'Episode';
  const w = wide ? 1280 : 600, ht = wide ? 720 : 900;
  const name = item.Type === 'Episode' && kind === 'Primary' ? item.Name : (item.SeriesName || item.Name);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${ht}" viewBox="0 0 ${w} ${ht}">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hue},45%,38%)"/><stop offset="1" stop-color="hsl(${hue2},50%,14%)"/></linearGradient></defs>
<rect width="100%" height="100%" fill="url(#g)"/><circle cx="${w * 0.72}" cy="${ht * 0.35}" r="${ht * 0.22}" fill="hsla(${hue2},60%,70%,0.25)"/>
${kind === 'Primary' && !wide ? `<text x="40" y="${ht - 70}" font-family="Arial" font-weight="700" font-size="54" fill="#fff">${String(name).replace(/&/g, '&amp;').slice(0, 18)}</text>` : ''}</svg>`;
}

function page(list, total) { return { Items: list, TotalRecordCount: total === undefined ? list.length : total }; }
function strip(item) { const { seasons, episodes, ...rest } = item; return rest; }

function api(req, res) {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname, q = url.searchParams;
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, X-Emby-Authorization, X-Jellyfin-Token, Accept, Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  const json = (data, status) => { res.writeHead(status || 200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(data)); };
  let m;
  if (p === '/System/Info/Public') return json({ Id: 'mock', ServerName: 'Mock Zorofin', Version: '10.11.0', ProductName: 'Jellyfin Server' });
  if (p === '/Users/AuthenticateByName') {
    let body = '';
    req.on('data', c => { body += c; });
    req.on('end', () => {
      const name = (JSON.parse(body || '{}').Username || 'Claude Test');
      users[name] = users[name] || 'u' + hash(name);
      json({ AccessToken: 'tok-' + users[name], User: { Id: users[name], Name: name } });
    });
    return;
  }
  if (p === '/Zorofin/Home/Rows') {
    const card = (item, subtitle, extra) => Object.assign({ id: item.Id, item: strip(item), subtitle: subtitle || '', badges: [] }, extra || {});
    return json({ schemaVersion: 1, rows: [
      { id: 'requests-ready', title: 'Your requests are ready', state: 'ready', cards: movies.slice(9, 12).map(m => card(m, 'Requested by you')) },
      { id: 'new-episodes', title: 'New episodes', state: 'ready', cards: shows.slice(0, 5).map(s => card(firstEpisode(s)[3], 'S1 E4 · New')) },
      { id: 'sports', title: 'Live sports', state: 'ready', cards: sports.map(g => card(g, g.ChannelName, { startsAt: g.StartDate, endsAt: g.EndDate })) },
      { id: 'popular', title: 'Popular on Mock Zorofin', state: 'ready', cards: movies.slice(3, 12).map(m => card(m, '')) },
      { id: 'curated', title: 'Weekend picks', state: 'empty', cards: [] }
    ] });
  }
  if (p === '/LiveTv/Channels') { const all = channels.map(strip); return json(page(all.slice(0, Number(q.get('limit') || 300)), all.length)); }
  if (/^\/MediaSegments\//.test(p)) return json(page([]));
  if (/^\/Users\/[^/]+\/Images\//.test(p)) { res.writeHead(404); return res.end(); }
  if (p === '/Zorofin/Companion/pickTogether/sessions' && req.method === 'POST') {
    pickSession = { schemaVersion: 1, id: 'a'.repeat(32), code: 'K7QX2M', kind: 'movie', status: 'lobby', round: 0, version: 1, host: true, display: true,
      members: [{ seat: 's0', name: 'Living room TV', display: true, host: true, you: true, swiped: 0, total: 0, done: false },
        { seat: 's1', name: 'Sam', display: false, swiped: 0, total: 0, done: false }, { seat: 's2', name: 'Sam', display: false, swiped: 0, total: 0, done: false }],
      voters: 2, poolSize: 0, matches: [], almost: [] };
    return json(pickSession);
  }
  if ((m = /^\/Zorofin\/Companion\/pickTogether\/sessions\/[0-9a-f]+\/?(\w[\w-]*)?$/.exec(p))) {
    if (!pickSession) return json({ error: 'not_found' }, 404);
    const action = m[1] || '';
    const describe = (mv, likes) => ({ itemId: mv.Id, type: 'Movie', title: mv.Name, year: mv.ProductionYear, runtimeMinutes: Math.round(mv.RunTimeTicks / 600000000), imageTag: mv.ImageTags.Primary, likes, of: 2 });
    if (action === 'start' || action === 'next-round') {
      pickSession = Object.assign({}, pickSession, { status: 'swiping', round: 1, version: pickSession.version + 1, poolSize: 20,
        members: pickSession.members.map((mb, i) => i ? Object.assign({}, mb, { swiped: i === 1 ? 20 : 13, total: 20, done: i === 1 }) : mb),
        matches: [describe(movies[2], 2), describe(movies[7], 2), describe(movies[10], 2)], almost: [describe(movies[5], 1), describe(movies[12], 1)] });
    }
    if (action === 'end') pickSession = Object.assign({}, pickSession, { status: 'ended', version: pickSession.version + 1 });
    if (!action && Number(q.get('since')) === pickSession.version) return json({ unchanged: true, version: pickSession.version });
    return json(pickSession);
  }
  if (p === '/QuickConnect/Initiate') return json({ Code: '482913', Secret: 's' });
  if (p === '/QuickConnect/Connect') return json({ Authenticated: false });
  if (p === '/UserItems/Resume') return json(page(resume.map(strip)));
  if (p === '/Shows/NextUp') return json(page(nextUp.map(strip)));
  if (p === '/Items/Latest') return json((q.get('includeItemTypes') || '').includes('Movie') ? movies.map(strip) : shows.map(strip));
  if ((m = /^\/Items\/([^/]+)\/Images\/(\w+)$/.exec(p))) { const it = items[m[1]]; if (!it) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'Content-Type': 'image/svg+xml', 'Cache-Control': 'max-age=3600' }); return res.end(svg(it, m[2], q.get('fillWidth'))); }
  if ((m = /^\/Items\/([^/]+)\/PlaybackInfo$/.exec(p))) return json({ PlaySessionId: 'ps', MediaSources: [{ Id: m[1], SupportsDirectPlay: true, MediaStreams: [] }] });
  if ((m = /^\/Items\/([^/]+)$/.exec(p))) return items[m[1]] ? json(strip(items[m[1]])) : json({}, 404);
  if ((m = /^\/Shows\/([^/]+)\/Seasons$/.exec(p))) return json(page(items[m[1]].seasons.map(strip)));
  if ((m = /^\/Shows\/([^/]+)\/Episodes$/.exec(p))) { const s = items[m[1]]; return json(page((s.episodes[q.get('seasonId')] || firstEpisode(s)).map(strip))); }
  if (p === '/Items') {
    const types = (q.get('includeItemTypes') || '').split(',');
    let list = [];
    if (q.get('parentId')) list = movies.slice(0, 5);
    else if (types.includes('BoxSet')) list = collections;
    else { if (types.includes('Movie')) list = list.concat(movies); if (types.includes('Series')) list = list.concat(shows); }
    const term = (q.get('searchTerm') || '').toLowerCase();
    if (term) list = list.filter(i => i.Name.toLowerCase().includes(term));
    if (q.get('sortBy') === 'CommunityRating') list = list.slice().sort((a, b) => (b.CommunityRating || 0) - (a.CommunityRating || 0));
    return json(page(list.slice(0, Number(q.get('limit') || 100)).map(strip)));
  }
  if (p.startsWith('/Sessions/') || p.startsWith('/UserPlayedItems/')) { res.writeHead(204); return res.end(); }
  if (/^\/Videos\//.test(p)) { res.writeHead(404); return res.end(); }
  json({ error: 'not mocked', path: p }, 404);
}

const TYPES = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.png': 'image/png', '.woff2': 'font/woff2' };
function app(req, res) {
  const rel = decodeURIComponent(new URL(req.url, 'http://x').pathname).replace(/^\/+/, '') || 'index.html';
  const file = path.join(appDir, rel);
  if (!file.startsWith(appDir)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}

function start(appPort, apiPort) {
  const a = http.createServer(app).listen(appPort, '127.0.0.1');
  const b = http.createServer(api).listen(apiPort, '127.0.0.1');
  return { close() { a.close(); b.close(); }, items, shows, movies };
}

module.exports = { start };
if (require.main === module) {
  const [appPort = 8730, apiPort = 8731] = process.argv.slice(2).map(Number);
  start(appPort, apiPort);
  console.log('app http://127.0.0.1:' + appPort + '  api http://127.0.0.1:' + apiPort);
}
