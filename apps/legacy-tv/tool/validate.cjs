#!/usr/bin/env node
'use strict';
// Screenshot validation in the same browser engine as 2020 Samsung TVs
// (Chromium 69, Tizen 5.5). Drives the app with remote-control keys against
// tool/mock-server.cjs and saves one PNG per step at 1920x1080 and 1280x720.
// Fails on any page error or console error.
//
// Setup (once, outside the repo; old Chromium is used only for this check):
//   mkdir -p ~/legacy-tv-check && cd ~/legacy-tv-check
//   curl -o c.zip https://storage.googleapis.com/chromium-browser-snapshots/Linux_x64/576753/chrome-linux.zip && unzip c.zip
//   PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 npm i puppeteer-core@1.7.0
// Run:
//   NODE_PATH=~/legacy-tv-check/node_modules CHROME69=~/legacy-tv-check/chrome-linux/chrome \
//     node apps/legacy-tv/tool/validate.cjs [out-dir]
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const puppeteer = require('puppeteer-core');
const mock = require('./mock-server.cjs');

const out = path.resolve(process.argv[2] || 'legacy-tv-shots');
const chrome = process.env.CHROME69;
if (!chrome) throw new Error('Set CHROME69 to the Chromium 69 binary');
fs.mkdirSync(out, { recursive: true });

const KEY = { left: 37, up: 38, right: 39, down: 40, enter: 13, back: 10009 };
const TIZEN_UA = 'Mozilla/5.0 (SMART-TV; LINUX; Tizen 5.5) AppleWebKit/537.36 (KHTML, like Gecko) 69.0.3497.106/5.5 TV Safari/537.36';

async function press(page, name, times) {
  for (let i = 0; i < (times || 1); i++) {
    await page.evaluate(code => {
      const e = document.createEvent('Event');
      e.initEvent('keydown', true, true);
      e.keyCode = code; e.which = code;
      (document.activeElement || document).dispatchEvent(e);
    }, KEY[name]);
    await page.waitFor(260);
  }
}

