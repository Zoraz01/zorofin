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
    const focusedText = () => page.evaluate(() => { const f = document.querySelector('.focused'); return f ? f.textContent : ''; });
    const toTab = async name => {
      await press(page, 'up', 6);
      await press(page, 'left', 6);
      for (let i = 0; i < 7 && (await focusedText()).indexOf(name) < 0; i++) await press(page, 'right');
      await press(page, 'enter');
      await page.waitFor(1200);
    };
    await toTab('Live TV');
    await press(page, 'down');
    await shot('12-live-tv');
    await toTab('Claude Test');
    await shot('13-profile-menu');
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
    await page.waitFor(900);
    await press(page, 'down');
    await press(page, 'enter');
    await page.waitFor(700);
    await page.evaluate(() => { const f = document.querySelectorAll('input'); f[0].value = 'Sam'; f[1].value = 'x'; });
    await press(page, 'down', 2);
    await press(page, 'enter');
    await page.waitFor(1500);
    await page.goto(base);
    await page.waitFor(1200);
    await shot('17-whos-watching');
    await press(page, 'enter');
    await page.waitFor(1500);
    await press(page, 'down', 3);
    await page.waitFor(600);
    await shot('18-home-sports');
  } finally {
    await browser.close();
  }
  return errors;
}

(async () => {
  const server = mock.start(8730, 8731);
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
