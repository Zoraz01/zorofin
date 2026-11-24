/* Zorofin for older Samsung TVs: app shell, routing, remote keys and scaling.
 * ES5 only. The layout is designed at 1920x1080 and scaled to the TV's
 * actual web viewport (1280x720 on some models). */
(function (root) {
  'use strict';

  var Z = root.Z;
  var ui = Z.ui, util = Z.util, KEYS = Z.KEYS;

  var app = Z.app = {
    client: null,
    serverName: '',
    stack: [],
    screen: null,
    player: null,

    init: function () {
      this.stage = document.getElementById('stage');
      this.page = document.getElementById('page');
      this.scale();
      root.addEventListener('resize', this.scale);
      this.registerKeys();
      document.addEventListener('keydown', function (e) { app.onKey(e); });
      var server = util.storage('zorofin.server');
      var session = null;
      try { session = JSON.parse(util.storage('zorofin.session') || 'null'); } catch (e) {}
      if (!server) return this.go('connect', null, true);
      this.client = new Z.Client(server, session);
      this.serverName = util.storage('zorofin.serverName') || '';
      var accounts = this.accounts();
      if (!accounts.length && session && session.token) { accounts = [session]; this.storeAccounts(accounts); }
      if (session && session.token) this.loadViewer();
      // Two or more saved profiles: ask who's watching, like the other TV apps.
      if (accounts.length > 1) return this.go('profiles', null, true);
      this.go(session && session.token ? 'home' : 'signin', null, true);
    },

    // Profiles signed in on this TV for the current server.
    accounts: function () {
      var list = [];
      try { list = JSON.parse(util.storage('zorofin.accounts') || '[]') || []; } catch (e) {}
      return list.filter(function (a) { return a && a.token && a.userId; });
    },

    storeAccounts: function (list) { util.storage('zorofin.accounts', list.length ? JSON.stringify(list) : null); },

    useAccount: function (session) {
      var self = this, source = this.screen, menu = this.menu;
      var check = this.accountCheck = {};
      var candidate = new Z.Client(this.client.base, session);
      function activate(err, viewer) {
        if (self.screen !== source || self.menu !== menu || self.accountCheck !== check) return;
        if (err && (err.status === 401 || err.status === 403)) return self.go('profiles', { expired: session });
        self.client = candidate;
        self.hasLiveTv = false;
        util.storage('zorofin.session', JSON.stringify(session));
        self.loadViewer(viewer);
        self.go('home', null, true);
      }
      candidate.get('/Users/Me', null, activate);
    },

    loadViewer: function (viewer) {
      var self = this, client = this.client, session = client.session;
      this.isAdmin = !!(viewer && viewer.Policy && viewer.Policy.IsAdministrator);
      this.features = null;
      if (!session || !session.token) return;
      if (!viewer) client.get('/Users/Me', null, function (err, data) {
        if (self.client === client && client.session === session) self.isAdmin = !!(!err && data && data.Policy && data.Policy.IsAdministrator);
      });
      client.extension('GET', '/Zorofin/Capabilities', null, undefined, function (err, data) {
        if (self.client === client && client.session === session && !err && data && data.schemaVersion === 1) {
          self.features = data.features || {};
        }
      });
    },

    supports: function (name) {
      var feature = this.features && this.features[name];
      return !!(feature && feature.version === 1 && feature.enabled === true);
    },

    preferences: function () {
      var s = this.client && this.client.session;
      var key = s && 'zorofin.prefs:' + this.client.base + ':' + s.userId;
      var saved = {};
      try { saved = JSON.parse(key && util.storage(key) || '{}') || {}; } catch (e) {}
      return {
        key: key,
        skipBack: Z.skipIntervals.indexOf(saved.skipBack) >= 0 ? saved.skipBack : 10,
        skipForward: Z.skipIntervals.indexOf(saved.skipForward) >= 0 ? saved.skipForward : 10,
        showChapters: saved.showChapters === true,
        showTitles: saved.showTitles !== false,
        showProgress: saved.showProgress !== false,
        reduceMotion: saved.reduceMotion === true,
        subtitlesOn: saved.subtitlesOn !== false,
        sendPlaybackReports: saved.sendPlaybackReports !== false
      };
    },

    savePreference: function (name, value) {
      var prefs = this.preferences(), key = prefs.key;
      if (!key) return;
      delete prefs.key;
      prefs[name] = value;
      util.storage(key, JSON.stringify(prefs));
      this.applyPreferences();
    },

    applyPreferences: function () {
      var prefs = this.preferences();
      this.stage.className = (prefs.showTitles ? '' : ' hide-poster-titles') +
        (prefs.showProgress ? '' : ' hide-progress') + (prefs.reduceMotion ? ' reduce-motion' : '');
    },

    openMenu: function () {
      this.closeMenu();
      this.menu = Z.profileMenu(this);
      this.stage.appendChild(this.menu.node);
      this.menu.focus.start();
    },

    closeMenu: function () {
      if (this.menu) this.stage.removeChild(this.menu.node);
      this.menu = null;
    },

    scale: function () {
      var s = Math.min(root.innerWidth / 1920, root.innerHeight / 1080) || 1;
      var t = 'scale(' + s + ')';
      app.stage.style.webkitTransform = t;
      app.stage.style.transform = t;
    },

    registerKeys: function () {
      var tv = root.tizen && root.tizen.tvinputdevice;
      if (!tv) return;
      ['MediaPlay', 'MediaPause', 'MediaPlayPause', 'MediaStop', 'MediaFastForward', 'MediaRewind', 'ColorF3Blue', 'ChannelUp', 'ChannelDown'].forEach(function (name) {
        try { tv.registerKey(name); } catch (e) {}
      });
    },

    setServer: function (base, info) {
      this.client = new Z.Client(base, null);
      this.features = null;
      this.isAdmin = false;
      this.serverName = info && info.ServerName || '';
      util.storage('zorofin.server', base);
      util.storage('zorofin.serverName', this.serverName);
    },

    saveSession: function () {
      var session = this.client.session;
      util.storage('zorofin.session', JSON.stringify(session));
      var list = this.accounts().filter(function (a) { return a.userId !== session.userId; });
      list.push(session);
      this.storeAccounts(list);
      this.loadViewer();
    },

    // Signs the current profile out of this TV. Other saved profiles stay.
    signOut: function (changeServer) {
      var current = this.client && this.client.session;
      if (current) this.client.post('/Sessions/Logout', {});
      util.storage('zorofin.session', null);
      if (this.client) this.client.session = null;
      this.features = null;
      this.isAdmin = false;
      if (changeServer) {
        this.accounts().forEach(function (a) { if (!current || a.userId !== current.userId) new Z.Client(app.client.base, a).post('/Sessions/Logout', {}); });
        this.storeAccounts([]);
        util.storage('zorofin.server', null);
        return this.go('connect', { prefill: this.client ? this.client.base : '' }, true);
      }
      var rest = this.accounts().filter(function (a) { return !current || a.userId !== current.userId; });
      this.storeAccounts(rest);
      this.go(rest.length ? 'profiles' : 'signin', null, true);
    },

    // replace: start a fresh history (after sign-in, tabs).
    go: function (name, params, replace) {
      this.closeMenu();
      if (this.screen && this.screen.leave) this.screen.leave();
      if (this.screen && !replace) {
        this.stack.push({ name: this.screen.name, params: this.screen.params, snapshot: this.screen.snapshot ? this.screen.snapshot() : null });
        if (this.stack.length > 12) this.stack.shift();
      }
      if (replace) this.stack = [];
      this.show(name, params || {});
    },

    show: function (name, params) {
      this.applyPreferences();
      ui.clear(this.page);
      ui.translate(this.page, 0, 0);
      this.page.className = 'page page-' + name;
      var screen = { name: name, params: params, focus: null };
      var result = Z.screens[name].render(this.page, params, screen) || {};
      for (var k in result) if (Object.prototype.hasOwnProperty.call(result, k) && result[k] !== null) screen[k] = result[k];
      this.screen = screen;
    },

    back: function () {
      var prev = this.stack.pop();
      if (!prev) return this.go('home', null, true);
      if (this.screen && this.screen.leave) this.screen.leave();
      var params = prev.params || {};
      if (prev.snapshot) params.restore = prev.snapshot;
      this.show(prev.name, params);
    },

    exit: function () {
      try { root.tizen.application.getCurrentApplication().exit(); } catch (e) {}
    },

    play: function (item, opts) {
      if (this.player) return;
      this.player = new Z.Player(this);
      this.player.open(item, opts);
    },

    // Back on screen: refresh it so progress and Continue Watching are current.
    playerClosed: function () {
      this.player = null;
      if (this.screen) {
        var snap = this.screen.snapshot ? this.screen.snapshot() : null;
        var params = this.screen.params || {};
        if (snap) params.restore = snap;
        this.show(this.screen.name, params);
      }
    },

    onKey: function (e) {
      var code = e.keyCode;
      var active = document.activeElement;
      var typing = active && active.tagName === 'INPUT';
      if (typing && code !== KEYS.back && code !== KEYS.escape && code !== KEYS.up && code !== KEYS.down) return;
      if (typing && (code === KEYS.up || code === KEYS.down)) active.blur();
      var repeat = this.lastKey === code && Date.now() - this.lastKeyAt < 250;
      this.lastKey = code; this.lastKeyAt = Date.now();
      if (this.player) { e.preventDefault(); this.player.key(code, repeat); return; }
      if (this.menu) {
        if (code === KEYS.back || code === KEYS.escape) this.closeMenu();
        else this.menu.focus.key(code);
        e.preventDefault();
        return;
      }
      var screen = this.screen;
      if (!screen) return;
      if (code === KEYS.back || code === KEYS.escape) {
        e.preventDefault();
        if (typing) { active.blur(); return; }
        if (screen.back) screen.back(); else this.back();
        return;
      }
      if (screen.focus && screen.focus.key(code)) e.preventDefault();
    }
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { app.init(); });
  else app.init();
})(this);
