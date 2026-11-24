/* Zorofin for older Samsung TVs: the video player. ES5 only.
 * Uses the TV's own <video> decoder. The server direct-plays what the TV
 * supports and transcodes the rest to H.264/AAC HLS. Remote: OK or Play/Pause
 * toggles, Left/Right seek, Up opens chapters and Down opens subtitles,
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
    this.prefs = this.app.preferences();
    this.attempt = 0;
    this.chapters = [];
    var layer = this.layer = el('div', 'player' + (this.live ? ' live' : ''));
    var spinner = this.spinner = el('div', 'player-spinner');
    layer.appendChild(spinner);
    var osd = this.osd = el('div', 'player-osd');
    var title = el('div', 'player-title', item.Type === 'Episode' ? item.SeriesName : item.Name);
    var program = this.live && item.CurrentProgram;
    var sub = el('div', 'player-sub', this.live ? (program ? program.Name : 'Live') : item.Type === 'Episode' ? util.episodeLabel(item) : (item.ProductionYear || ''));
    var bar = this.bar = el('div', 'player-bar');
    this.fill = el('div', 'player-fill');
    bar.appendChild(this.fill);
    var times = el('div', 'player-times');
    this.now = el('span', '', '0:00');
    this.total = el('span', '', util.ticksToClock(item.RunTimeTicks));
    times.appendChild(this.now);
    times.appendChild(this.total);
    this.hint = el('div', 'player-hint');
    this.updateHint();
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
        if (self.layer) self.segments = list.filter(function (seg) { return seg.Type === 'Intro' || seg.Type === 'Recap' || seg.Type === 'Outro'; });
      });
      if (this.prefs.showChapters) this.client.get('/Items/' + item.Id, { userId: this.client.session.userId, fields: 'Chapters' }, function (err, data) {
        if (!self.layer || err || !data || !Array.isArray(data.Chapters)) return;
        var list = data.Chapters.filter(function (chapter) {
          return chapter && typeof chapter.StartPositionTicks === 'number' && isFinite(chapter.StartPositionTicks) && chapter.StartPositionTicks >= 0;
        });
        if (list.length < 2) return;
        self.chapters = list.sort(function (a, b) { return a.StartPositionTicks - b.StartPositionTicks; });
        self.updateHint();
        self.drawChapters();
      });
    }
    this.load(start, false);
  };

  Player.prototype.updateHint = function () {
    this.hint.textContent = this.live ? 'OK  Pause    ◀ ▶  Channel    ▼  Subtitles    Back  Stop' :
      'OK  Play / pause    ◀ ' + this.prefs.skipBack + ' s   ▶ ' + this.prefs.skipForward + ' s    ' +
      (this.chapters.length ? '▲  Chapters    ' : '') + '▼  Subtitles    Back  Stop';
  };

  Player.prototype.load = function (position, compatibility) {
    var self = this, attempt = ++this.attempt;
    this.closeMenu();
    this.releaseStream();
    this.startPosition = position;
    this.compatibility = compatibility;
    this.checking = false;
    this.pendingFailure = null;
    this.stalled = false;
    this.reconnecting = false;
    this.failed = false;
    this.message.className = 'player-message';
    this.spinner.style.display = 'block';
    var video = this.video = el('video', 'player-video');
    video.setAttribute('preload', 'auto');
    this.layer.insertBefore(video, this.layer.firstChild);
    this.subtitles = [];
    this.drawnDuration = null;
    function active(fn) {
      return function () {
        if (self.layer && self.attempt === attempt && !self.reconnecting && !self.failed) fn();
      };
    }
    video.addEventListener('loadedmetadata', active(function () {
      if (position && isFinite(video.duration) && video.duration > 1) {
        try { video.currentTime = Math.min(position / TICKS, video.duration - 1); } catch (e) {}
      }
      self.drawChapters();
      self.playVideo();
    }));
    video.addEventListener('playing', active(function () {
      clearTimeout(self.startTimer);
      clearTimeout(self.stallTimer);
      self.checking = false;
      self.stalled = false;
      self.stallTimer = null;
      self.pendingFailure = null;
      self.spinner.style.display = 'none';
      if (!self.started) { self.started = true; self.report('start'); }
      self.showOsd();
    }));
    video.addEventListener('waiting', active(function () {
      self.spinner.style.display = 'block';
      if (!self.started || video.paused || self.stalled || self.stallTimer) return;
      self.stallTimer = setTimeout(function () {
        self.stallTimer = null;
        self.handleProblem(false, 'Playback buffered for 12 seconds');
      }, 12000);
    }));
    video.addEventListener('pause', active(function () {
      clearTimeout(self.stallTimer);
      self.stallTimer = null;
      self.showOsd(true);
      self.report('progress');
    }));
    video.addEventListener('timeupdate', active(function () { self.tick(); }));
    video.addEventListener('ended', active(function () { self.finished(); }));
    video.addEventListener('error', active(function () { self.handleProblem(true, 'The TV could not open the video stream'); }));
    this.startTimer = setTimeout(active(function () { self.handleProblem(true, 'The video did not start in time'); }), 24000);

    this.client.playbackInfo(this.item, 0, function (err, info) {
      if (!self.layer || self.attempt !== attempt || self.checking || self.reconnecting || self.failed) return;
      var source = info && info.MediaSources && info.MediaSources[0];
      var url = source && self.client.streamUrl(self.item, source, info.PlaySessionId, compatibility);
      if (err || !url) return self.handleProblem(true, 'The server could not prepare the video');
      self.source = source;
      self.playSessionId = info.PlaySessionId;
      self.method = self.live || compatibility ? 'Transcode' :
        source.SupportsDirectPlay ? 'DirectPlay' : source.SupportsDirectStream ? 'DirectStream' : 'Transcode';
      self.addSubtitles(source);
      video.src = url;
      self.timer = setInterval(function () { if (self.started && !video.paused && !self.reconnecting) self.report('progress'); }, 10000);
    }, compatibility);
  };

  Player.prototype.playVideo = function () {
    var result = this.video.play();
    if (result && result.catch) result.catch(function () {});
  };

  Player.prototype.releaseStream = function () {
    clearInterval(this.timer);
    clearTimeout(this.startTimer);
    clearTimeout(this.stallTimer);
    clearTimeout(this.retryTimer);
    this.stallTimer = null;
    if (this.started || (this.live && this.source && this.source.LiveStreamId)) this.report('stop');
    this.started = false;
    this.source = null;
    this.playSessionId = null;
    if (this.video) {
      var video = this.video;
      this.video = null;
      try { video.pause(); video.removeAttribute('src'); video.load(); } catch (e) {}
      if (video.parentNode) video.parentNode.removeChild(video);
    }
  };

  Player.prototype.handleProblem = function (fatal, reason) {
    if (this.checking) {
      if (fatal) this.pendingFailure = reason;
      return;
    }
    var self = this, attempt = this.attempt, check = this.checking = {};
    var position = this.live ? 0 : this.video.currentTime > 0 ? this.ticks() : this.startPosition;
    function current() { return self.layer && self.attempt === attempt && self.checking === check; }
    this.client.publicInfo(function (err) {
      if (!current()) return;
      fatal = fatal || !!self.pendingFailure;
      reason = self.pendingFailure || reason;
      self.pendingFailure = null;
      if (!err) {
        self.checking = false;
        if (!fatal) {
          self.stalled = true;
          return self.problem('stalled', reason);
        }
        if (!self.live && !self.compatibility && self.method && self.method !== 'Transcode') {
          self.problem('fallback', reason);
          return self.load(position, true);
        }
        self.problem(self.started ? 'stopped' : 'start_failed', reason);
        return self.fail(self.started ? 'Playback stopped.' : 'This video can’t play on this TV.');
      }
      self.closeMenu();
      self.reconnecting = true;
      self.spinner.style.display = 'none';
      self.message.textContent = 'Reconnecting…';
      self.message.className = 'player-message visible';
      self.video.pause();
      var until = Date.now() + 90000;
      function retry() {
        if (!current()) return;
        if (Date.now() >= until) return self.fail('Can’t reach your server. Check the connection, then try again.');
        self.client.publicInfo(function (error) {
          if (!current()) return;
          if (!error) {
            self.problem('recovered', 'Reconnected after the server came back', position);
            self.load(position, self.compatibility);
          } else self.retryTimer = setTimeout(retry, 3000);
        }, 4000);
      }
      self.retryTimer = setTimeout(retry, 3000);
    }, 4000);
  };

  Player.prototype.problem = function (kind, reason, position) {
    if (!this.app.supports('playbackReports') || !this.app.preferences().sendPlaybackReports) return;
    var item = this.item;
    this.client.reportProblem({
      kind: kind, itemId: item.Id, title: item.Type === 'Episode' && item.SeriesName ? item.SeriesName + ': ' + item.Name : item.Name,
      platform: 'Samsung TV', appVersion: Z.VERSION, device: 'Older Samsung TV',
      method: this.live ? 'live' : this.method === 'DirectPlay' ? 'direct' : this.method === 'DirectStream' ? 'remux' : this.method === 'Transcode' ? 'transcode' : '',
      reason: reason, positionSeconds: this.live ? 0 : Math.floor((position === undefined ? this.ticks() : position) / TICKS)
    });
  };

  Player.prototype.drawChapters = function () {
    var duration = this.video.duration;
    if (!this.chapters.length || !isFinite(duration) || duration <= 0 || this.drawnDuration === duration) return;
    this.drawnDuration = duration;
    var marks = this.bar.querySelectorAll('.player-chapter-mark'), bar = this.bar;
    for (var i = 0; i < marks.length; i++) bar.removeChild(marks[i]);
    this.chapters.forEach(function (chapter) {
      var percent = 100 * chapter.StartPositionTicks / TICKS / duration;
      if (percent <= 0 || percent >= 100) return;
      var mark = el('span', 'player-chapter-mark');
      mark.style.left = percent + '%';
      bar.appendChild(mark);
    });
  };

  Player.prototype.addSubtitles = function (source) {
    var self = this, video = this.video;
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
      self.subtitles.push({ label: track.label, index: stream.Index, isDefault: stream.IsDefault || stream.Index === source.DefaultSubtitleStreamIndex });
    });
    setTimeout(function () {
      if (self.video !== video) return;
      var tracks = video.textTracks || [];
      for (var i = 0; i < tracks.length; i++) {
        var sub = self.subtitles[i];
        var show = sub && (self.subtitleChoice === undefined ? self.prefs.subtitlesOn && sub.isDefault : sub.index === self.subtitleChoice);
        tracks[i].mode = show ? 'showing' : 'disabled';
      }
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
    this.drawChapters();
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
    this.seekTo(v.currentTime + seconds);
  };

  Player.prototype.seekTo = function (seconds) {
    if (!isFinite(this.video.duration) || this.video.duration <= 0) return;
    this.video.currentTime = Math.max(0, Math.min(this.video.duration - 1, seconds));
    this.tick();
    this.showOsd();
  };

  Player.prototype.toggle = function () {
    if (this.video.paused) this.playVideo(); else this.video.pause();
    this.showOsd(this.video.paused);
  };

  Player.prototype.choiceMenu = function (title, options) {
    if (this.menu) return this.closeMenu();
    var self = this, menu = this.menu = el('div', 'player-menu');
    menu.appendChild(el('div', 'player-menu-title', title));
    var selected = 0;
    var items = options.map(function (option, index) {
      if (option.selected) selected = index;
      var button = ui.button(option.label + (option.selected ? '  ✓' : ''), 'menu-item', function () {
        option.pick();
        self.closeMenu();
      });
      menu.appendChild(button);
      return button;
    });
    this.layer.appendChild(menu);
    this.menuFocus = new ui.Focus(menu, [{ items: items, kind: 'grid', cols: 1 }], { noPageScroll: true, onFocus: function (item) {
      if (item && item.scrollIntoViewIfNeeded) item.scrollIntoViewIfNeeded(false);
    } });
    this.menuFocus.start(0, selected);
  };

  Player.prototype.subtitleMenu = function () {
    var self = this, tracks = this.video.textTracks || [];
    function select(index) {
      self.subtitleChoice = index < 0 ? null : self.subtitles[index].index;
      for (var i = 0; i < tracks.length; i++) tracks[i].mode = i === index ? 'showing' : 'disabled';
    }
    var options = [{ label: 'Off', selected: !self.anyShowing(), pick: function () { select(-1); } }];
    this.subtitles.forEach(function (sub, i) {
      options.push({ label: sub.label, selected: tracks[i] && tracks[i].mode === 'showing', pick: function () { select(i); } });
    });
    this.choiceMenu('Subtitles', options);
  };

  Player.prototype.chapterMenu = function () {
    var self = this, position = this.ticks(), active = 0;
    this.chapters.forEach(function (chapter, i) { if (chapter.StartPositionTicks <= position) active = i; });
    this.choiceMenu('Chapters', this.chapters.map(function (chapter, i) {
      return {
        label: (chapter.Name || 'Chapter ' + (i + 1)) + '  ·  ' + util.ticksToClock(chapter.StartPositionTicks),
        selected: i === active,
        pick: function () { self.seekTo(chapter.StartPositionTicks / TICKS); }
      };
    }));
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
    if (this.reconnecting || this.failed) return;
    if (code === KEYS.enter && this.skipVisible) return this.skipSegment();
    if (this.live && (code === KEYS.channelUp || code === KEYS.right)) return this.zap(1);
    if (this.live && (code === KEYS.channelDown || code === KEYS.left)) return this.zap(-1);
    if (code === KEYS.enter || code === KEYS.playPause) return this.toggle();
    if (code === KEYS.play) { this.playVideo(); return this.showOsd(); }
    if (code === KEYS.pause) { this.video.pause(); return this.showOsd(true); }
    if (code === KEYS.left || code === KEYS.rewind) return this.seek(repeat ? -Math.max(30, this.prefs.skipBack) : -this.prefs.skipBack);
    if (code === KEYS.right || code === KEYS.forward) return this.seek(repeat ? Math.max(30, this.prefs.skipForward) : this.prefs.skipForward);
    if (code === KEYS.up && this.chapters.length) return this.chapterMenu();
    if (code === KEYS.down) return this.subtitles.length ? this.subtitleMenu() : this.showOsd();
    this.showOsd();
  };

  Player.prototype.fail = function (text) {
    this.failed = true;
    this.checking = false;
    clearTimeout(this.startTimer);
    clearTimeout(this.stallTimer);
    clearTimeout(this.retryTimer);
    this.spinner.style.display = 'none';
    this.message.textContent = text + '  Press Back to return.';
    this.message.className = 'player-message visible';
  };

  // At the end of an episode, the next one starts, like the other apps.
  Player.prototype.finished = function () {
    var self = this, item = this.item;
    if (this.finishing) return;
    this.finishing = true;
    this.report('stop');
    this.started = false;
    if (item.Type !== 'Episode' || !item.SeriesId) return this.close(true);
    this.client.get('/Shows/' + item.SeriesId + '/Episodes', { userId: this.client.session.userId, startItemId: item.Id, limit: 2, fields: 'Overview,UserData' }, function (err, page) {
      if (!self.layer) return;
      var list = page && page.Items || [];
      var next = list.length > 1 ? list[1] : null;
      self.close(true);
      if (!err && next) self.app.play(next, { fromStart: true });
    });
  };

  Player.prototype.close = function (alreadyReported, zapping) {
    if (!this.layer) return;
    if (alreadyReported) this.started = false;
    this.attempt++;
    this.releaseStream();
    clearTimeout(this.osdTimer);
    document.body.removeChild(this.layer);
    this.layer = null;
    if (zapping) this.app.player = null;
    else this.app.playerClosed();
  };

  Z.Player = Player;
})(this);
