/* Zorofin for older Samsung TVs: shared helpers and the Jellyfin client.
 * ES5 only (Tizen 3.0 = Chromium 47): no arrow functions, let/const, template
 * strings, classes, fetch, Promise-only APIs, ?. or ??. Callbacks are
 * node-style: done(error, result). */
(function (root) {
  'use strict';

  var Z = root.Z = root.Z || {};
  Z.VERSION = '1.5.1';

  Z.skipIntervals = [5, 10, 15, 30, 60];

  var KEYS = Z.KEYS = {
    left: 37, up: 38, right: 39, down: 40, enter: 13, back: 10009, escape: 27, backspace: 8,
    play: 415, pause: 19, playPause: 10252, stop: 413, rewind: 412, forward: 417,
    blue: 406, channelUp: 427, channelDown: 428, imeDone: 65376, imeCancel: 65385
  };

  // ---------- server address ----------

  function isPrivateHost(host) {
    return /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|[^.]+$|.+\.local$)/i.test(host);
  }

  // What the viewer typed, as base URLs worth trying, best first.
  function candidates(input) {
    var text = String(input || '').replace(/^\s+|\s+$/g, '');
    if (!text) return [];
    text = text.replace(/\/+(web(\/.*)?)?$/i, '').replace(/\/+$/, '');
    if (/^https?:\/\//i.test(text)) return [text];
    var host = text.split('/')[0];
    var hasPort = /:\d+$/.test(host);
    var hostname = host.replace(/:\d+$/, '');
    var rest = text.slice(host.length);
    var list = [];
    if (isPrivateHost(hostname)) {
      list.push('http://' + text);
      if (!hasPort) list.push('http://' + hostname + ':8096' + rest);
      list.push('https://' + text);
    } else {
      list.push('https://' + text);
      list.push('http://' + text);
      if (!hasPort) list.push('http://' + hostname + ':8096' + rest);
    }
    return list;
  }

  function looksLikeJellyfin(body) {
    try {
      var info = typeof body === 'string' ? JSON.parse(body) : body;
      return !!(info && info.Id && (info.ProductName || info.Version));
    } catch (e) { return false; }
  }

  // ---------- small utilities ----------

  function query(params) {
    var parts = [];
    for (var key in params) {
      if (Object.prototype.hasOwnProperty.call(params, key) && params[key] !== undefined && params[key] !== null) {
        parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(params[key]));
      }
    }
    return parts.length ? '?' + parts.join('&') : '';
  }

  function ticksToClock(ticks) {
    var s = Math.max(0, Math.floor((ticks || 0) / 10000000));
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    var mm = h ? (m < 10 ? '0' + m : '' + m) : '' + m;
    return (h ? h + ':' : '') + mm + ':' + (sec < 10 ? '0' + sec : sec);
  }

  function runtimeLabel(ticks) {
    var min = Math.round((ticks || 0) / 600000000);
    if (!min) return '';
    var h = Math.floor(min / 60), m = min % 60;
    return h ? h + ' h' + (m ? ' ' + m + ' min' : '') : m + ' min';
  }

  function episodeLabel(item) {
    if (item.Type !== 'Episode') return '';
    var parts = [];
    if (item.ParentIndexNumber !== undefined && item.IndexNumber !== undefined) parts.push('S' + item.ParentIndexNumber + ' · E' + item.IndexNumber);
    if (item.Name) parts.push(item.Name);
    return parts.join(' · ');
  }

  // One meta line under a card, like the other TV apps.
  function cardMeta(item) {
    if (item.Type === 'Episode') return episodeLabel(item);
    if (item.Type === 'Series') {
      var years = item.ProductionYear ? '' + item.ProductionYear : '';
      if (item.Status === 'Continuing' && years) years += ' –';
      return years;
    }
    return item.ProductionYear ? '' + item.ProductionYear : '';
  }

  function progress(item) {
    var data = item.UserData || {};
    if (data.PlayedPercentage) return Math.min(100, Math.max(0, data.PlayedPercentage));
    if (data.PlaybackPositionTicks && item.RunTimeTicks) return Math.min(100, 100 * data.PlaybackPositionTicks / item.RunTimeTicks);
    return 0;
  }

  // Continue Watching: resume items first, then next-up episodes of other shows.
  function continueWatching(resume, nextUp) {
    var out = [], seenItems = {}, seenSeries = {};
    function add(item) {
      if (!item || seenItems[item.Id]) return;
      if (item.SeriesId && seenSeries[item.SeriesId]) return;
      seenItems[item.Id] = true;
      if (item.SeriesId) seenSeries[item.SeriesId] = true;
      out.push(item);
    }
    (resume || []).forEach(add);
    (nextUp || []).forEach(add);
    return out.slice(0, 20);
  }

  // Built-in avatar for a profile without a photo: sum of the id's
  // characters mod 7, the same rule as the Apple, Flutter and Roku apps.
  var SCENES = ['northbound', 'orbital', 'ember', 'tide', 'harbor', 'saltflats', 'lastlight'];
  function sceneAvatar(id) {
    var text = String(id || '').toLowerCase(), sum = 0;
    for (var i = 0; i < text.length; i++) sum += text.charCodeAt(i);
    return SCENES[sum % SCENES.length];
  }

  function storage(key, value) {
    try {
      if (arguments.length === 1) return root.localStorage.getItem(key);
      if (value === null) root.localStorage.removeItem(key);
      else root.localStorage.setItem(key, value);
    } catch (e) {}
    return null;
  }

  function deviceId() {
    var id = storage('zorofin.device');
    if (!id) {
      id = 'zrfn-legacy-' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
      storage('zorofin.device', id);
    }
    return id;
  }

  // ---------- Jellyfin client ----------

  function Client(base, session) {
    this.base = base;
    this.session = session || null; // { token, userId, userName }
  }

  Client.prototype.authorization = function () {
    var fields = [
      ['Client', 'Zorofin'], ['Device', 'Samsung TV'], ['DeviceId', deviceId()], ['Version', Z.VERSION]
    ];
    if (this.session && this.session.token) fields.push(['Token', this.session.token]);
    return 'MediaBrowser ' + fields.map(function (f) { return f[0] + '="' + String(f[1]).replace(/"/g, '') + '"'; }).join(', ');
  };

  Client.prototype.request = function (method, path, params, body, done, timeout) {
    var xhr = new XMLHttpRequest();
    var finished = false;
    function finish(err, data) { if (!finished) { finished = true; done(err, data); } }
    try {
      xhr.open(method, this.base + path + query(params || {}), true);
      xhr.timeout = timeout || 20000;
      xhr.setRequestHeader('Authorization', this.authorization());
      xhr.setRequestHeader('X-Emby-Authorization', this.authorization());
      if (body !== undefined) xhr.setRequestHeader('Content-Type', 'application/json');
      xhr.onload = function () {
        if (xhr.status === 204) return finish(null, null);
        if (xhr.status < 200 || xhr.status >= 300) {
          var err = new Error('HTTP ' + xhr.status);
          err.status = xhr.status;
          return finish(err);
        }
        var text = xhr.responseText;
        if (!text) return finish(null, null);
        try { finish(null, JSON.parse(text)); } catch (e) { finish(e); }
      };
      xhr.onerror = function () { finish(new Error('network')); };
      xhr.ontimeout = function () { finish(new Error('timeout')); };
      xhr.send(body === undefined ? null : JSON.stringify(body));
    } catch (e) { finish(e); }
  };

  Client.prototype.get = function (path, params, done) { this.request('GET', path, params, undefined, done); };
  Client.prototype.post = function (path, body, done) { this.request('POST', path, null, body || {}, done || function () {}); };

  Client.prototype.publicInfo = function (done, timeout) {
    this.request('GET', '/System/Info/Public', null, undefined, done, timeout);
  };

  Client.prototype.signIn = function (name, password, done) {
    var self = this;
    this.post('/Users/AuthenticateByName', { Username: name, Pw: password }, function (err, data) {
      if (err) return done(err);
      self.session = { token: data.AccessToken, userId: data.User.Id, userName: data.User.Name };
      done(null, self.session);
    });
  };

  Client.prototype.quickConnectStart = function (done) { this.post('/QuickConnect/Initiate', {}, done); };
  Client.prototype.quickConnectState = function (secret, done) { this.get('/QuickConnect/Connect', { secret: secret }, done); };
  Client.prototype.quickConnectFinish = function (secret, done) {
    var self = this;
    this.post('/Users/AuthenticateWithQuickConnect', { Secret: secret }, function (err, data) {
      if (err) return done(err);
      self.session = { token: data.AccessToken, userId: data.User.Id, userName: data.User.Name };
      done(null, self.session);
    });
  };

  var FIELDS = 'PrimaryImageAspectRatio,Overview,Genres,ProductionYear,Status,UserData,MediaStreams';

  Client.prototype.items = function (params, done) {
    var p = { userId: this.session.userId, fields: FIELDS, enableImageTypes: 'Primary,Backdrop,Thumb', imageTypeLimit: 1 };
    for (var k in params) if (Object.prototype.hasOwnProperty.call(params, k)) p[k] = params[k];
    this.get('/Items', p, function (err, page) { done(err, page ? page.Items || [] : []); });
  };

  Client.prototype.resume = function (done) {
    this.get('/UserItems/Resume', { userId: this.session.userId, limit: 20, fields: FIELDS, mediaTypes: 'Video', enableImageTypes: 'Primary,Backdrop,Thumb' },
      function (err, page) { done(err, page ? page.Items || [] : []); });
  };

  Client.prototype.nextUp = function (done) {
    this.get('/Shows/NextUp', { userId: this.session.userId, limit: 20, fields: FIELDS, enableResumable: false, enableRewatching: false },
      function (err, page) { done(err, page ? page.Items || [] : []); });
  };

  Client.prototype.latest = function (types, done) {
    this.get('/Items/Latest', { userId: this.session.userId, includeItemTypes: types, limit: 20, fields: FIELDS, groupItems: true },
      function (err, list) { done(err, list || []); });
  };

  Client.prototype.item = function (id, done) { this.get('/Items/' + id, { userId: this.session.userId, fields: FIELDS + ',People' }, done); };

  Client.prototype.seasons = function (seriesId, done) {
    this.get('/Shows/' + seriesId + '/Seasons', { userId: this.session.userId, fields: 'UserData' }, function (err, page) { done(err, page ? page.Items || [] : []); });
  };

  Client.prototype.episodes = function (seriesId, seasonId, done) {
    this.get('/Shows/' + seriesId + '/Episodes', { userId: this.session.userId, seasonId: seasonId, fields: FIELDS },
      function (err, page) { done(err, page ? page.Items || [] : []); });
  };

  Client.prototype.search = function (term, done) {
    this.items({ searchTerm: term, recursive: true, includeItemTypes: 'Movie,Series', limit: 30 }, done);
  };

  // Artwork URL sized for a card, so the TV never decodes full-size images.
  Client.prototype.image = function (item, kind, width) {
    var id = item.Id, tag;
    var tags = item.ImageTags || {};
    if (kind === 'Backdrop') {
      if (item.BackdropImageTags && item.BackdropImageTags.length) tag = item.BackdropImageTags[0];
      else if (item.ParentBackdropImageTags && item.ParentBackdropImageTags.length) { tag = item.ParentBackdropImageTags[0]; id = item.ParentBackdropItemId; }
      else if (tags.Thumb) { kind = 'Thumb'; tag = tags.Thumb; }
      else if (tags.Primary && (item.Type === 'Episode' || item.Type === 'Program' || item.Type === 'TvChannel')) { kind = 'Primary'; tag = tags.Primary; }
      if (!tag) return '';
    } else {
      if (item.Type === 'Episode' && item.SeriesPrimaryImageTag) { id = item.SeriesId; tag = item.SeriesPrimaryImageTag; }
      else tag = tags.Primary;
      if (!tag) return '';
    }
    return this.base + '/Items/' + id + '/Images/' + kind + query({ fillWidth: width, quality: 85, tag: tag });
  };

  // What older Samsung TVs play in an HTML5 <video>; everything else is
  // transcoded by the server to H.264/AAC HLS.
  Z.deviceProfile = function (maxBitrate) {
    return {
      MaxStreamingBitrate: maxBitrate, MaxStaticBitrate: maxBitrate, MusicStreamingTranscodingBitrate: 384000,
      DirectPlayProfiles: [
        { Container: 'mp4,m4v,mkv,mov', Type: 'Video', VideoCodec: 'h264,hevc', AudioCodec: 'aac,mp3,ac3,eac3' },
        { Container: 'ts', Type: 'Video', VideoCodec: 'h264', AudioCodec: 'aac,mp3,ac3' }
      ],
      TranscodingProfiles: [
        { Container: 'ts', Type: 'Video', Protocol: 'hls', VideoCodec: 'h264', AudioCodec: 'aac', Context: 'Streaming', MaxAudioChannels: '2', MinSegments: 2, SegmentLength: 4, BreakOnNonKeyFrames: true }
      ],
      CodecProfiles: [
        { Type: 'Video', Codec: 'h264', Conditions: [
          { Condition: 'LessThanEqual', Property: 'VideoBitDepth', Value: '8' },
          { Condition: 'LessThanEqual', Property: 'VideoLevel', Value: '51' }
        ] },
        { Type: 'Video', Codec: 'hevc', Conditions: [
          { Condition: 'EqualsAny', Property: 'VideoRangeType', Value: 'SDR|HDR10' }
        ] }
      ],
      ContainerProfiles: [],
      SubtitleProfiles: [
        { Format: 'vtt', Method: 'External' }, { Format: 'srt', Method: 'External' },
        { Format: 'ass', Method: 'Encode' }, { Format: 'ssa', Method: 'Encode' },
        { Format: 'pgssub', Method: 'Encode' }, { Format: 'dvdsub', Method: 'Encode' }
      ]
    };
  };

  Client.prototype.playbackInfo = function (item, startTicks, done, compatibility) {
    var bitrate = 40000000;
    var live = item.Type === 'TvChannel';
    this.request('POST', '/Items/' + item.Id + '/PlaybackInfo', { userId: this.session.userId }, {
      UserId: this.session.userId, StartTimeTicks: startTicks || 0, MaxStreamingBitrate: bitrate,
      // Live channels go through the server's HLS (stream copy when it can),
      // which old TV players handle better than a raw TS feed.
      DeviceProfile: Z.deviceProfile(bitrate), EnableDirectPlay: !live && !compatibility, EnableDirectStream: !live && !compatibility,
      EnableTranscoding: true, AllowVideoStreamCopy: !compatibility, AllowAudioStreamCopy: !compatibility, AutoOpenLiveStream: true
    }, done);
  };

  // The URL the <video> element should open for a PlaybackInfo media source.
  Client.prototype.streamUrl = function (item, source, playSessionId, compatibility) {
    // Live channels: the server's HLS stream when it offers one, else the raw TS.
    if (source.LiveStreamId && !source.TranscodingUrl) {
      return this.base + '/Videos/' + item.Id + '/stream.ts' + query({
        static: 'true', mediaSourceId: source.Id, liveStreamId: source.LiveStreamId, playSessionId: playSessionId, api_key: this.session.token
      });
    }
    if (!compatibility && !source.LiveStreamId && (source.SupportsDirectPlay || source.SupportsDirectStream)) {
      return this.base + '/Videos/' + item.Id + '/stream' + query({
        static: 'true', mediaSourceId: source.Id, playSessionId: playSessionId, api_key: this.session.token
      });
    }
    if (source.TranscodingUrl) {
      var url = source.TranscodingUrl;
      if (!/api_key=/i.test(url)) url += (url.indexOf('?') >= 0 ? '&' : '?') + 'api_key=' + encodeURIComponent(this.session.token);
      return /^https?:/i.test(url) ? url : this.base + url;
    }
    return '';
  };

  // Zorofin plugin and companion routes read the viewer token from this header.
  Client.prototype.extension = function (method, path, params, body, done) {
    var self = this, xhr = new XMLHttpRequest(), finished = false;
    function finish(err, data) { if (!finished) { finished = true; done(err, data); } }
    try {
      xhr.open(method, this.base + path + query(params || {}), true);
      xhr.timeout = 20000;
      xhr.setRequestHeader('Authorization', this.authorization());
      xhr.setRequestHeader('X-Jellyfin-Token', this.session ? this.session.token : '');
      xhr.setRequestHeader('Accept', 'application/json');
      if (body !== undefined) xhr.setRequestHeader('Content-Type', 'application/json');
      xhr.onload = function () {
        if (xhr.status < 200 || xhr.status >= 300) { var e = new Error('HTTP ' + xhr.status); e.status = xhr.status; e.extension = true; return finish(e); }
        try { finish(null, xhr.responseText ? JSON.parse(xhr.responseText) : null); } catch (x) { finish(x); }
      };
      xhr.onerror = function () { finish(new Error('network')); };
      xhr.ontimeout = function () { finish(new Error('timeout')); };
      xhr.send(body === undefined ? null : JSON.stringify(body));
    } catch (e) { finish(e); }
    return self;
  };

  Client.prototype.reportProblem = function (problem) {
    if (this.problemsRefused || (this.problemCount || 0) >= 30) return;
    this.problemCount = (this.problemCount || 0) + 1;
    var self = this;
    this.extension('POST', '/Zorofin/PlaybackReports', null, problem, function (err) {
      if (err && (err.status === 404 || err.status === 429)) self.problemsRefused = true;
    });
  };

  // The plugin's Home rows (the same feed the other TV apps use), or null.
  Client.prototype.homeRows = function (done) {
    this.extension('GET', '/Zorofin/Home/Rows', null, undefined, function (err, data) {
      if (err || !data || data.schemaVersion !== 1 || !data.rows) return done(null, null);
      done(null, data.rows.filter(function (r) { return r.state === 'ready' && r.cards && r.cards.length; }));
    });
  };

  Client.prototype.pick = function (method, path, body, done) {
    this.extension(method, '/Zorofin/Companion/pickTogether' + path, null, body, done);
  };

  Client.prototype.channels = function (done) {
    this.get('/LiveTv/Channels', { userId: this.session.userId, addCurrentProgram: true, enableImageTypes: 'Primary', imageTypeLimit: 1, limit: 300, sortBy: 'SortName' },
      function (err, page) { done(err, page ? page.Items || [] : []); });
  };

  // Intro and credits markers (Jellyfin media segments, filled by Intro Skipper).
  Client.prototype.segments = function (itemId, done) {
    this.get('/MediaSegments/' + itemId, { includeSegmentTypes: 'Intro,Outro,Recap,Preview' }, function (err, page) {
      done(null, err || !page ? [] : page.Items || []);
    });
  };

  Client.prototype.userImage = function (userId, width) {
    return this.base + '/Users/' + userId + '/Images/Primary' + query({ fillWidth: width, quality: 85 });
  };

  Client.prototype.report = function (event, body) {
    var path = event === 'start' ? '/Sessions/Playing' : event === 'stop' ? '/Sessions/Playing/Stopped' : '/Sessions/Playing/Progress';
    this.post(path, body);
  };

  Z.Client = Client;
  Z.util = {
    candidates: candidates, looksLikeJellyfin: looksLikeJellyfin, isPrivateHost: isPrivateHost, query: query,
    ticksToClock: ticksToClock, runtimeLabel: runtimeLabel, episodeLabel: episodeLabel, cardMeta: cardMeta,
    progress: progress, continueWatching: continueWatching, storage: storage, sceneAvatar: sceneAvatar
  };
})(this);
