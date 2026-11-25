/* Zorofin for older Samsung TVs: the video player. ES5 only.
 * Uses the TV's own <video> decoder. The server direct-plays what the TV
 * supports and transcodes the rest to H.264/AAC HLS. Remote: OK or Play/Pause
 * toggles, Left/Right seek 10 s (30 s when held), Down opens subtitles,
 * Back stops. Progress is reported every 10 seconds. Skip intro / recap /
 * credits buttons come from the server's media segments (Intro Skipper).
 * Live channels: Left/Right or Channel +/- change channel. */
(function (root) {
  'use strict';

  var Z = root.Z;
  var ui = Z.ui, util = Z.util, el = ui.el, KEYS = Z.KEYS;
  var TICKS = 10000000;

  function Player(app) { this.app = app; }

  Player.prototype.open = function (item, opts) {
    var self = this;
    opts = opts || {};
    this.item = item;
    this.opts = opts;
    this.live = item.Type === 'TvChannel';
    this.client = this.app.client;
    var layer = this.layer = el('div', 'player' + (this.live ? ' live' : ''));
    var video = this.video = el('video', 'player-video');
    video.setAttribute('preload', 'auto');
    layer.appendChild(video);
    var spinner = this.spinner = el('div', 'player-spinner');
    layer.appendChild(spinner);
    var osd = this.osd = el('div', 'player-osd');
    var title = el('div', 'player-title', item.Type === 'Episode' ? item.SeriesName : item.Name);
    var program = this.live && item.CurrentProgram;
    var sub = el('div', 'player-sub', this.live ? (program ? program.Name : 'Live') : item.Type === 'Episode' ? util.episodeLabel(item) : (item.ProductionYear || ''));
    var bar = el('div', 'player-bar');
    this.fill = el('div', 'player-fill');
    bar.appendChild(this.fill);
    var times = el('div', 'player-times');
    this.now = el('span', '', '0:00');
    this.total = el('span', '', util.ticksToClock(item.RunTimeTicks));
    times.appendChild(this.now);
    times.appendChild(this.total);
    this.hint = el('div', 'player-hint', this.live ? 'OK  Pause    ◀ ▶  Channel    ▼  Subtitles    Back  Stop' : 'OK  Play / pause    ◀ ▶  10 s    ▼  Subtitles    Back  Stop');
    osd.appendChild(title); osd.appendChild(sub); osd.appendChild(bar); osd.appendChild(times); osd.appendChild(this.hint);
    layer.appendChild(osd);
    this.message = el('div', 'player-message');
    layer.appendChild(this.message);
    this.skip = el('div', 'player-skip');
    layer.appendChild(this.skip);
    this.segments = [];
    document.body.appendChild(layer);
    this.showOsd();

    var start = opts.fromStart || this.live ? 0 : ((item.UserData || {}).PlaybackPositionTicks || 0);
    if (!this.live) {
      this.client.segments(item.Id, function (e, list) {
        self.segments = list.filter(function (seg) { return seg.Type === 'Intro' || seg.Type === 'Recap' || seg.Type === 'Outro'; });
      });
    }
    this.client.playbackInfo(item, 0, function (err, info) {
      if (err || !info || !info.MediaSources || !info.MediaSources.length) return self.fail(Z.screenHelpers.errorText(err) || 'This video can’t play on this TV.');
      var source = info.MediaSources[0];
      self.source = source;
      self.playSessionId = info.PlaySessionId;
      var url = self.client.streamUrl(item, source, info.PlaySessionId);
      if (!url) return self.fail('This video can’t play on this TV.');
      self.method = source.SupportsDirectPlay || source.SupportsDirectStream ? 'DirectPlay' : 'Transcode';
      self.addSubtitles(source);
      video.addEventListener('loadedmetadata', function () {
        if (start && video.duration && start / TICKS < video.duration - 30) video.currentTime = start / TICKS;
        video.play();
      });
      video.addEventListener('playing', function () { spinner.style.display = 'none'; if (!self.started) { self.started = true; self.report('start'); } self.showOsd(); });
      video.addEventListener('waiting', function () { spinner.style.display = 'block'; });
      video.addEventListener('pause', function () { self.showOsd(true); self.report('progress'); });
      video.addEventListener('timeupdate', function () { self.tick(); });
      video.addEventListener('ended', function () { self.finished(); });
      video.addEventListener('error', function () { self.fail('Playback stopped: the TV couldn’t decode this video.'); });
      video.src = url;
      self.timer = setInterval(function () { if (!video.paused) self.report('progress'); }, 10000);
    });
  };

  Player.prototype.addSubtitles = function (source) {
    var self = this;
    this.subtitles = [];
    (source.MediaStreams || []).forEach(function (stream) {
      if (stream.Type !== 'Subtitle' || stream.DeliveryMethod !== 'External' || !stream.DeliveryUrl) return;
      var track = document.createElement('track');
      track.kind = 'subtitles';
      track.label = stream.DisplayTitle || stream.Language || 'Subtitles';
      track.srclang = stream.Language || 'und';
      var url = stream.DeliveryUrl.replace(/\.(srt|ass|ssa|subrip)(\?|$)/i, '.vtt$2');
      track.src = (/^https?:/i.test(url) ? url : self.client.base + url) + (url.indexOf('api_key=') < 0 ? (url.indexOf('?') < 0 ? '?' : '&') + 'api_key=' + encodeURIComponent(self.client.session.token) : '');
      self.video.appendChild(track);
      self.subtitles.push({ label: track.label, track: track, isDefault: stream.IsDefault || stream.Index === source.DefaultSubtitleStreamIndex });
    });
    setTimeout(function () {
      var tracks = self.video.textTracks || [];
      for (var i = 0; i < tracks.length; i++) tracks[i].mode = self.subtitles[i] && self.subtitles[i].isDefault ? 'showing' : 'disabled';
    }, 0);
  };

  Player.prototype.ticks = function () { return Math.floor((this.video.currentTime || 0) * TICKS); };

  Player.prototype.report = function (event) {
    if (!this.item || !this.playSessionId) return;
    this.client.report(event, {
      ItemId: this.item.Id, MediaSourceId: this.source && this.source.Id, PlaySessionId: this.playSessionId,
      PositionTicks: this.live ? 0 : this.ticks(), IsPaused: !!this.video.paused, PlayMethod: this.method, CanSeek: !this.live,
      LiveStreamId: this.source && this.source.LiveStreamId || undefined
    });
  };

  Player.prototype.tick = function () {
    var dur = this.video.duration || (this.item.RunTimeTicks || 0) / TICKS;
    var pos = this.video.currentTime || 0;
    if (dur && isFinite(dur)) this.fill.style.width = Math.min(100, 100 * pos / dur).toFixed(2) + '%';
    this.now.textContent = util.ticksToClock(pos * TICKS);
    if (dur && isFinite(dur)) this.total.textContent = util.ticksToClock(dur * TICKS);
    this.checkSegment(pos * TICKS);
  };

  // Shows "Skip intro" (or recap / credits) for 8 seconds when one starts.
  Player.prototype.checkSegment = function (ticks) {
    var seg = null;
    for (var i = 0; i < this.segments.length; i++) {
      var s = this.segments[i];
      if (ticks >= s.StartTicks && ticks < s.EndTicks - TICKS) { seg = s; break; }
    }
    if (seg && seg !== this.segment) {
      this.segment = seg;
      this.segmentShownAt = Date.now();
      var next = seg.Type === 'Outro' && this.item.Type === 'Episode';
      this.skip.textContent = seg.Type === 'Intro' ? 'Skip intro' : seg.Type === 'Recap' ? 'Skip recap' : next ? 'Next episode' : 'Skip credits';
    }
    var visible = seg && seg === this.segment && Date.now() - this.segmentShownAt < 8000;
    this.skip.className = 'player-skip' + (visible ? ' visible' : '');
    this.skipVisible = !!visible;
    if (!seg) this.segment = null;
  };

  Player.prototype.skipSegment = function () {
    var seg = this.segment;
    this.skipVisible = false;
    this.skip.className = 'player-skip';
    this.segmentShownAt = 0;
    if (!seg) return;
    if (seg.Type === 'Outro' && this.item.Type === 'Episode') return this.finished();
    var end = seg.EndTicks / TICKS;
    if (this.video.duration && end >= this.video.duration - 1) return this.finished();
    this.video.currentTime = end;
  };

  // Live TV: the previous or next channel in the list the viewer came from.
  Player.prototype.zap = function (delta) {
    var list = this.opts.channels;
    if (!list || list.length < 2) return this.showOsd();
    var index = ((this.opts.index || 0) + delta + list.length) % list.length;
    var app = this.app;
    this.close(false, true);
    app.play(list[index], { channels: list, index: index });
  };

  Player.prototype.showOsd = function (stay) {
    var self = this;
    if (!/\bvisible\b/.test(this.osd.className)) this.osd.className += ' visible';
    if (this.osdTimer) clearTimeout(this.osdTimer);
    if (!stay) this.osdTimer = setTimeout(function () { if (self.video && !self.video.paused) self.osd.className = self.osd.className.replace(/\s*\bvisible\b/g, ''); }, 4000);
  };

  Player.prototype.seek = function (seconds) {
    var v = this.video;
    if (this.live || !v.duration || !isFinite(v.duration)) return this.showOsd();
    v.currentTime = Math.max(0, Math.min(v.duration - 1, v.currentTime + seconds));
    this.tick();
    this.showOsd();
  };

  Player.prototype.toggle = function () {
    if (this.video.paused) this.video.play(); else this.video.pause();
    this.showOsd(this.video.paused);
  };

  Player.prototype.subtitleMenu = function () {
    var self = this;
    if (this.menu) return this.closeMenu();
    var menu = this.menu = el('div', 'player-menu');
    menu.appendChild(el('div', 'player-menu-title', 'Subtitles'));
    var tracks = this.video.textTracks || [];
    var options = [{ label: 'Off', index: -1 }];
    this.subtitles.forEach(function (s, i) { options.push({ label: s.label, index: i }); });
    var items = options.map(function (o) {
      var showing = o.index >= 0 ? tracks[o.index] && tracks[o.index].mode === 'showing' : !self.anyShowing();
      var b = ui.button(o.label + (showing ? '  ✓' : ''), 'menu-item');
      b.activate = function () {
        for (var i = 0; i < tracks.length; i++) tracks[i].mode = i === o.index ? 'showing' : 'disabled';
        self.closeMenu();
      };
      menu.appendChild(b);
      return b;
    });
    this.layer.appendChild(menu);
    this.menuFocus = new ui.Focus(menu, items.map(function (b) { return { items: [b], kind: 'buttons' }; }), { topMargin: 0 });
    this.menuFocus.start(0);
  };

  Player.prototype.anyShowing = function () {
    var tracks = this.video.textTracks || [];
    for (var i = 0; i < tracks.length; i++) if (tracks[i].mode === 'showing') return true;
    return false;
  };

  Player.prototype.closeMenu = function () {
    if (this.menu) this.layer.removeChild(this.menu);
    this.menu = null;
    this.menuFocus = null;
  };

  Player.prototype.key = function (code, repeat) {
    if (this.menu) {
      if (code === KEYS.back || code === KEYS.escape) { this.closeMenu(); return; }
      this.menuFocus.key(code);
      return;
    }
    if (code === KEYS.back || code === KEYS.escape || code === KEYS.stop) return this.close();
    if (code === KEYS.enter && this.skipVisible) return this.skipSegment();
    if (this.live && (code === KEYS.channelUp || code === KEYS.right)) return this.zap(1);
    if (this.live && (code === KEYS.channelDown || code === KEYS.left)) return this.zap(-1);
    if (code === KEYS.enter || code === KEYS.playPause) return this.toggle();
    if (code === KEYS.play) { this.video.play(); return this.showOsd(); }
    if (code === KEYS.pause) { this.video.pause(); return this.showOsd(true); }
    if (code === KEYS.left || code === KEYS.rewind) return this.seek(repeat ? -30 : -10);
    if (code === KEYS.right || code === KEYS.forward) return this.seek(repeat ? 30 : 10);
    if (code === KEYS.down) return this.subtitles.length ? this.subtitleMenu() : this.showOsd();
    this.showOsd();
  };

  Player.prototype.fail = function (text) {
    this.spinner.style.display = 'none';
    this.message.textContent = text + '  Press Back to return.';
    this.message.className = 'player-message visible';
  };

  // At the end of an episode, the next one starts, like the other apps.
  Player.prototype.finished = function () {
    var self = this, item = this.item;
    this.report('stop');
    if (item.Type !== 'Episode' || !item.SeriesId) return this.close(true);
    this.client.get('/Shows/' + item.SeriesId + '/Episodes', { userId: this.client.session.userId, startItemId: item.Id, limit: 2, fields: 'Overview,UserData' }, function (err, page) {
      var list = page && page.Items || [];
      var next = list.length > 1 ? list[1] : null;
      self.close(true);
      if (!err && next) self.app.play(next, { fromStart: true });
    });
  };

  Player.prototype.close = function (alreadyReported, zapping) {
    if (!this.layer) return;
    if (!alreadyReported && this.started) this.report('stop');
    if (this.timer) clearInterval(this.timer);
    if (this.osdTimer) clearTimeout(this.osdTimer);
    try { this.video.pause(); this.video.removeAttribute('src'); this.video.load(); } catch (e) {}
    document.body.removeChild(this.layer);
    this.layer = null;
    if (zapping) this.app.player = null;
    else this.app.playerClosed();
  };

  Z.Player = Player;
})(this);
