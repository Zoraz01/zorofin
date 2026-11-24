// Export the existing web illustrations into both native asset catalogs.
// Run from any directory; --check reports stale/missing exports without writing.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const webPath = path.resolve(root, '../../branding/zorofin-live-events.js');
const {sportGraphic} = require(webPath);
const webSource = fs.readFileSync(webPath, 'utf8');
const coreSource = fs.readFileSync(path.join(root, 'Core/Sources/ZorofinCore/LiveEvents.swift'), 'utf8');
const sports = coreSource.match(/public enum LiveSport[^\{]+\{\s*case ([^\n]+)/)[1].split(',').map(x => x.trim());
// The colors live with the web component. Extract only its authored graphic rules,
// so regenerating after a web artwork edit cannot silently keep an old palette.
const rules = [...webSource.matchAll(/'([^'\n]*\.zle-sport-graphic)\{([^'\n]+)\}'/g)];
const defaultRule = rules.find(rule => !rule[1].includes('[data-sport='));
assert.ok(defaultRule, 'Missing default web artwork palette');
const scenes = new Set();
let bytes = 0;
for (const sport of sports) {
  assert.match(sport, /^[a-z]+$/);
  const rule = rules.find(rule => rule[1].includes(`[data-sport=${sport}] `)) || defaultRule;
  const [, ink] = rule[2].match(/(?:^|;)color:(#[a-f0-9]{6});/);
  const [, top, bottom] = rule[2].match(/background:linear-gradient\(135deg,(#[a-f0-9]{6}),(#[a-f0-9]{6})\)/);
  const scene = sportGraphic(sport);
  assert.ok(!scenes.has(scene), `Missing distinct illustration for ${sport}`);
  scenes.add(scene);
  // SVGs are app-owned vector art, not remote or guide-provided markup.
  assert.ok(!/<(?:script|image|foreignObject)\b|(?:href|url\s*\()/i.test(scene));
  // CSS 135 degrees uses the projected diagonal of this 640x360 viewport.
  const background = `<defs><linearGradient id="background" gradientUnits="userSpaceOnUse" x1="70" y1="-70" x2="570" y2="430"><stop stop-color="${top}"/><stop offset="1" stop-color="${bottom}"/></linearGradient></defs><path fill="url(#background)" d="M0 0h640v360H0z"/>`;
  const svg = scene.replace('viewBox=', 'width="640" height="360" viewBox=')
    .replace(' aria-hidden="true" focusable="false"', '')
    .replace(/currentColor/g, ink).replace('><g', `>${background}<g`) + '\n';
  const name = `LiveSport-${sport}`;
  const contents = JSON.stringify({images: [{filename: `${name}.svg`, idiom: 'universal'}],
    info: {author: 'xcode', version: 1}, properties: {'preserves-vector-representation': true, 'template-rendering-intent': 'original'}}, null, 2) + '\n';
  for (const platform of ['iOS', 'tvOS']) {
    const folder = path.join(root, `Resources/${platform}/Assets.xcassets/${name}.imageset`);
    for (const [file, data] of [[`${name}.svg`, svg], ['Contents.json', contents]]) {
      const destination = path.join(folder, file);
      if (process.argv.includes('--check')) {
        assert.equal(fs.readFileSync(destination, 'utf8'), data, `Regenerate ${destination}`);
      } else {
        fs.mkdirSync(folder, {recursive: true});
        fs.writeFileSync(destination, data);
      }
      bytes += Buffer.byteLength(data);
    }
  }
}
console.log(`${process.argv.includes('--check') ? 'Checked' : 'Exported'} ${sports.length} sport illustrations for iOS and tvOS (${bytes} source bytes).`);
