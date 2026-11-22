// Turns the prototype boards (docs/design/prototypes/canvas/*.dc.html, made for a Design canvas) into pages any
// browser opens, and a picture of each:
//
//   node tools/design/export-prototypes.mjs
//
// For every board in canvas.json it writes docs/design/prototypes/<board>.html (the canvas's own script taken out,
// its image addresses pointed at the design system's assets) and <board>.jpg (rendered at the board's size, twice
// the pixels). Needs Chrome or Edge (tools/promo/lib/cdp.mjs). The fonts come from Google Fonts: offline the
// pictures fall back to the system's fonts.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { launch } from '../promo/lib/cdp.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const dir = join(root, 'docs/design/prototypes');
const canvas = JSON.parse(readFileSync(join(dir, 'canvas/canvas.json'), 'utf8'));

// The canvas's uploaded images and the files they were uploaded from, relative to docs/design/prototypes.
const images = {
  fe6f97f08daa9b59c906a0df93c38058: '../system/assets/Logos/yingzhou-logo-small.svg',
  '4acb575712e2fcc2835eef4d48d2b281': '../system/assets/Imagery/player-frame.jpg',
  '1f5457874074ae945f6d04490f9e6cca': '../system/assets/Imagery/poster-1.jpg',
  '03400aa47610c4e40e8c177cc8bc05b8': '../system/assets/Imagery/poster-5.jpg',
  b61eee520c6b329701e77c46a36b294e: '../system/assets/Imagery/poster-8.jpg',
  '2bf257fdd4c4d2a8f3c082469a04c224': '../system/assets/Imagery/poster-14.jpg',
};

function standalone(source, board) {
  return source
    .replace(/<script src="\.\/support\.js"><\/script>\n?/, '')
    .replace(/<script type="text\/x-dc"[\s\S]*?<\/script>\n?/, '')
    .replace(/<\/?(x-dc|helmet)>\n?/g, '')
    .replace(/\/_blob\/([0-9a-f]{32})/g, (m, id) => images[id] ?? m)
    // Links between boards go to the exported pages.
    .replace(/href="([A-Za-z-]+)\.dc\.html"/g, 'href="$1.html"')
    .replace('<head>', `<head>\n<!-- Exported from canvas/${board} by tools/design/export-prototypes.mjs; edit the canvas file, not this one. -->`);
}

mkdirSync(dir, { recursive: true });
const browser = await launch({ width: 1440, height: 900, profileDir: join(root, 'dist/design/export-profile') });
try {
  for (const [board, spec] of Object.entries(canvas.boards)) {
    const name = board.replace(/\.dc\.html$/, '');
    const html = standalone(readFileSync(join(dir, 'canvas', board), 'utf8'), board);
    const out = join(dir, `${name}.html`);
    writeFileSync(out, html);
    const page = await browser.newPage({ width: spec.w, height: spec.h, scale: 2 });
    await page.goto(pathToFileURL(out).href);
    writeFileSync(join(dir, `${name}.jpg`), await page.shot({ format: 'jpeg', quality: 86 }));
    if (page.errors.length) console.warn(`${name}: ${page.errors.join(' | ')}`);
    await page.close();
    console.log(`${name}: ${spec.w}×${spec.h}`);
  }
} finally {
  await browser.close();
}
