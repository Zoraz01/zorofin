// Generate a portable Swift regression fixture from the server's seasonal calendar.
// Run from the repository root after changing support-agent/curated-seasons.js.
const fs = require('node:fs');
const path = require('node:path');
const {themePlan} = require('../../../support-agent/curated-seasons.js');
const timeZone = 'America/New_York';
const cases = [];
// Two full years at 17:00 UTC, plus evenings that are already tomorrow in UTC.
for (let at = Date.UTC(2026, 0, 1, 17); at < Date.UTC(2028, 0, 1); at += 86400000) cases.push(at);
for (const text of ['2027-01-01T03:00:00Z', '2026-07-05T02:30:00Z', '2026-11-01T03:59:00Z', '2026-11-27T04:30:00Z']) cases.push(Date.parse(text));
const fixture = {generatedFrom: 'support-agent/curated-seasons.js', timeZone,
  cases: cases.map(at => ({at: new Date(at).toISOString(), plan: themePlan(at, {timeZone})}))};
const output = path.join(__dirname, '../Core/Tests/ZorofinCoreTests/Fixtures/seasonal-plan-parity.json');
fs.writeFileSync(output, JSON.stringify(fixture) + '\n');
console.log(`Wrote ${fixture.cases.length} seasonal plan cases to ${path.relative(process.cwd(), output)}`);
