// Builds the portfolio PDF (portfolio/index.html) -> dist/promo/yingzhou-portfolio.pdf, plus a JPEG of every page in
// dist/promo/build/portfolio-pages to look them over. Needs the promo source running and dist/promo/build/img filled
// (make-assets.mjs). Stills of the film are taken from the film page itself.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launch } from './lib/cdp.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const build = process.env.PROMO_BUILD || resolve(here, '../../dist/promo/build');
const base = process.env.PROMO_URL || 'http://127.0.0.1:5199';
const outArg = process.argv.indexOf('--out');
const out = outArg > 0 ? resolve(process.argv[outArg + 1]) : resolve(here, '../../dist/promo/yingzhou-portfolio.pdf');
const img = join(build, 'img'), pages = join(build, 'portfolio-pages');
mkdirSync(img, { recursive: true });
mkdirSync(pages, { recursive: true });

const browser = await launch({ width: 1920, height: 1080, profileDir: join(build, '.chrome-portfolio') });
try {
  // The film's world without its text, as backgrounds; then six moments of the film as it is.
  const still = async (url, shots) => {
    const page = await browser.newPage({ width: 1920, height: 1080 });
    await page.goto(base + url);
    for (const [t, name] of shots) {
      await page.eval(`window.__seek(${t})`);
      writeFileSync(join(img, `${name}.jpg`), await page.shot({ format: 'jpeg', quality: 93 }));
    }
    await page.close();
  };
  if (!process.argv.includes('--no-stills')) {
    await still('/film/index.html?plain=1&hold=1', [[15.5, 'plate-title'], [70.6, 'plate-dawn']]);
    await still('/film/index.html?hold=1', [[15.6, 'film-1'], [22.6, 'film-2'], [27.6, 'film-3'], [46.6, 'film-4'], [64.9, 'film-5'], [70.4, 'film-6']]);
  }

  const page = await browser.newPage({ width: 1600, height: 900 });
  await page.goto(`${base}/portfolio/index.html`);
  const count = await page.eval("document.querySelectorAll('.page').length");
  for (let i = 0; i < count; i++) {
    const jpg = await page.shot({ format: 'jpeg', quality: 88, clip: { x: 0, y: i * 900, width: 1600, height: 900, scale: 1 } });
    writeFileSync(join(pages, `p-${String(i + 1).padStart(2, '0')}.jpg`), jpg);
  }
  const pdf = await page.pdf({ paperWidth: 1600 / 96, paperHeight: 900 / 96, marginTop: 0, marginBottom: 0, marginLeft: 0, marginRight: 0 });
  writeFileSync(out, pdf);
  if (page.errors.length) console.log('page errors:\n' + [...new Set(page.errors)].join('\n'));
  console.log(`wrote ${out}: ${count} pages, ${(pdf.length / 1048576).toFixed(1)} MB`);
} finally {
  await browser.close();
}