async function run(width, height, server) {
  const browser = await puppeteer.launch({ executablePath: chrome, args: ['--no-sandbox', '--disable-gpu', '--window-size=' + width + ',' + height], headless: true });
  const errors = [];
  try {
    const page = await browser.newPage();
    await page.setUserAgent(TIZEN_UA);
    await page.setViewport({ width, height });
    page.on('pageerror', e => errors.push('pageerror: ' + e.message));
    page.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
    const shot = async name => { await page.waitFor(700); await page.screenshot({ path: path.join(out, width + 'x' + height + '-' + name + '.png') }); };
    const base = 'http://127.0.0.1:8730/index.html';

    // First run: connect and sign-in screens.
    await page.goto(base);
    await page.evaluate(() => localStorage.clear());
    await page.goto(base);
    await shot('01-connect');
    await page.evaluate(() => { document.querySelector('input').value = '127.0.0.1:8731'; });
    await press(page, 'down');
    await press(page, 'enter');
    await page.waitFor(800);
    await shot('02-signin');
    await page.evaluate(() => { const f = document.querySelectorAll('input'); f[0].value = 'Claude Test'; f[1].value = 'x'; });
    await press(page, 'down', 2);
    await press(page, 'enter');
    await page.waitFor(1500);
    await shot('03-home');
    await press(page, 'right', 2);
    await shot('04-home-move-right');
    await press(page, 'down');
    await shot('05-home-posters');
    await press(page, 'down', 3);
    await page.waitFor(800);
    await shot('06-home-lower-rows');
    await press(page, 'up', 4);
    await press(page, 'left', 2);
    await press(page, 'enter');
    await page.waitFor(1200);
    await shot('07-details-movie');
    await press(page, 'back');
    await page.waitFor(900);
    await press(page, 'down');
    await press(page, 'right');
    await press(page, 'down');
    await press(page, 'enter');
    await page.waitFor(1500);
    await shot('08-details-series');
    await press(page, 'down', 2);
    await press(page, 'right');
    await shot('09-episodes');
    await press(page, 'back');
    await page.waitFor(900);
    await press(page, 'up', 3);
    await press(page, 'right');
    await press(page, 'enter');
    await page.waitFor(600);
    await page.evaluate(() => { const i = document.querySelector('.search-field'); i.value = 'the'; i.dispatchEvent(new Event('input')); });
    await page.waitFor(1300);
    await press(page, 'down');
    await shot('10-search');
    await press(page, 'up', 2);
    await press(page, 'right');
    await press(page, 'enter');
    await page.waitFor(1500);
    await press(page, 'down', 2);
    await shot('11-movies-grid');
    const layout = await page.evaluate(() => {
      const bad = [];
      document.querySelectorAll('.card').forEach(c => {
        const r = c.querySelector('.card-frame').getBoundingClientRect();
        const poster = /card-poster/.test(c.className);
        const ratio = r.height / r.width;
        if (r.width && Math.abs(ratio - (poster ? 1.5 : 0.5625)) > 0.02) bad.push(c.className + ' ratio ' + ratio.toFixed(3));
      });
      return bad;
    });
    errors.push.apply(errors, layout.map(b => 'layout: ' + b));

    // 1.4 features: Live TV, profile menu, Pick Together, Who's watching.
    const focusedText = () => page.evaluate(() => {
      const focused = document.querySelector('.profile-overlay .focused') || document.querySelector('.focused');
      return focused ? focused.textContent : '';
    });
    const expectScreen = async name => page.waitForFunction(expected => Z.app.screen.name === expected, {}, name);
    const expectFocus = async name => assert.ok((await focusedText()).includes(name), await focusedText());
    const toTab = async name => {
      await press(page, 'up', 6);
      await press(page, 'left', 6);
      for (let i = 0; i < 7 && (await focusedText()).indexOf(name) < 0; i++) await press(page, 'right');
      await expectFocus(name);
      await press(page, 'enter');
      await page.waitFor(600);
    };
    const settings = async name => {
      await toTab(name);
      await page.waitForSelector('.profile-popover');
      await press(page, 'down', 2);
      await expectFocus('Settings');
      await press(page, 'enter');
      await expectScreen('settings');
    };
    await toTab('Live TV');
    await press(page, 'down');
    await shot('12-live-tv');
    await toTab('Claude Test');
    await shot('13-profile-menu');
    await expectFocus('All');
    assert.doesNotMatch(await page.$eval('.profile-popover', el => el.textContent), /sign out|change server|quick connect/i);
    await press(page, 'down');
    await expectFocus('Pick Together');
    await press(page, 'enter');
    await page.waitFor(600);
    await shot('14-pick-together');
    await press(page, 'enter');
    await page.waitFor(900);
    await shot('15-pick-lobby');
    await press(page, 'enter');
    await page.waitFor(900);
    await press(page, 'down');
    await shot('16-pick-matches');
    await press(page, 'back');
    await expectScreen('live');
    await toTab('Claude Test');
    await press(page, 'enter');
    await expectScreen('profiles');
    await press(page, 'right');
    await expectFocus('Add');
    await press(page, 'enter');
    await expectScreen('signin');
    await page.evaluate(() => { const f = document.querySelectorAll('input'); f[0].value = 'Sam'; f[1].value = 'x'; });
    await press(page, 'down', 2);
    await press(page, 'enter');
    await expectScreen('home');
    await page.goto(base);
    await expectScreen('profiles');
    await shot('17-whos-watching');
    await expectFocus('Sam');
    await press(page, 'enter');
    await expectScreen('home');
    await press(page, 'down', 3);
    await shot('18-home-sports');

    // Profile strip, role boundary, and instant preferences on the real screens.
    await settings('Sam');
    const pageText = () => page.$eval('#page', element => element.textContent);
    assert.doesNotMatch(await pageText(), /Manage server/);
    await press(page, 'back');
    await toTab('Sam');
    await expectFocus('Claude Test');
    await press(page, 'enter');
    await page.waitForFunction(() => Z.app.screen.name === 'home' && Z.app.client.session.userName === 'Claude Test');
    await toTab('Claude Test');
    await expectFocus('Sam');
    await shot('19-saved-profile-strip');

    server.state.expired.Sam = true;
    await press(page, 'enter');
    await expectScreen('profiles');
    assert.match(await pageText(), /Sign in again to use Sam/);
    await expectFocus('Sam');
    await press(page, 'enter');
    await expectScreen('signin');
    assert.equal(await page.$eval('input', field => field.value), 'Sam');
    assert.equal(await page.evaluate(() => Z.app.client.session.userName), 'Claude Test');
    delete server.state.expired.Sam;
    await press(page, 'back', 2);
    await expectScreen('home');

    await settings('Claude Test');
    assert.match(await pageText(), /Account.*Home & display.*Playback.*Subtitles.*Help & about.*Manage server.*Sign Out/);
    await shot('20-settings');
    await press(page, 'enter');
    await expectScreen('preferences');
    await press(page, 'down');
    await expectFocus('Quick Connect');
    await press(page, 'enter');
    await expectScreen('authorizeDevice');
    const priorAuthorizations = server.state.authorizations;
    await page.$eval('input', field => { field.value = '482913'; });
    await press(page, 'down');
    await press(page, 'enter');
    await page.waitForFunction(() => /Device authorized/.test(document.querySelector('#page').textContent));
    assert.equal(server.state.authorizations, priorAuthorizations + 1);
    await press(page, 'back', 2);
    await expectScreen('settings');
    await press(page, 'down', 2);
    await press(page, 'enter');
    await expectScreen('preferences');
    await expectFocus('Skip backward');
    assert.match(await pageText(), /In the player.*Skip forward10 seconds.*Show chaptersOff/);
    await press(page, 'down');
    await press(page, 'enter');
    await expectScreen('skipInterval');
    await press(page, 'down', 2);
    await expectFocus('30 seconds');
    await press(page, 'enter');
    await press(page, 'back');
    await expectScreen('settings');
    await press(page, 'enter');
    assert.match(await pageText(), /Skip forward30 seconds/);
    await page.goto(base);
    await expectScreen('profiles');
    await expectFocus('Claude Test');
    await press(page, 'enter');
    await expectScreen('home');
    await settings('Claude Test');
    await press(page, 'down', 2);
    await press(page, 'enter');
    assert.match(await pageText(), /Skip forward30 seconds/);
    await shot('21-playback-persisted');
    await press(page, 'back');
    await press(page, 'down', 2);
    await press(page, 'enter');
    assert.match(await pageText(), /Send playback problem reports to this serverOn/);
    assert.match(await pageText(), /Nothing leaves your server/);
    await shot('22-help-and-reporting');
    if (server.state.clip) await exercisePlayback(page, server, shot);
  } finally {
    await browser.close();
  }
  return errors;
}

