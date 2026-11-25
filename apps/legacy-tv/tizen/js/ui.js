/* Zorofin for older Samsung TVs: elements, cards and remote focus.
 * ES5 only. Movement uses CSS transforms so old TV GPUs can animate it. */
(function (root) {
  'use strict';

  var Z = root.Z;
  var KEYS = Z.KEYS;
  var util = Z.util;

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }

  function translate(node, x, y) {
    var value = 'translate3d(' + Math.round(x) + 'px,' + Math.round(y) + 'px,0)';
    node.style.webkitTransform = value;
    node.style.transform = value;
  }

  // ---------- cards (two styles only: wide 16:9 and poster 2:3) ----------

  // Image URLs load only when a card is near the focus, so the TV never
  // decodes a hundred posters at once.
  function setArt(card, url) {
    card.setAttribute('data-art', url || '');
    if (!url) card.className += ' no-art';
  }

  function loadArt(card) {
    var url = card.getAttribute('data-art');
    if (!url || card.getAttribute('data-loaded')) return;
    card.setAttribute('data-loaded', '1');
    var img = card.querySelector('img');
    img.onload = function () { card.className += ' art-ready'; };
    img.onerror = function () { card.className += ' no-art'; };
    img.src = url;
  }

  function badge(item) {
    var data = item.UserData || {};
    if (item.Type === 'Series' && data.UnplayedItemCount) return '' + (data.UnplayedItemCount > 99 ? '99+' : data.UnplayedItemCount);
    if (data.Played) return '✓';
    return '';
  }

  function card(client, item, style, opts) {
    opts = opts || {};
    var node = el('div', 'card card-' + style);
    var frame = el('div', 'card-frame');
    var img = el('img', 'card-img');
    img.alt = '';
    frame.appendChild(img);
    var fallback = el('div', 'card-fallback', item.SeriesName || item.Name || '');
    frame.appendChild(fallback);
    var mark = opts.badge !== undefined ? opts.badge : badge(item);
    if (mark) frame.appendChild(el('span', 'card-badge' + (opts.badgeClass ? ' ' + opts.badgeClass : ''), mark));
    var pct = opts.percent !== undefined ? opts.percent : opts.progress === false ? 0 : util.progress(item);
    if (pct > 0 && pct < 100) {
      var bar = el('div', 'card-progress');
      var fill = el('div', 'card-progress-fill');
      fill.style.width = pct.toFixed(1) + '%';
      bar.appendChild(fill);
      frame.appendChild(bar);
    }
    node.appendChild(frame);
    var title = opts.title !== undefined ? opts.title : (item.Type === 'Episode' ? item.SeriesName : item.Name);
    node.appendChild(el('div', 'card-title', title || ''));
    var meta = opts.meta !== undefined ? opts.meta : util.cardMeta(item);
    node.appendChild(el('div', 'card-meta', meta || ' '));
    setArt(node, opts.art !== undefined ? opts.art : style === 'wide' ? client.image(item, 'Backdrop', 480) : client.image(item, 'Primary', 300));
    if (opts.homeGame) showHomeGame(node, frame, client.base, item.Name, opts.homeGame);
    node.item = item;
    return node;
  }

  function showHomeGame(node, frame, base, channel, card) {
    var teams = card.matchup, paths = card.crests;
    var pattern = /^Zorofin\/Web\/ui\/live-tv-logos\/art\/sports-[a-f0-9]{24}-[a-f0-9]{8}\.(png|jpg)$/;
    if (!Array.isArray(teams) || !Array.isArray(paths) || teams.length !== 2 || paths.length !== 2) return;
    for (var j = 0; j < 2; j++) {
      var m = typeof paths[j] === 'string' && pattern.exec(paths[j]);
      if (!m || m[0] !== paths[j] || typeof teams[j] !== 'string' || !teams[j].trim() ||
          teams[j].replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, 'x').length > 80) return;
    }
    var layer = el('div', 'home-game-crests'), loaded = 0;
    var title = teams.join(' vs '), soon = Date.parse(card.startsAt) > Date.now();
    var status = soon || (!card.startsAt && (card.badges || []).indexOf('Starting soon') >= 0) ? 'Starting soon' : 'On now';
    paths.forEach(function(path, index) {
      if (index) layer.appendChild(el('strong', '', 'VS'));
      var slot = el('span', 'home-crest-slot'), img = el('img', '');
      img.alt = '';
      img.onload = function() {
        // Original aspect ratio even on engines without object-fit.
        if (img.naturalWidth / img.naturalHeight > (16 / 9 * .28 / .56)) img.style.width = '100%';
        else img.style.height = '100%';
        if (++loaded !== 2) return;
        frame.appendChild(layer);
        node.className += ' home-game';
        node.querySelector('.card-title').textContent = title;
        node.querySelector('.card-meta').textContent = channel;
        node.appendChild(el('div', 'game-status', status));
        node.setAttribute('aria-label', [title, channel, status].join(', '));
      };
      slot.appendChild(img); layer.appendChild(slot);
      img.src = base.replace(/\/$/, '') + '/' + path;
    });
  }

  // ---------- focus ----------

  /* A screen is a vertical list of zones. A zone is a row of cards or
   * buttons ({ items, kind: 'row' | 'buttons' | 'grid', cols, track, head }).
   * Up/Down move between zones (or grid lines), Left/Right move inside one. */
  function Focus(page, zones, options) {
    this.page = page;
    this.zones = zones.filter(function (z) { return z.items.length; });
    this.options = options || {};
    this.zone = 0;
    this.offsetY = 0;
    for (var i = 0; i < this.zones.length; i++) {
      this.zones[i].index = this.zones[i].index || 0;
      this.zones[i].offsetX = 0;
    }
  }

  Focus.prototype.current = function () {
    var zone = this.zones[this.zone];
    return zone ? zone.items[zone.index] : null;
  };

  Focus.prototype.start = function (zoneIndex, itemIndex) {
    if (!this.zones.length) return;
    this.zone = Math.min(zoneIndex || 0, this.zones.length - 1);
    if (itemIndex !== undefined) this.zones[this.zone].index = Math.min(itemIndex, this.zones[this.zone].items.length - 1);
    this.apply(true);
  };

  Focus.prototype.apply = function (instant) {
    var self = this;
    var previous = this.page.querySelectorAll('.focused');
    for (var p = 0; p < previous.length; p++) previous[p].className = previous[p].className.replace(/\s*\bfocused\b/g, '');
    this.zones.forEach(function (z, zi) {
      if (z.head) z.head.className = z.head.className.replace(/\s*\bactive\b/g, '') + (zi === self.zone ? ' active' : '');
    });
    var zone = this.zones[this.zone];
    if (!zone) return;
    var item = zone.items[zone.index];
    item.className += ' focused';
    if (instant) this.page.className = this.page.className.replace(/\s*\banimate\b/g, '');
    else if (!/\banimate\b/.test(this.page.className)) this.page.className += ' animate';
    this.scrollRow(zone);
    this.scrollPage(zone);
    this.loadNearby();
    if (this.options.onFocus) this.options.onFocus(item, zone);
  };

  // Keep the focused card near the left edge, like the other TV apps.
  Focus.prototype.scrollRow = function (zone) {
    if (zone.kind !== 'row' || !zone.track) return;
    var item = zone.items[zone.index];
    var viewport = zone.track.parentNode.clientWidth;
    var trackWidth = zone.track.scrollWidth;
    // offsetLeft counts the row's left padding; measure from the first card.
    var target = item.offsetLeft - zone.items[0].offsetLeft;
    var max = Math.max(0, trackWidth - viewport);
    zone.offsetX = Math.min(target, max);
    if (zone.index === 0) zone.offsetX = 0;
    translate(zone.track, -zone.offsetX, 0);
  };

  Focus.prototype.scrollPage = function (zone) {
    var anchor = zone.anchor || zone.items[zone.index];
    var top = 0, node = anchor;
    while (node && node !== this.page) { top += node.offsetTop; node = node.offsetParent; }
    if (zone.kind === 'grid') top = top + 0;
    var margin = this.options.topMargin === undefined ? 60 : this.options.topMargin;
    var view = 1080;
    var bottom = top + anchor.offsetHeight;
    var max = Math.max(0, this.page.scrollHeight - view);
    // Scroll only as far as needed, so Home keeps its banner above the first row.
    if (this.zone === 0) this.offsetY = 0;
    else if (top - margin < this.offsetY) this.offsetY = top - margin;
    else if (bottom + 40 > this.offsetY + view) this.offsetY = bottom + 40 - view;
    this.offsetY = Math.max(0, Math.min(this.offsetY, max));
    translate(this.page, 0, -this.offsetY);
  };

  Focus.prototype.loadNearby = function () {
    for (var zi = Math.max(0, this.zone - 1); zi <= Math.min(this.zones.length - 1, this.zone + 2); zi++) {
      var zone = this.zones[zi];
      var from = zone.kind === 'grid' ? 0 : Math.max(0, zone.index - 2);
      var to = zone.kind === 'grid' ? zone.items.length : Math.min(zone.items.length, zone.index + 9);
      for (var i = from; i < to; i++) if (zone.items[i].getAttribute('data-art') !== null) loadArt(zone.items[i]);
    }
  };

  Focus.prototype.move = function (dx, dy) {
    var zone = this.zones[this.zone];
    if (!zone) return false;
    if (zone.kind === 'grid' && dy) {
      var target = zone.index + dy * zone.cols;
      if (target >= 0 && target < zone.items.length) { zone.index = target; this.apply(); return true; }
      if (dy > 0 && Math.floor(zone.index / zone.cols) < Math.floor((zone.items.length - 1) / zone.cols)) {
        zone.index = zone.items.length - 1; this.apply(); return true;
      }
    }
    if (dx) {
      var next = zone.index + dx;
      if (zone.kind === 'grid' && Math.floor(next / zone.cols) !== Math.floor(zone.index / zone.cols)) return false;
      if (next < 0 || next >= zone.items.length) return false;
      zone.index = next;
      this.apply();
      return true;
    }
    if (dy) {
      var nz = this.zone + dy;
      if (nz < 0 || nz >= this.zones.length) return false;
      var from = this.zones[this.zone], to = this.zones[nz];
      // Buttons and grids line up by position; rows keep where you left them.
      if (to.kind !== 'row' && from.kind !== 'row') to.index = Math.min(to.index, to.items.length - 1);
      if (to.kind === 'grid' && dy < 0) to.index = Math.min(to.items.length - 1, Math.floor((to.items.length - 1) / to.cols) * to.cols + (to.index % to.cols));
      this.zone = nz;
      this.apply();
      return true;
    }
    return false;
  };

  Focus.prototype.key = function (code) {
    if (code === KEYS.left) return this.move(-1, 0);
    if (code === KEYS.right) return this.move(1, 0);
    if (code === KEYS.up) return this.move(0, -1);
    if (code === KEYS.down) return this.move(0, 1);
    if (code === KEYS.enter) {
      var item = this.current();
      if (item && item.activate) { item.activate(); return true; }
    }
    return false;
  };

  function button(label, cls, activate) {
    var node = el('div', 'btn' + (cls ? ' ' + cls : ''), label);
    node.activate = activate;
    return node;
  }

  function rowZone(client, title, items, style, onPick, opts) {
    var section = el('section', 'row row-' + style);
    var head = el('h2', 'row-title', title);
    section.appendChild(head);
    var viewport = el('div', 'row-viewport');
    var track = el('div', 'row-track');
    viewport.appendChild(track);
    section.appendChild(viewport);
    var cards = items.map(function (item) {
      var c = card(client, item, style, opts && opts.cardOptions ? opts.cardOptions(item) : null);
      c.activate = function () { onPick(item, c); };
      track.appendChild(c);
      return c;
    });
    return { node: section, zone: { items: cards, kind: 'row', track: track, head: head, anchor: section } };
  }

  Z.ui = { el: el, clear: clear, translate: translate, card: card, loadArt: loadArt, Focus: Focus, button: button, rowZone: rowZone };
})(this);
