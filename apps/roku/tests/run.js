#!/usr/bin/env node
// Runs the BrightScript unit tests in tests/*.test.brs against the pure
// libraries in source/lib with the brs-node interpreter (no Roku needed).
// Each test file defines `sub Test_<Name>()` subs that call Assert* helpers.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const libs = ['Utils', 'DeviceProfile', 'Jellyfin', 'HomeLogic', 'LiveTvStreams', 'Quality', 'LiveGuide', 'LiveEvents', 'Extras', 'NotificationReads', 'PickTogether', 'PlayerExtras', 'Store'].map((n) => path.join(root, 'source', 'lib', `${n}.brs`));
const testFiles = fs.readdirSync(__dirname).filter((f) => f.endsWith('.test.brs')).sort().map((f) => path.join(__dirname, f));
const names = [];
for (const file of testFiles) {
  for (const m of fs.readFileSync(file, 'utf8').matchAll(/^\s*sub\s+(Test_\w+)\s*\(/gim)) names.push(m[1]);
}
if (names.length === 0) {
  console.error('No tests found.');
  process.exit(1);
}

const main = [
  'sub Main()',
  '    m.failures = 0',
  '    m.checks = 0',
  ...names.map((n) => `    m.current = "${n}"\n    ${n}()`),
  '    print "RESULT checks=" + m.checks.toStr() + " failures=" + m.failures.toStr()',
  'end sub',
].join('\n');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zorofin-roku-tests-'));
const mainFile = path.join(dir, 'Main.brs');
fs.writeFileSync(mainFile, main + '\n');

const cli = path.join(root, 'node_modules', '.bin', 'brs-cli');
const run = spawnSync(cli, [mainFile, path.join(__dirname, 'Assert.brs'), ...libs, ...testFiles], {
  encoding: 'utf8',
  timeout: 120000,
});
fs.rmSync(dir, { recursive: true, force: true });
const output = `${run.stdout || ''}${run.stderr || ''}`;
const clean = output.replace(/\u001b\[[0-9;]*m/g, '');
for (const line of clean.split('\n')) {
  if (line.startsWith('FAIL') || /error/i.test(line)) console.log(line);
}
const result = clean.match(/RESULT checks=(\d+) failures=(\d+)/);
if (!result) {
  console.error('The test run did not finish:\n' + clean.split('\n').slice(-20).join('\n'));
  process.exit(1);
}
console.log(`${names.length} tests, ${result[1]} checks, ${result[2]} failures`);
process.exit(result[2] === '0' ? 0 : 1);
