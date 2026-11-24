/* Zorofin for older Samsung TVs: screens (connect, sign in, Home, details,
 * search, library). ES5 only. Each screen fills Z.app.page and hands its
 * zones to a Focus; Z.app routes keys and Back. */
(function (root) {
  'use strict';

  var Z = root.Z;
  var ui = Z.ui, util = Z.util, el = ui.el;

  function app() { return Z.app; }
  function client() { return Z.app.client; }

  // ---------- shared chrome ----------

  // The header: logo, then Home / Search / Movies / Shows / Settings.
  function header(active) {
    var bar = el('header', 'topbar');
    var logo = el('img', 'topbar-logo');
    logo.src = 'wordmark.png';
    logo.alt = 'Zorofin';
    bar.appendChild(logo);
    var nav = el('nav', 'topnav');
    var tabs = [
      ['Home', function () { app().go('home', null, true); }],
      ['Search', function () { app().go('search', null, true); }],
      ['Movies', function () { app().go('library', { type: 'Movie', title: 'Movies' }, true); }],
      ['Shows', function () { app().go('library', { type: 'Series', title: 'Shows' }, true); }]
    ];
    if (app().hasLiveTv) tabs.push(['Live TV', function () { app().go('live', null, true); }]);
    var s = client().session || {};
    var name = s.userName || 'Profile';
    tabs.push([name, function () { app().openMenu(); }, 'profile']);
    var items = tabs.map(function (t) {
      var b = ui.button(t[0], 'tab' + (t[2] ? ' tab-' + t[2] : '') + (t[0] === active || (t[2] && active === t[2]) ? ' current' : ''), t[1]);
      if (t[2] === 'profile') {
        var face = avatar(s.userId, name, 'tab-avatar');
        b.insertBefore(face, b.firstChild);
      }
      nav.appendChild(b);
      return b;
    });
    bar.appendChild(nav);
    var index = 0;
    for (var i = 0; i < tabs.length; i++) if (tabs[i][0] === active || (tabs[i][2] && tabs[i][2] === active)) index = i;
    return { node: bar, zone: { items: items, kind: 'buttons', index: index } };
  }

  function status(text, isError) {
    var node = el('div', 'status' + (isError ? ' error' : ''), text);
    return node;
  }

  // A profile picture, or the first letter of the name when there is none.
  function avatar(userId, name, cls) {
    var node = el('span', 'avatar' + (cls ? ' ' + cls : ''));
    node.appendChild(el('span', 'avatar-letter', (name || '?').charAt(0).toUpperCase()));
    if (userId && client()) {
      var img = el('img', 'avatar-img');
      img.alt = '';
      img.onload = function () { node.className += ' has-img'; };
      img.onerror = function () { if (img.parentNode) img.parentNode.removeChild(img); };
      img.src = client().userImage(userId, 240);
      node.appendChild(img);
    }
    return node;
  }

  function clock(date) {
    var h = date.getHours(), m = date.getMinutes();
    return (h % 12 || 12) + ':' + (m < 10 ? '0' : '') + m + (h < 12 ? ' AM' : ' PM');
  }

  // "Live now" or a start time, for sports and programmes.
  function airLabel(startsAt, endsAt) {
    var start = startsAt ? new Date(startsAt) : null, end = endsAt ? new Date(endsAt) : null;
    var now = new Date();
    if (start && start <= now && (!end || end > now)) return 'Live now';
    if (!start || isNaN(start.getTime())) return '';
    var today = start.toDateString() === now.toDateString();
    return (today ? 'Today ' : ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][start.getDay()] + ' ') + clock(start);
  }

  // A live channel as something the player can open.
  function channelOf(item) {
    if (item.Type === 'TvChannel') return item;
    return { Id: item.ChannelId, Type: 'TvChannel', Name: item.ChannelName || item.Name, CurrentProgram: item, ImageTags: {} };
  }

  function errorText(err) {
    if (!err) return '';
    if (err.status === 401) return 'Your sign-in expired. Sign in again.';
    if (err.message === 'network' || err.message === 'timeout') return 'Couldn’t reach your server. Check the TV’s internet connection.';
    return 'Something went wrong (' + (err.status || err.message) + ').';
  }

  function openItem(item) {
    if (item.Type === 'TvChannel' || ((item.Type === 'Program' || item.IsLive) && item.ChannelId)) return app().play(channelOf(item));
    if (item.Type === 'Episode' || item.Type === 'Movie' || item.Type === 'Video') {
      if (item.Type === 'Episode') return app().go('details', { id: item.SeriesId, episodeId: item.Id, seasonId: item.SeasonId });
      return app().go('details', { id: item.Id });
    }
    if (item.Type === 'BoxSet' || item.Type === 'CollectionFolder' || item.Type === 'Folder') return app().go('library', { parentId: item.Id, title: item.Name });
    app().go('details', { id: item.Id });
  }

  // ---------- connect ----------

  var connect = {
    render: function (page, params) {
      var panel = el('section', 'panel');
      panel.appendChild(el('h1', '', 'Connect to your server'));
      panel.appendChild(el('p', 'muted', 'Type your Zorofin or Jellyfin server address, for example myserver.com or 192.168.1.20:8096.'));
      var input = el('input', 'field');
      input.type = 'text';
      input.setAttribute('autocomplete', 'off');
      input.setAttribute('spellcheck', 'false');
      input.placeholder = 'Server address';
      input.value = (params && params.prefill || '').replace(/^https?:\/\//, '');
      var go = ui.button('Connect', 'primary wide');
      var note = status('');
      var busy = false;
      input.activate = function () { input.focus(); };
      go.activate = function () {
        if (busy) return;
        var list = util.candidates(input.value);
        if (!list.length) { note.textContent = 'Type your server address first.'; note.className = 'status error'; return; }
        busy = true;
        note.className = 'status';
        note.textContent = 'Checking ' + list[0].replace(/^https?:\/\//, '') + '…';
        (function next(i) {
          if (i >= list.length) {
            busy = false;
            note.className = 'status error';
            note.textContent = 'Couldn’t reach a Jellyfin server there. Check the address and that the TV is online.';
            return;
          }
          new Z.Client(list[i]).publicInfo(function (err, info) {
            if (!err && util.looksLikeJellyfin(info)) { busy = false; app().setServer(list[i], info); app().go('signin'); }
            else next(i + 1);
          });
        })(0);
      };
      input.addEventListener('keydown', function (e) {
        if (e.keyCode === Z.KEYS.imeDone || e.keyCode === Z.KEYS.enter) { e.preventDefault(); input.blur(); focus.start(1); }
        if (e.keyCode === Z.KEYS.imeCancel) { input.blur(); }
      });
      panel.appendChild(input);
      panel.appendChild(go);
      panel.appendChild(note);
      var wrap = el('div', 'center-screen');
      var logo = el('img', 'hero-logo');
      logo.src = 'wordmark.png';
      logo.alt = 'Zorofin';
      wrap.appendChild(logo);
      wrap.appendChild(panel);
      page.appendChild(wrap);
      var focus = new ui.Focus(page, [{ items: [input], kind: 'buttons' }, { items: [go], kind: 'buttons' }], { topMargin: 0 });
      focus.start(input.value ? 1 : 0);
      return { focus: focus, back: function () { app().exit(); } };
    }
  };

  // ---------- sign in ----------

  var signin = {
    render: function (page, params) {
      var adding = params && params.add;
      var panel = el('section', 'panel');
      panel.appendChild(el('h1', '', adding ? 'Add a profile' : 'Sign in'));
      panel.appendChild(el('p', 'muted', app().serverName ? 'to ' + app().serverName : ''));
      var name = el('input', 'field');
      name.type = 'text'; name.placeholder = 'Username'; name.value = params.userName || ''; name.setAttribute('autocomplete', 'off');
      var pass = el('input', 'field');
      pass.type = 'password'; pass.placeholder = 'Password';
      var submit = ui.button('Sign in', 'primary wide');
      var quick = ui.button('Use Quick Connect', 'wide');
      var change = ui.button(adding ? 'Cancel' : 'Change server', 'wide subtle');
      var note = status('');
      var poll = null, alive = true, busy = false;
      var existing = client(), auth = new Z.Client(existing.base, null);
      function signedIn(err, session) {
        if (!alive || client() !== existing) return;
        busy = false;
        if (err || !session || !session.token) {
          note.className = 'status error';
          note.textContent = err && err.status === 401 ? 'Wrong username or password.' : errorText(err) || 'Sign-in could not be completed.';
          return;
        }
        existing.session = session;
        app().saveSession();
        app().go('home', null, true);
      }
      [name, pass].forEach(function (input, i) {
        input.activate = function () { input.focus(); };
        input.addEventListener('keydown', function (e) {
          if (e.keyCode === Z.KEYS.imeDone || e.keyCode === Z.KEYS.enter) { e.preventDefault(); input.blur(); focus.start(i + 1); }
        });
      });
      submit.activate = function () {
        if (busy) return;
        if (poll) { clearInterval(poll); poll = null; }
        busy = true;
        note.className = 'status'; note.textContent = 'Signing in…';
        auth.signIn(name.value.replace(/^\s+|\s+$/g, ''), pass.value, signedIn);
      };
      quick.activate = function () {
        if (busy) return;
        if (poll) { clearInterval(poll); poll = null; }
        busy = true;
        auth.quickConnectStart(function (err, data) {
          if (!alive) return;
          busy = false;
          if (err || !data || !data.Code) { note.className = 'status error'; note.textContent = 'Quick Connect is off on this server.'; return; }
          note.className = 'status code';
          note.textContent = 'On a signed-in phone or computer, open Quick Connect and enter ' + data.Code;
          var checking = false;
          var ticket = poll = setInterval(function () {
            if (checking || poll !== ticket) return;
            checking = true;
            auth.quickConnectState(data.Secret, function (e, state) {
              checking = false;
              if (!alive || poll !== ticket) return;
              if (e && (e.status === 401 || e.status === 404)) {
                clearInterval(poll); poll = null;
                note.className = 'status error'; note.textContent = 'That code expired. Request a new one.';
                return;
              }
              if (e || !state || !state.Authenticated) return;
              clearInterval(poll); poll = null;
              busy = true;
              auth.quickConnectFinish(data.Secret, signedIn);
            });
          }, 3000);
        });
      };
      change.activate = function () {
        if (adding) return app().back();
        app().go('connect', { prefill: client().base }, true);
      };
      [name, pass, submit, quick, change, note].forEach(function (n) { panel.appendChild(n); });
      var wrap = el('div', 'center-screen');
      wrap.appendChild(panel);
      page.appendChild(wrap);
      var zones = [name, pass, submit, quick, change].map(function (n) { return { items: [n], kind: 'buttons' }; });
      var focus = new ui.Focus(page, zones, { topMargin: 0 });
      focus.start(0);
      return { focus: focus, leave: function () { alive = false; if (poll) clearInterval(poll); }, back: function () { if (adding) app().back(); else app().exit(); } };
    }
  };

  // ---------- Home ----------

  var home = {
    render: function (page, params, screen) {
      var top = header('Home');
      page.appendChild(top.node);
      var hero = el('section', 'hero');
      var heroArt = el('div', 'hero-art');
      var heroText = el('div', 'hero-text');
      var heroTitle = el('h1', 'hero-title', '');
      var heroMeta = el('div', 'hero-meta', '');
      var heroOverview = el('p', 'hero-overview', '');
      heroText.appendChild(heroTitle); heroText.appendChild(heroMeta); heroText.appendChild(heroOverview);
      hero.appendChild(heroArt); hero.appendChild(heroText);
      page.appendChild(hero);
      var rowsNode = el('div', 'rows');
      page.appendChild(rowsNode);
      var loading = status('Loading your library…');
      rowsNode.appendChild(loading);
      var zones = [top.zone];
      var focus;
      var heroTimer = null;

      function showHero(item) {
        if (!item || !item.Id) return;
        if (heroTimer) clearTimeout(heroTimer);
        // Wait for the remote to settle so fast scrolling stays smooth.
        heroTimer = setTimeout(function () {
          var show = item.Type === 'Episode' ? { Name: item.SeriesName } : item;
          heroTitle.textContent = show.Name || '';
          var meta = [];
          if (item.Type === 'Episode') meta.push(util.episodeLabel(item));
          else {
            if (item.ProductionYear) meta.push(item.ProductionYear);
            if (item.OfficialRating) meta.push(item.OfficialRating);
            if (item.RunTimeTicks && item.Type === 'Movie') meta.push(util.runtimeLabel(item.RunTimeTicks));
            if (item.CommunityRating) meta.push('★ ' + item.CommunityRating.toFixed(1));
          }
          heroMeta.textContent = meta.join('  ·  ');
          heroOverview.textContent = item.Overview || '';
          var url = client().image(item, 'Backdrop', 1280);
          heroArt.style.backgroundImage = url ? 'url("' + url + '")' : 'none';
        }, 220);
      }

      var pending = 5, results = {};
      function collect(key) {
        return function (err, items) {
          results[key] = err ? [] : items;
          if (err && err.status === 401) return app().signOut();
          if (--pending === 0) build();
        };
      }
      client().resume(collect('resume'));
      client().nextUp(collect('next'));
      client().latest('Movie', collect('movies'));
      client().latest('Series,Episode', collect('shows'));
      // Zorofin rows from the server plugin (New episodes, Live sports, picks).
      // Servers without the plugin just get the library rows.
      client().homeRows(function (err, rows) { results.server = rows || []; if (--pending === 0) build(); });
      if (app().hasLiveTv === undefined) {
        client().get('/LiveTv/Channels', { userId: client().session.userId, limit: 1 }, function (err, page) {
          app().hasLiveTv = !err && page && page.TotalRecordCount > 0;
          if (app().hasLiveTv) addLiveTab();
        });
      }

      function addLiveTab() {
        var nav = top.node.querySelector('.topnav');
        var tab = ui.button('Live TV', 'tab', function () { app().go('live', null, true); });
        var profile = top.zone.items[top.zone.items.length - 1];
        nav.insertBefore(tab, profile);
        top.zone.items.splice(top.zone.items.length - 1, 0, tab);
      }

      function serverRow(row) {
        var wide = row.id === 'new-episodes' || row.id === 'sports';
        var items = row.cards.map(function (c) { var it = c.item; it.zCard = c; return it; });
        return ui.rowZone(client(), row.title, items, wide ? 'wide' : 'poster', openItem, {
          cardOptions: function (item) {
            var c = item.zCard;
            if (row.id === 'sports') {
              var when = airLabel(c.startsAt, c.endsAt);
              return { title: item.Name, meta: [c.subtitle, when === 'Live now' ? '' : when].filter(Boolean).join('  ·  '),
                badge: when === 'Live now' ? 'LIVE' : '', badgeClass: 'live', progress: false };
            }
            var out = { meta: c.subtitle || undefined };
            if (item.Type === 'Episode') out.title = item.SeriesName;
            if ((c.badges || []).length && !wide) out.badge = c.badges[0] === '4K' ? '4K' : undefined;
            return out;
          }
        });
      }

      function build() {
        ui.clear(rowsNode);
        var rows = [];
        var cw = util.continueWatching(results.resume, results.next);
        saveSpotlight(cw);
        if (cw.length) rows.push(ui.rowZone(client(), 'Continue Watching', cw, 'wide', openItem, {
          cardOptions: function (item) { return { title: item.Type === 'Episode' ? item.SeriesName : item.Name, meta: item.Type === 'Episode' ? util.episodeLabel(item) : util.cardMeta(item) }; }
        }));
        // Same order as the other TV apps: what's ready and new first, then shelves.
        var server = {};
        results.server.forEach(function (r) { server[r.id] = r; });
        ['requests-ready', 'new-episodes', 'sports'].forEach(function (id) { if (server[id]) rows.push(serverRow(server[id])); });
        if (results.movies.length) rows.push(ui.rowZone(client(), 'New movies', results.movies, 'poster', openItem));
        var shows = results.shows.map(function (i) { return i; });
        if (shows.length) rows.push(ui.rowZone(client(), 'New in shows', shows, 'poster', openItem, {
          cardOptions: function (item) {
            if (item.Type === 'Episode') return { title: item.SeriesName, meta: util.episodeLabel(item) };
            return null;
          }
        }));
        ['short-movies', 'showcase', 'curated', 'popular'].forEach(function (id) { if (server[id]) rows.push(serverRow(server[id])); });
        results.hasServerRows = results.server.length > 0;
        if (!rows.length) { rowsNode.appendChild(status('Nothing here yet. Add some movies or shows on your server.')); }
        rows.forEach(function (r) { rowsNode.appendChild(r.node); zones.push(r.zone); });
        // More rows load in the background once Home is on screen.
        loadExtraRows(rows.length ? null : null);
        focus = new ui.Focus(page, zones, { onFocus: function (node) { if (node.item) showHero(node.item); } });
        screen.focus = focus;
        var restore = params && params.restore;
        focus.start(restore ? restore.zone : (zones.length > 1 ? 1 : 0), restore ? restore.index : 0);
        var first = zones[1] && zones[1].items[0];
        if (first && first.item) showHero(first.item);
      }

      function loadExtraRows() {
        var extra = results.hasServerRows ? [
          ['Collections', { includeItemTypes: 'BoxSet', recursive: true, sortBy: 'SortName', limit: 20 }]
        ] : [
          ['Top rated movies', { includeItemTypes: 'Movie', recursive: true, sortBy: 'CommunityRating', sortOrder: 'Descending', limit: 20, minCommunityRating: 7 }],
          ['Top rated shows', { includeItemTypes: 'Series', recursive: true, sortBy: 'CommunityRating', sortOrder: 'Descending', limit: 20, minCommunityRating: 7 }],
          ['Collections', { includeItemTypes: 'BoxSet', recursive: true, sortBy: 'SortName', limit: 20 }]
        ];
        extra.forEach(function (row) {
          client().items(row[1], function (err, items) {
            if (err || !items.length || !focus) return;
            var r = ui.rowZone(client(), row[0], items, 'poster', openItem, {
              cardOptions: row[0] === 'Collections' ? function (item) { return { meta: item.ChildCount ? item.ChildCount + ' titles' : '' }; } : null
            });
            rowsNode.appendChild(r.node);
            r.zone.index = 0; r.zone.offsetX = 0;
            focus.zones.push(r.zone);
            focus.loadNearby();
          });
        });
      }

      return {
        focus: null,
        snapshot: function () { return focus ? { zone: focus.zone, index: focus.zones[focus.zone].index } : null; },
        leave: function () { if (heroTimer) clearTimeout(heroTimer); },
        back: function () {
          if (focus && focus.zone !== 0) { focus.start(0); return; }
          app().exit();
        }
      };
    }
  };

  // ---------- details (movie or series) ----------

  var details = {
    render: function (page, params, screen) {
      var wrap = el('div', 'details');
      var art = el('div', 'details-art');
      var shade = el('div', 'details-shade');
      var body = el('div', 'details-body');
      wrap.appendChild(art); wrap.appendChild(shade); wrap.appendChild(body);
      page.appendChild(wrap);
      body.appendChild(status('Loading…'));
      var focus;

      client().item(params.id, function (err, item) {
        ui.clear(body);
        if (err || !item) { body.appendChild(status(errorText(err), true)); return; }
        var url = client().image(item, 'Backdrop', 1920);
        if (url) art.style.backgroundImage = 'url("' + url + '")';
        body.appendChild(el('h1', 'details-title', item.Name));
        var meta = [];
        if (item.ProductionYear) meta.push(item.ProductionYear);
        if (item.OfficialRating) meta.push(item.OfficialRating);
        if (item.RunTimeTicks && item.Type !== 'Series') meta.push(util.runtimeLabel(item.RunTimeTicks));
        if (item.CommunityRating) meta.push('★ ' + item.CommunityRating.toFixed(1));
        if (item.Genres && item.Genres.length) meta.push(item.Genres.slice(0, 3).join(', '));
        body.appendChild(el('div', 'details-meta', meta.join('  ·  ')));
        body.appendChild(el('p', 'details-overview', item.Overview || ''));
        var actions = el('div', 'actions');
        body.appendChild(actions);
        var zones = [];
        var buttons = [];

        if (item.Type === 'Series') {
          var resumeBtn = ui.button('Play', 'primary');
          actions.appendChild(resumeBtn);
          buttons.push(resumeBtn);
          resumeBtn.activate = function () { if (resumeBtn.target) app().play(resumeBtn.target); };
          var seasonsNode = el('div', 'seasons');
          var episodesHost = el('div', 'episodes-host');
          body.appendChild(seasonsNode);
          body.appendChild(episodesHost);
          zones.push({ items: buttons, kind: 'buttons' });
          var seasonZone = { items: [], kind: 'row', track: null, anchor: seasonsNode };
          var episodeZone = null;
          client().seasons(item.Id, function (e, seasons) {
            if (e || !seasons.length) { focus = new ui.Focus(page, zones, { topMargin: 0 }); screen.focus = focus; focus.start(0); return; }
            var viewport = el('div', 'row-viewport');
            var track = el('div', 'row-track chips');
            viewport.appendChild(track);
            seasonsNode.appendChild(viewport);
            seasonZone.track = track;
            seasonIds = seasons.map(function (s) { return s.Id; });
            var startSeason = 0;
            seasons.forEach(function (s, i) {
              var chip = ui.button(s.Name, 'chip');
              chip.activate = function () { pickSeason(i); };
              track.appendChild(chip);
              seasonZone.items.push(chip);
              if (params.seasonId ? s.Id === params.seasonId : (s.UserData && !s.UserData.Played && startSeason === 0 && i > 0 && seasons[i - 1].UserData && seasons[i - 1].UserData.Played)) startSeason = i;
            });
            seasonZone.index = startSeason;
            zones.push(seasonZone);
            focus = new ui.Focus(page, zones, { topMargin: 0 });
            screen.focus = focus;
            pickSeason(startSeason, true);
          });

          var pickSeason = function (i, first) {
            var season = seasonZone.items[i];
            seasonZone.items.forEach(function (c) { c.className = c.className.replace(/\s*\bcurrent\b/g, ''); });
            season.className += ' current';
            client().episodes(item.Id, seasonsAt(i), function (e, episodes) {
              ui.clear(episodesHost);
              if (episodeZone) focus.zones.splice(focus.zones.indexOf(episodeZone), 1);
              episodeZone = null;
              if (!e && episodes.length) {
                var r = ui.rowZone(client(), seasonZone.items[i].textContent, episodes, 'wide', function (ep) { app().play(ep); }, {
                  cardOptions: function (ep) { return { title: (ep.IndexNumber ? ep.IndexNumber + '. ' : '') + ep.Name, meta: util.runtimeLabel(ep.RunTimeTicks), art: client().image(ep, 'Primary', 480) || client().image(ep, 'Backdrop', 480) }; }
                });
                episodesHost.appendChild(r.node);
                episodeZone = r.zone;
                focus.zones.push(episodeZone);
                // Play resumes the first unwatched or in-progress episode.
                var target = 0;
                for (var k = 0; k < episodes.length; k++) {
                  var d = episodes[k].UserData || {};
                  if (params.episodeId ? episodes[k].Id === params.episodeId : !d.Played) { target = k; break; }
                }
                episodeZone.index = target;
                resumeBtn.target = episodes[target];
                var pos = (episodes[target].UserData || {}).PlaybackPositionTicks;
                resumeBtn.textContent = (pos ? 'Resume ' : 'Play ') + 'S' + (episodes[target].ParentIndexNumber || i + 1) + ' E' + (episodes[target].IndexNumber || target + 1);
              }
              if (first) focus.start(params.episodeId && episodeZone ? focus.zones.length - 1 : 0);
              else focus.apply(true);
            });
          };
          var seasonIds = [];
          var seasonsAt = function (i) { return seasonIds[i]; };
        } else {
          var pos = (item.UserData || {}).PlaybackPositionTicks;
          if (pos) {
            var resume = ui.button('Resume from ' + util.ticksToClock(pos), 'primary');
            resume.activate = function () { app().play(item); };
            actions.appendChild(resume);
            buttons.push(resume);
          }
          var play = ui.button(pos ? 'Play from start' : 'Play', pos ? '' : 'primary');
          play.activate = function () { app().play(item, { fromStart: true }); };
          actions.appendChild(play);
          buttons.push(play);
          zones.push({ items: buttons, kind: 'buttons' });
          focus = new ui.Focus(page, zones, { topMargin: 0 });
          screen.focus = focus;
          focus.start(0);
        }
        var watched = ui.button((item.UserData || {}).Played ? 'Mark unwatched' : 'Mark watched', '');
        watched.activate = function () {
          var played = (item.UserData || {}).Played;
          client().request(played ? 'DELETE' : 'POST', '/UserPlayedItems/' + item.Id, { userId: client().session.userId }, undefined, function () {});
          item.UserData = item.UserData || {};
          item.UserData.Played = !played;
          watched.textContent = played ? 'Mark watched' : 'Mark unwatched';
        };
        actions.appendChild(watched);
        buttons.push(watched);
      });

      return { back: function () { app().back(); } };
    }
  };

  // ---------- library grid (Movies, Shows, a collection) ----------

  var library = {
    render: function (page, params, screen) {
      var top = header(params.type === 'Movie' ? 'Movies' : params.type === 'Series' ? 'Shows' : '');
      page.appendChild(top.node);
      page.appendChild(el('h1', 'page-title', params.title || ''));
      var gridNode = el('div', 'grid');
      page.appendChild(gridNode);
      gridNode.appendChild(status('Loading…'));
      var query = params.parentId ? { parentId: params.parentId, sortBy: 'ProductionYear,SortName', limit: 300 }
        : { includeItemTypes: params.type, recursive: true, sortBy: 'SortName', limit: 300 };
      client().items(query, function (err, items) {
        ui.clear(gridNode);
        if (err) { gridNode.appendChild(status(errorText(err), true)); return; }
        if (!items.length) gridNode.appendChild(status('Nothing here yet.'));
        var cards = items.map(function (item) {
          var c = ui.card(client(), item, 'poster');
          c.activate = function () { openItem(item); };
          gridNode.appendChild(c);
          return c;
        });
        var focus = new ui.Focus(page, [top.zone, { items: cards, kind: 'grid', cols: 6 }], {
          onFocus: function () { }
        });
        screen.focus = focus;
        focus.start(cards.length ? 1 : 0, params.restore ? params.restore.index : 0);
      });
      return {
        snapshot: function () { return screen.focus ? { zone: 1, index: screen.focus.zones[screen.focus.zones.length - 1].index } : null; },
        back: function () { app().back(); }
      };
    }
  };

  // ---------- search ----------

  var search = {
    render: function (page, params, screen) {
      var top = header('Search');
      page.appendChild(top.node);
      var input = el('input', 'field search-field');
      input.type = 'text'; input.placeholder = 'Search movies and shows'; input.setAttribute('autocomplete', 'off');
      input.value = params && params.term || '';
      page.appendChild(input);
      var gridNode = el('div', 'grid');
      page.appendChild(gridNode);
      var zones = [top.zone, { items: [input], kind: 'buttons' }];
      var focus = new ui.Focus(page, zones, { topMargin: 100 });
      screen.focus = focus;
      var timer = null, run = 0;
      input.activate = function () { input.focus(); };
      function doSearch() {
        var term = input.value.replace(/^\s+|\s+$/g, '');
        var mine = ++run;
        if (focus.zones.length > 2) focus.zones.splice(2);
        ui.clear(gridNode);
        if (term.length < 2) return;
        gridNode.appendChild(status('Searching…'));
        client().search(term, function (err, items) {
          if (mine !== run) return;
          ui.clear(gridNode);
          if (err) { gridNode.appendChild(status(errorText(err), true)); return; }
          if (!items.length) { gridNode.appendChild(status('No matches for “' + term + '”.')); return; }
          var cards = items.map(function (item) {
            var c = ui.card(client(), item, 'poster');
            c.activate = function () { screen.params = { term: input.value }; openItem(item); };
            gridNode.appendChild(c);
            return c;
          });
          focus.zones.push({ items: cards, kind: 'grid', cols: 6, index: 0, offsetX: 0 });
          focus.loadNearby();
        });
      }
      input.addEventListener('input', function () { if (timer) clearTimeout(timer); timer = setTimeout(doSearch, 450); });
      input.addEventListener('keydown', function (e) {
        if (e.keyCode === Z.KEYS.imeDone || e.keyCode === Z.KEYS.enter) { e.preventDefault(); input.blur(); doSearch(); if (focus.zones.length > 2) focus.start(2); }
      });
      focus.start(1);
      if (input.value) doSearch();
      return { back: function () { if (document.activeElement === input) { input.blur(); return; } app().go('home', null, true); } };
    }
  };

  // ---------- Who's watching? ----------

  // Remembers what the signed-in profile was watching. Like Roku, this TV
  // never fetches other profiles' history; each refreshes on its own Home.
  function saveSpotlight(cw) {
    var session = client() && client().session;
    if (!session || !session.userId) return;
    var pick = null, i;
    for (i = 0; i < cw.length && !pick; i++) if (client().image(cw[i], 'Backdrop', 1280)) pick = cw[i];
    if (!pick) pick = cw[0];
    var key = 'zorofin.spotlight.' + session.userId;
    if (!pick) { util.storage(key, null); return; }
    var title = pick.Type === 'Episode' ? (pick.SeriesName || pick.Name) : pick.Name;
    var detail = util.episodeLabel(pick);
    util.storage(key, JSON.stringify({
      line: detail ? title + ' · ' + detail : title,
      progress: util.progress(pick),
      backdrop: client().image(pick, 'Backdrop', 1280),
      thumb: client().image(pick, 'Backdrop', 420)
    }));
  }

  function readSpotlight(userId) {
    try { return JSON.parse(util.storage('zorofin.spotlight.' + userId) || 'null'); } catch (e) { return null; }
  }

  function profileSquare(a) {
    var node = el('span', 'avatar square');
    node.appendChild(el('span', 'avatar-letter', (a.userName || '?').charAt(0).toUpperCase()));
    if (a.userId && client()) {
      var img = el('img', 'avatar-img');
      img.alt = '';
      img.onerror = function () { if (img.parentNode) img.parentNode.removeChild(img); };
      img.src = client().userImage(a.userId, 240);
      node.appendChild(img);
    }
    return node;
  }

  var profiles = {
    render: function (page, params, screen) {
      var wrap = el('div', 'pb');
      var art = el('div', 'pb-art');
      wrap.appendChild(art);
      wrap.appendChild(el('div', 'pb-shade-left'));
      wrap.appendChild(el('div', 'pb-shade-bottom'));
      var logo = el('img', 'pb-logo');
      logo.src = 'wordmark.png';
      logo.alt = 'Zorofin';
      wrap.appendChild(logo);
      wrap.appendChild(el('h1', 'pb-title', 'Who’s watching?'));
      if (params.expired) wrap.appendChild(el('p', 'pb-notice', 'Sign in again to use ' + (params.expired.userName || 'this profile') + '.'));
      var card = el('div', 'pb-card');
      var thumb = el('div', 'pb-thumb');
      var bar = el('div', 'pb-bar');
      var fill = el('div', 'pb-fill');
      bar.appendChild(fill);
      thumb.appendChild(bar);
      card.appendChild(thumb);
      var was = el('div', 'pb-was', '');
      var line = el('div', 'pb-line', '');
      card.appendChild(was);
      card.appendChild(line);
      wrap.appendChild(card);

      var list = el('div', 'pb-list');
      var current = params.expired ? params.expired.userId : client().session && client().session.userId;
      var accounts = app().accounts();
      var tiles = accounts.map(function (a) {
        var tile = el('div', 'profile-tile');
        tile.appendChild(profileSquare(a));
        tile.appendChild(el('div', 'profile-name', a.userName || ''));
        tile.account = a;
        tile.activate = function () {
          if (params.expired && params.expired.userId === a.userId) {
            return app().go('signin', { add: true, userName: a.userName });
          }
          app().useAccount(a);
        };
        list.appendChild(tile);
        return tile;
      });
      var add = el('div', 'profile-tile add');
      var plus = el('span', 'avatar square add');
      plus.appendChild(el('span', 'avatar-letter', '+'));
      add.appendChild(plus);
      add.appendChild(el('div', 'profile-name', 'Add'));
      add.activate = function () { app().go('signin', { add: true }); };
      list.appendChild(add);
      tiles.push(add);
      wrap.appendChild(list);
      page.appendChild(wrap);

      function show(tile) {
        var a = tile && tile.account;
        if (!a) return;
        var spot = readSpotlight(a.userId);
        if (spot && spot.backdrop) {
          art.style.backgroundImage = 'url(' + spot.backdrop + ')';
          art.className = 'pb-art';
        } else {
          art.style.backgroundImage = 'url(img/scene-' + util.sceneAvatar(a.userId) + '.jpg)';
          art.className = 'pb-art wash';
        }
        if (!spot) { card.style.visibility = 'hidden'; return; }
        card.style.visibility = 'visible';
        thumb.style.backgroundImage = spot.thumb ? 'url(' + spot.thumb + ')' : '';
        bar.style.display = spot.progress > 0 ? 'block' : 'none';
        fill.style.width = Math.max(0, Math.min(100, spot.progress || 0)) + '%';
        was.textContent = (a.userName || '') + ' was watching';
        line.textContent = spot.line || '';
      }

      var start = 0;
      for (var i = 0; i < accounts.length; i++) if (accounts[i].userId === current) start = i;
      var focus = new ui.Focus(page, [{ items: tiles, kind: 'buttons', index: start }], {
        topMargin: 0,
        onFocus: function (item) { show(item); }
      });
      screen.focus = focus;
      focus.start(0);
      show(tiles[start]);
      return { back: function () { if (client().session && app().stack.length) app().back(); else app().exit(); } };
    }
  };

  // ---------- Live TV ----------

  function programmeLine(channel) {
    var p = channel.CurrentProgram;
    if (!p) return '';
    var end = p.EndDate ? new Date(p.EndDate) : null;
    return p.Name + (end && !isNaN(end.getTime()) ? '  ·  until ' + clock(end) : '');
  }

  function programmePercent(channel) {
    var p = channel.CurrentProgram;
    if (!p || !p.StartDate || !p.EndDate) return 0;
    var start = new Date(p.StartDate).getTime(), end = new Date(p.EndDate).getTime(), now = Date.now();
    if (!(end > start)) return 0;
    return Math.max(0, Math.min(100, 100 * (now - start) / (end - start)));
  }

  var live = {
    render: function (page, params, screen) {
      var top = header('Live TV');
      page.appendChild(top.node);
      page.appendChild(el('h1', 'page-title', 'Live TV'));
      var gridNode = el('div', 'grid grid-wide');
      page.appendChild(gridNode);
      gridNode.appendChild(status('Loading channels…'));
      client().channels(function (err, channels) {
        ui.clear(gridNode);
        if (err) { gridNode.appendChild(status(errorText(err), true)); return; }
        if (!channels.length) gridNode.appendChild(status('No Live TV channels on this server.'));
        var cards = channels.map(function (ch, i) {
          var c = ui.card(client(), ch, 'wide', {
            title: (ch.ChannelNumber ? ch.ChannelNumber + '  ' : '') + ch.Name,
            meta: programmeLine(ch) || 'Live',
            art: client().image(ch, 'Primary', 300),
            percent: programmePercent(ch)
          });
          c.className += ' card-channel';
          c.activate = function () { app().play(ch, { channels: channels, index: i }); };
          gridNode.appendChild(c);
          return c;
        });
        var focus = new ui.Focus(page, [top.zone, { items: cards, kind: 'grid', cols: 4 }]);
        screen.focus = focus;
        focus.start(cards.length ? 1 : 0, params.restore ? params.restore.index : 0);
      });
      return {
        snapshot: function () { return screen.focus ? { zone: 1, index: screen.focus.zones[screen.focus.zones.length - 1].index } : null; },
        back: function () { app().go('home', null, true); }
      };
    }
  };

  // ---------- Pick Together (the TV hosts; phones swipe) ----------

  var PICK_TEXT = {
    lobby: 'Waiting for everyone to join',
    preparing: 'Finding titles everyone can watch…',
    swiping: 'Swiping on phones',
    empty: 'Everyone has seen every title in this round',
    ended: 'This session has ended',
    failed: 'Couldn’t build a round. Try again in a moment.'
  };

  function pickItem(card) {
    return { Id: card.itemId, Name: card.title, Type: card.type, ProductionYear: card.year,
      RunTimeTicks: card.runtimeMinutes ? card.runtimeMinutes * 600000000 : 0, ImageTags: card.imageTag ? { Primary: card.imageTag } : {}, UserData: {} };
  }

  var pick = {
    render: function (page, params, screen) {
      var wrap = el('div', 'pick');
      page.appendChild(wrap);
      var session = null, timer = null, gone = false, focus = null;

      function stopPolling() { if (timer) clearTimeout(timer); timer = null; }

      function fail(err) {
        ui.clear(wrap);
        wrap.appendChild(el('h1', 'page-title', 'Pick Together'));
        var text = err && err.status === 404 ? 'Pick Together isn’t turned on for this server yet. The server owner can turn it on in the Zorofin companion.'
          : errorText(err);
        wrap.appendChild(status(text, true));
        var back = ui.button('Back', 'wide', function () { app().back(); });
        wrap.appendChild(back);
        focus = new ui.Focus(page, [{ items: [back], kind: 'buttons' }], { topMargin: 0 });
        screen.focus = focus;
        focus.start(0);
      }

      function chooseKind() {
        ui.clear(wrap);
        wrap.appendChild(el('h1', 'page-title', 'Pick Together'));
        wrap.appendChild(el('p', 'pick-lead', 'Everyone swipes on their phone. Titles you all like show up here.'));
        var row = el('div', 'actions');
        var buttons = [['Movies', 'movie'], ['Shows', 'series']].map(function (k, i) {
          var b = ui.button(k[0], i === 0 ? 'primary big' : 'big', function () { create(k[1]); });
          row.appendChild(b);
          return b;
        });
        wrap.appendChild(row);
        focus = new ui.Focus(page, [{ items: buttons, kind: 'buttons' }], { topMargin: 0 });
        screen.focus = focus;
        focus.start(0);
      }

      function create(kind) {
        ui.clear(wrap);
        wrap.appendChild(status('Starting…'));
        client().pick('POST', '/sessions', { kind: kind, display: true }, function (err, data) {
          if (gone) return;
          if (err || !data || !data.id) return fail(err);
          session = data;
          draw();
          poll();
        });
      }

      function poll() {
        stopPolling();
        if (!session || session.status === 'ended') return;
        timer = setTimeout(function () {
          client().pick('GET', '/sessions/' + session.id + '?since=' + session.version, undefined, function (err, data) {
            if (gone) return;
            if (!err && data && !data.unchanged) { session = data; draw(); }
            poll();
          });
        }, 2500);
      }

      function act(action) {
        client().pick('POST', '/sessions/' + session.id + '/' + action, {}, function (err, data) {
          if (gone) return;
          if (!err && data && data.id) { session = data; draw(); }
          if (action === 'end') { stopPolling(); app().back(); }
        });
      }

      function draw() {
        var keep = focus ? { zone: focus.zone, index: focus.zones[focus.zone] ? focus.zones[focus.zone].index : 0 } : null;
        ui.clear(wrap);
        var head = el('div', 'pick-head');
        var left = el('div', 'pick-left');
        left.appendChild(el('h1', 'page-title', session.kind === 'series' ? 'Pick a show together' : 'Pick a movie together'));
        left.appendChild(el('p', 'pick-state', PICK_TEXT[session.status] || ''));
        var buttons = [];
        if (session.status === 'lobby') buttons.push(ui.button('Start swiping', 'primary', function () { act('start'); }));
        if (session.status === 'swiping' || session.status === 'empty') buttons.push(ui.button('More titles', session.status === 'empty' ? 'primary' : '', function () { act('next-round'); }));
        buttons.push(ui.button('End', '', function () { act('end'); }));
        var actions = el('div', 'actions');
        buttons.forEach(function (b) { actions.appendChild(b); });
        left.appendChild(actions);
        head.appendChild(left);
        var codeBox = el('div', 'pick-code');
        codeBox.appendChild(el('div', 'pick-code-label', 'Join on your phone'));
        codeBox.appendChild(el('div', 'pick-code-value', session.code || ''));
        codeBox.appendChild(el('div', 'pick-code-help', 'Open Zorofin, tap Pick Together, then Join'));
        head.appendChild(codeBox);
        wrap.appendChild(head);

        var people = el('div', 'pick-people');
        var voters = (session.members || []).filter(function (m) { return !m.display; });
        if (!voters.length) people.appendChild(el('div', 'muted', 'No one has joined yet.'));
        voters.forEach(function (m) {
          var chip = el('div', 'pick-person' + (m.done ? ' done' : ''));
          chip.appendChild(avatar(null, m.name, 'small'));
          chip.appendChild(el('span', 'pick-person-name', m.name));
          if (session.status !== 'lobby' && m.total) chip.appendChild(el('span', 'pick-person-count', m.done ? 'Done' : m.swiped + ' / ' + m.total));
          people.appendChild(chip);
        });
        wrap.appendChild(people);

        var zones = [{ items: buttons, kind: 'buttons' }];
        [['Everyone likes', session.matches], ['Almost', session.almost]].forEach(function (group) {
          if (!group[1] || !group[1].length) return;
          var items = group[1].map(pickItem);
          var r = ui.rowZone(client(), group[0], items, 'poster', function (item) { app().go('details', { id: item.Id }); }, {
            cardOptions: function (item) {
              var src = group[1][items.indexOf(item)];
              return { badge: src.likes + ' of ' + src.of, meta: [item.ProductionYear, src.runtimeMinutes ? util.runtimeLabel(item.RunTimeTicks) : ''].filter(Boolean).join('  ·  '), progress: false };
            }
          });
          wrap.appendChild(r.node);
          zones.push(r.zone);
        });
        if (session.status !== 'lobby' && !(session.matches || []).length) wrap.appendChild(el('p', 'muted pick-empty', 'Matches appear here as soon as everyone likes the same title.'));
        focus = new ui.Focus(page, zones, { topMargin: 0 });
        screen.focus = focus;
        if (keep && keep.zone < zones.length) focus.start(keep.zone, keep.index);
        else focus.start(0);
      }

      if (params.session) { session = params.session; draw(); poll(); }
      else chooseKind();

      return {
        snapshot: function () { return null; },
        leave: function () { gone = true; stopPolling(); screen.params = session && session.status !== 'ended' ? { session: session } : {}; },
        back: function () {
          if (session && session.status !== 'ended') return act('end');
          app().back();
        }
      };
    }
  };

  Z.screens = { connect: connect, signin: signin, home: home, details: details, library: library, search: search, profiles: profiles, live: live, pick: pick };
  Z.screenHelpers = { errorText: errorText, openItem: openItem, avatar: avatar, airLabel: airLabel, clock: clock };
})(this);
