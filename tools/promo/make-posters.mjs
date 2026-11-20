// Renders the catalogue's posters (posters/poster.html) to dist/promo/build/posters/<id>.jpg.
// Needs the promo source running: node tools/promo/server.mjs
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CATALOG } from './catalog.mjs';
import { launch } from './lib/cdp.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const build = process.env.PROMO_BUILD || resolve(here, '../../dist/promo/build');
const base = process.env.PROMO_URL || 'http://127.0.0.1:5199';
const only = process.argv.slice(2).map(Number);

mkdirSync(join(build, 'posters'), { recursive: true });
const browser = await launch({ width: 600, height: 840, profileDir: join(build, '.chrome-posters') });
const page = await browser.newPage({ width: 600, height: 840 });
for (const c of CATALOG) {
  if (only.length && !only.includes(c.id)) continue;
  await page.goto(`${base}/posters/poster.html?id=${c.id}`);
  writeFileSync(join(build, 'posters', `${c.id}.jpg`), await page.shot({ format: 'jpeg', quality: 93 }));
}
if (page.errors.length) console.log('page errors:\n' + page.errors.join('\n'));
// A contact sheet to look at them together.
await page.size(1860, 1560);
await page.goto(`${base}/posters/sheet.html`);
writeFileSync(join(build, 'posters-sheet.jpg'), await page.shot({ format: 'jpeg', quality: 88 }));
await browser.close();
console.log('posters done');
