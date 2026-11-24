/* Older Samsung profile menu and settings. Uses the same remote focus
 * engine as the library and saves device preferences as they are changed. */
(function (root) {
  'use strict';

  var Z = root.Z, ui = Z.ui, el = ui.el;

  function zone(node) { return { items: [node], kind: 'buttons' }; }

  function panel(page, title) {
    var node = el('section', 'panel left settings-panel');
    node.appendChild(el('h1', '', title));
    page.appendChild(node);
    return node;
  }

  function row(node, label, detail, activate) {
    var button = ui.button('', 'wide settings-row', activate);
    button.appendChild(el('span', 'settings-label', label));
    var value = el('span', 'settings-value', detail || '');
    button.appendChild(value);
    node.appendChild(button);
    return { button: button, value: value };
  }

  Z.profileMenu = function (app) {
    var layer = el('div', 'profile-overlay');
    var menu = el('section', 'profile-popover');
    var session = app.client.session || {};
    var who = el('div', 'me-who');
    who.appendChild(Z.screenHelpers.avatar(session.userId, session.userName, 'tab-avatar'));
    var names = el('div', 'me-text');
    names.appendChild(el('h2', '', session.userName || 'Profile'));
    names.appendChild(el('p', 'muted small', app.serverName || 'Jellyfin'));
    who.appendChild(names);
    menu.appendChild(who);
    menu.appendChild(el('p', 'muted small', 'Switch profile'));
    var strip = el('div', 'profile-strip');
    var tiles = app.accounts().filter(function (a) { return a.userId !== session.userId; }).map(function (a) {
      var tile = ui.button('', 'profile-chip', function () { app.useAccount(a); });
      tile.appendChild(Z.screenHelpers.avatar(a.userId, a.userName, 'tab-avatar'));
      tile.appendChild(el('span', '', a.userName || 'Profile'));
      strip.appendChild(tile);
      return tile;
    });
    var all = ui.button('All', 'profile-chip profile-all', function () { app.go('profiles'); });
    strip.appendChild(all);
    tiles.push(all);
    var zones = [{ items: tiles, kind: 'row', track: strip }];
    var viewport = el('div', 'profile-strip-viewport');
    viewport.appendChild(strip);
    menu.appendChild(viewport);
    if (!app.features || app.supports('pickTogether')) {
      zones.push(zone(row(menu, 'Pick Together', '', function () { app.go('pick'); }).button));
    }
    zones.push(zone(row(menu, 'Settings', '', function () { app.go('settings'); }).button));
    layer.appendChild(menu);
    return { node: layer, focus: new ui.Focus(layer, zones) };
  };

  var pages = [
    ['account', 'Account', 'Profiles and server'],
    ['display', 'Home & display', 'Posters, progress, motion'],
    ['playback', 'Playback', 'Skip intervals and chapters'],
    ['subtitles', 'Subtitles', 'Default subtitle behavior'],
    ['help', 'Help & about', 'Support, privacy, version']
  ];

  Z.screens.settings = {
    render: function (page, params, screen) {
      var app = Z.app, node = panel(page, 'Settings'), zones = [];
      var session = app.client.session || {};
      node.appendChild(el('p', 'muted', (session.userName || 'Profile') + (app.serverName ? '  ·  ' + app.serverName : '')));
      function section(key, title, description) {
        zones.push(zone(row(node, title, description, function () { app.go('preferences', { key: key, title: title }); }).button));
      }
      pages.forEach(function (entry) { section(entry[0], entry[1], entry[2]); });
      if (app.isAdmin) section('admin', 'Manage server', 'Dashboard, metadata, approvals');
      zones.push(zone(row(node, 'Sign Out', '', function () { app.go('confirmSignOut'); }).button));
      var focus = new ui.Focus(page, zones);
      focus.start(params.restore && params.restore.zone);
      return { focus: focus, snapshot: function () { return { zone: focus.zone }; } };
    }
  };

  function web(title, address) {
    Z.app.go('settingsLink', { title: title, address: address });
  }

  Z.screens.preferences = {
    render: function (page, params) {
      var app = Z.app, node = panel(page, params.title), zones = [];
      var prefs = app.preferences();
      function action(label, detail, fn) {
        var entry = row(node, label, detail, fn);
        zones.push(zone(entry.button));
        return entry;
      }
      function toggle(label, key) {
        var entry = action(label, prefs[key] ? 'On' : 'Off', function () {
          prefs[key] = !prefs[key];
          app.savePreference(key, prefs[key]);
          entry.value.textContent = prefs[key] ? 'On' : 'Off';
        });
      }
      function interval(label, key) {
        var entry = action(label, prefs[key] + ' seconds', function () {
          app.go('skipInterval', { title: label, key: key });
        });
        return entry;
      }
      if (params.key === 'account') {
        action('Add a profile', '', function () { app.go('signin', { add: true }); });
        action('Quick Connect', 'Sign in another device', function () { app.go('authorizeDevice'); });
        action('Change server', 'Sign in to another Jellyfin server', function () { app.go('confirmSignOut', { changeServer: true }); });
      } else if (params.key === 'display') {
        toggle('Show titles under posters', 'showTitles');
        toggle('Show watching progress', 'showProgress');
        toggle('Reduce motion', 'reduceMotion');
      } else if (params.key === 'playback') {
        node.appendChild(el('h2', 'settings-section', 'In the player'));
        interval('Skip backward', 'skipBack');
        interval('Skip forward', 'skipForward');
        toggle('Show chapters', 'showChapters');
        node.appendChild(el('p', 'muted small', 'Chapter marks and the chapter list can give the story away. Off by default.'));
      } else if (params.key === 'subtitles') {
        toggle('Use default subtitle track', 'subtitlesOn');
        node.appendChild(el('p', 'muted small', 'Press Down while a title plays to choose another available subtitle track.'));
      } else if (params.key === 'help') {
        action('App Support', '', function () { web('App Support', 'https://zorofin.app/support'); });
        action('Privacy Policy', '', function () { web('Privacy Policy', 'https://zorofin.app/privacy'); });
        if (app.supports('playbackReports')) {
          toggle('Send playback problem reports to this server', 'sendPlaybackReports');
          node.appendChild(el('p', 'muted small', 'When a title won’t start or keeps buffering, the app tells your server owner the title, app version and what went wrong. Nothing leaves your server.'));
        }
        node.appendChild(el('p', 'muted', 'Zorofin for older Samsung TVs · ' + Z.VERSION));
      } else if (params.key === 'admin' && app.isAdmin) {
        function serverLink(label, path) { action(label, '', function () { web(label, app.client.base + '/web/#/' + path); }); }
        serverLink('Dashboard', 'dashboard');
        serverLink('Metadata Manager', 'metadata');
        if (app.supports('accountApprovals')) serverLink('Account approvals', 'mypreferencesmenu');
      }
      var focus = new ui.Focus(page, zones);
      focus.start(params.restore && params.restore.zone);
      return { focus: focus, snapshot: function () { return { zone: focus.zone }; } };
    }
  };

  Z.screens.skipInterval = {
    render: function (page, params) {
      var app = Z.app, node = panel(page, params.title), selected = app.preferences()[params.key];
      var options = Z.skipIntervals.map(function (seconds) {
        return zone(row(node, seconds + ' seconds', seconds === selected ? 'Selected' : '', function () {
          app.savePreference(params.key, seconds);
          app.back();
        }).button);
      });
      var focus = new ui.Focus(page, options);
      focus.start(Z.skipIntervals.indexOf(selected));
      return { focus: focus };
    }
  };

  Z.screens.authorizeDevice = {
    render: function (page, params, screen) {
      var app = Z.app, client = app.client, node = panel(page, 'Quick Connect');
      node.appendChild(el('p', 'muted', 'Enter the sign-in code shown on the other device.'));
      var field = el('input', 'field');
      field.type = 'text';
      field.maxLength = 6;
      field.setAttribute('autocomplete', 'off');
      field.setAttribute('inputmode', 'numeric');
      field.activate = function () { field.focus(); };
      node.appendChild(field);
      var pending = false;
      var submit = row(node, 'Authorize device', '', function () {
        if (pending) return;
        var code = field.value.replace(/\s/g, '');
        if (!/^\d{6}$/.test(code)) { note.textContent = 'Enter a six-digit code.'; return; }
        pending = true;
        note.textContent = 'Authorizing…';
        client.request('POST', '/QuickConnect/Authorize', { code: code, userId: client.session.userId }, undefined, function (err, result) {
          if (app.screen !== screen) return;
          pending = false;
          note.textContent = !err && result === true ? 'Device authorized.' : 'That code could not be approved. Check the code and try again.';
          if (!err && result === true) field.value = '';
        });
      }).button;
      var note = el('p', 'muted small');
      node.appendChild(note);
      var focus = new ui.Focus(page, [zone(field), zone(submit)]);
      field.addEventListener('keydown', function (e) {
        if (e.keyCode === Z.KEYS.enter || e.keyCode === Z.KEYS.imeDone) {
          e.preventDefault();
          e.stopPropagation();
          field.blur();
          focus.start(1);
        }
      });
      focus.start();
      return { focus: focus };
    }
  };

  Z.screens.confirmSignOut = {
    render: function (page, params) {
      var app = Z.app, changing = params.changeServer;
      var node = panel(page, changing ? 'Change server' : 'Sign Out');
      node.appendChild(el('p', 'muted', changing ? 'Changing servers signs all saved profiles out of this TV.' : 'Sign this profile out of this TV?'));
      var cancel = row(node, 'Cancel', '', function () { app.back(); });
      var confirm = row(node, changing ? 'Change server' : 'Sign Out', '', function () { app.signOut(changing); });
      var focus = new ui.Focus(page, [zone(cancel.button), zone(confirm.button)]);
      focus.start();
      return { focus: focus };
    }
  };

  Z.screens.settingsLink = {
    render: function (page, params) {
      var node = panel(page, params.title);
      node.appendChild(el('p', 'muted', 'Open this page on your phone or computer.'));
      node.appendChild(el('p', 'settings-address', params.address));
      var back = row(node, 'Back', '', function () { Z.app.back(); });
      var focus = new ui.Focus(page, [zone(back.button)]);
      focus.start();
      return { focus: focus };
    }
  };
})(this);
