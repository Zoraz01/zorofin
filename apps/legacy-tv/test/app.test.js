'use strict';
// Run: node --test apps/legacy-tv/test/app.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'tizen', 'js', 'core.js'), 'utf8');
const sandbox = {};
vm.runInNewContext(source, sandbox);
const L = sandbox.Z.util;

test('public hostnames try https first, then http and :8096', () => {
  assert.deepStrictEqual(Array.from(L.candidates(' media.example.com/ ')), ['https://media.example.com', 'http://media.example.com', 'http://media.example.com:8096']);
});
test('LAN addresses try http first', () => {
  assert.deepStrictEqual(Array.from(L.candidates('192.168.1.20')), ['http://192.168.1.20', 'http://192.168.1.20:8096', 'https://192.168.1.20']);
  assert.deepStrictEqual(Array.from(L.candidates('192.168.1.20:8096')), ['http://192.168.1.20:8096', 'https://192.168.1.20:8096']);
});
test('explicit scheme and /web suffix are respected', () => {
  assert.deepStrictEqual(Array.from(L.candidates('https://media.example.org/jf/web/index.html')), ['https://media.example.org/jf']);
  assert.deepStrictEqual(Array.from(L.candidates('')), []);
});
test('server probe accepts Jellyfin public info only', () => {
  assert.ok(L.looksLikeJellyfin('{"Id":"abc","ProductName":"Jellyfin Server","Version":"10.11.0"}'));
  assert.ok(!L.looksLikeJellyfin('<html>'));
  assert.ok(!L.looksLikeJellyfin('{"ok":true}'));
});
test('app scripts parse as ES5 for Tizen 3.0 (Chromium 47)', () => {
  const acorn = require('acorn');
  const dir = path.join(__dirname, '..', 'tizen', 'js');
  for (const name of fs.readdirSync(dir).filter(n => n.endsWith('.js'))) {
    acorn.parse(fs.readFileSync(path.join(dir, name), 'utf8'), { ecmaVersion: 5, sourceType: 'script' });
  }
});
test('scene avatars match the other apps (sum of characters mod 7)', () => {
  assert.strictEqual(L.sceneAvatar('a'), 'lastlight');
  assert.strictEqual(L.sceneAvatar('ABC'), L.sceneAvatar('abc'));
});
