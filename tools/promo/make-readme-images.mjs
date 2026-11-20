// The images the README shows: framed screenshots (readme/boards.html), a banner and a social preview cut from the
// film's title, and the brand board (page 3 of the portfolio). Needs the promo source running, dist/promo/build/img
// (make-assets.mjs) and dist/promo/build/portfolio-pages (make-portfolio.mjs).
//   -> docs/screenshots/{desktop,mobile,tv,live}.jpg, docs/brand/{yingzhou-hero,brand-board}.jpg, docs/brand/social-preview.png
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launch } from './lib/cdp.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const build = process.env.PROMO_BUILD || join(repo, 'dist/promo/build');
const base = process.env.PROMO_URL || 'http://127.0.0.1:5199';
const shots = join(repo, 'docs/screenshots'), brand = join(repo, 'docs/brand');
mkdirSync(shots, { recursive: true });

const BOARDS = { desktop: [1600, 1000], mobile: [1600, 780], tv: [1600, 860], live: [1600, 960] };
const browser = await launch({ width: 1920, height: 1080, profileDir: join(build, '.chrome-readme') });
try {
  for (const [id, [w, h]] of Object.entries(BOARDS)) {
    const page = await browser.newPage({ width: w, height: h });
    await page.goto(`${base}/readme/boards.html?b=${id}`);
    writeFileSync(join(shots, `${id}.jpg`), await page.shot({ format: 'jpeg', quality: 86 }));
    await page.close();
  }
  // The film's title, held: the boat and the name.
  const film = await browser.newPage({ width: 1920, height: 1080 });
  await film.goto(`${base}/film/index.html?hold=1`);
  await film.eval('window.__seek(15.6)');
  const frame = join(build, 'readme-title.png');
  writeFileSync(frame, await film.shot());
  await film.close();
  const ff = (args) => execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...args]);
  ff(['-i', frame, '-vf', 'crop=1920:720:0:150,scale=1600:600:flags=lanczos', '-q:v', '3', join(brand, 'yingzhou-hero.jpg')]);
  ff(['-i', frame, '-vf', 'crop=1920:960:0:60,scale=1280:640:flags=lanczos', join(brand, 'social-preview.png')]);
  copyFileSync(join(build, 'portfolio-pages/p-03.jpg'), join(brand, 'brand-board.jpg'));
} finally {
  await browser.close();
}
console.log('readme images done');
