// Renders the Apple app's Live TV sport artwork to the PNGs in
// assets/images. Run from apps/tv with Node and Playwright:
//   node tool/render_sport_art.js <Assets.xcassets dir> assets/images
// The xcassets directory is apps/apple/Resources/tvOS/Assets.xcassets on the
// release/zorofin branch.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
(async () => {
  const root = process.argv[2], out = process.argv[3];
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 640, height: 360 } });
  for (const sport of ['baseball','basketball','combat','cricket','event','football','golf','hockey','racing','soccer','tennis']) {
    const svg = fs.readFileSync(path.join(root, `LiveSport-${sport}.imageset/LiveSport-${sport}.svg`), 'utf8');
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg.replace('<svg', '<svg width="640" height="360"')}</body></html>`);
    await page.locator('svg').screenshot({ path: path.join(out, `live-sport-${sport}.png`), omitBackground: true });
  }
  await browser.close();
})();
