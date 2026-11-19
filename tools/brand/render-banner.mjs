// Renders the Android TV launcher banner from docs/brand/yingzhou-banner.svg with headless Edge/Chrome.
//
//   node tools/brand/render-banner.mjs
//
// Writes client/android/app/src/main/res/drawable-xhdpi/banner.png (320 x 180, the size Android TV asks for) and
// drawable-xxhdpi/banner.png (480 x 270) for sharper TVs. Each is drawn by the browser from the vector at its own
// pixel size. Set TVBOX_BROWSER to the browser executable when it is not in the usual place. The text uses the
// system's fonts (Microsoft YaHei / Segoe UI on Windows), so render on Windows for the committed files.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const svg = fs.readFileSync(path.join(root, 'docs/brand/yingzhou-banner.svg'));
const res = path.join(root, 'client/android/app/src/main/res');
const browser = process.env.TVBOX_BROWSER || [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/chromium',
].find((p) => fs.existsSync(p));
if (!browser) throw new Error('no Edge/Chrome found; set TVBOX_BROWSER');

const sleep = (ms) => execFileSync(process.execPath, ['-e', `setTimeout(()=>{},${ms})`]);

/** The PNG's size from its header. */
const sizeOf = (png) => [png.readUInt32BE(16), png.readUInt32BE(20)];

for (const [dir, w, h] of [['drawable-xhdpi', 320, 180], ['drawable-xxhdpi', 480, 270]]) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'yingzhou-banner-'));
  const html = path.join(work, 'banner.html');
  const shot = path.join(work, 'banner.png');
  // Inline, so the system fonts apply (an <img> of an SVG cannot use them on every browser).
  const inline = svg.toString('utf8').replace('<svg ', `<svg style="display:block;width:${w}px;height:${h}px" `);
  fs.writeFileSync(html, `<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0;overflow:hidden">${inline}</body></html>`);
  execFileSync(browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars', '--force-device-scale-factor=1',
    `--user-data-dir=${path.join(work, 'profile')}`, `--window-size=${w},${h}`, `--screenshot=${shot}`,
    'file:///' + html.replace(/\\/g, '/')], { stdio: 'ignore' });
  // Edge's launcher can return before the browser it started has written the file.
  for (let i = 0; i < 100 && !fs.existsSync(shot); i++) sleep(200);
  let last = -1;
  while (fs.existsSync(shot) && fs.statSync(shot).size !== last) { last = fs.statSync(shot).size; sleep(300); }
  if (!fs.existsSync(shot)) throw new Error('the browser wrote no screenshot');
  const png = fs.readFileSync(shot);
  const [sw, sh] = sizeOf(png);
  if (sw !== w || sh !== h) throw new Error(`screenshot is ${sw}x${sh}, wanted ${w}x${h}`);
  fs.mkdirSync(path.join(res, dir), { recursive: true });
  fs.writeFileSync(path.join(res, dir, 'banner.png'), png);
  console.log('wrote', path.relative(root, path.join(res, dir, 'banner.png')));
  // The browser may still hold its profile for a moment; a leftover temporary folder is no harm.
  try {
    fs.rmSync(work, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 });
  } catch {
    console.log('could not remove', work);
  }
}