async function exercisePlayback(page, server, shot) {
  const movie = server.movies[0];
  const play = () => page.evaluate(item => Z.app.play(item, { fromStart: true }), movie);
  const playing = () => page.waitForFunction(() => {
    const player = Z.app.player;
    return player && player.started && player.video.currentTime > 0.1 && !player.video.paused;
  });
  const count = kind => server.state.reports.filter(report => report.kind === kind).length;
  const error = () => page.evaluate(() => Z.app.player.video.dispatchEvent(new Event('error')));
  const close = async () => {
    await press(page, 'back');
    await page.waitForFunction(() => !Z.app.player);
  };
  const recover = async name => {
    server.state.offline = true;
    await error();
    await page.waitForFunction(() => (document.querySelector('.player-message.visible') || {}).textContent === 'Reconnecting…');
    await shot(name);
    server.state.offline = false;
    await playing();
  };

  await play();
  await playing();
  assert.equal(await page.evaluate(() => document.querySelectorAll('.player-chapter-mark').length), 0);
  await close();

  await page.evaluate(() => Z.app.savePreference('showChapters', true));
  await play();
  await playing();
  await page.waitForSelector('.player-chapter-mark');
  await press(page, 'up');
  await page.waitForSelector('.player-menu');
  assert.match(await page.$eval('.player-menu', menu => menu.textContent), /Opening.*Second act.*Finale/);
  await shot('23-chapters');
  await press(page, 'down');
  await press(page, 'enter');
  await page.waitForFunction(() => Z.app.player.video.currentTime >= 25);
  await press(page, 'right');
  await page.waitForFunction(() => Z.app.player.video.currentTime >= 55);
  await press(page, 'enter');
  assert.ok(await page.evaluate(() => Z.app.player.video.paused));
  await press(page, 'enter');
  await playing();

  const beforeFallback = count('fallback');
  await error();
  await page.waitForFunction(() => Z.app.player.started && Z.app.player.compatibility);
  assert.equal(count('fallback'), beforeFallback + 1);
  assert.equal(server.state.playbackRequests[server.state.playbackRequests.length - 1].direct, false);
  assert.equal(server.state.playbackRequests[server.state.playbackRequests.length - 1].streamCopy, false);
  const priorPosition = await page.evaluate(() => Z.app.player.video.currentTime);

  const beforeRecovery = count('recovered');
  await recover('24-reconnecting-reports-on');
  assert.equal(count('recovered'), beforeRecovery + 1);
  assert.equal(server.state.reports.filter(r => r.kind === 'recovered').slice(-1)[0].platform, 'Samsung TV');
  assert.ok(await page.evaluate(() => Z.app.player.video.currentTime) >= priorPosition - 4);
  await close();

  await page.evaluate(() => Z.app.savePreference('sendPlaybackReports', false));
  await play();
  await playing();
  await recover('25-reconnecting-reports-off');
  assert.equal(count('recovered'), beforeRecovery + 1);
  await close();

  await play();
  await playing();
  server.state.offline = true;
  await error();
  await page.waitForFunction(() => Z.app.player.reconnecting);
  await close();
  server.state.offline = false;
  await page.waitFor(3500);
  assert.equal(await page.evaluate(() => Z.app.player), null);
  await page.evaluate(() => {
    Z.app.savePreference('showChapters', false);
    Z.app.savePreference('sendPlaybackReports', true);
    Z.app.savePreference('skipForward', 10);
  });
}

(async () => {
  const server = mock.start(8730, 8731, process.env.LEGACY_TEST_CLIP);
  let failures = [];
  try {
    for (const [w, h] of [[1920, 1080], [1280, 720]]) {
      const errors = await run(w, h, server);
      errors.forEach(e => console.log(w + 'x' + h + ' ' + e));
      failures = failures.concat(errors);
    }
  } finally {
    server.close();
  }
  console.log(failures.length ? 'FAILED: ' + failures.length + ' problem(s)' : 'OK: screenshots in ' + out);
  process.exit(failures.length ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
