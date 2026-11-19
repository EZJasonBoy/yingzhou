// Renders the app icons for every platform from docs/brand/yingzhou-logo*.svg with headless Edge/Chrome.
//
//   node tools/brand/render-icons.mjs
//
// Writes the Windows .ico, macOS AppIcon set, Android launcher icons and web icons into client/,
// and the Windows installer's wizard images into tools/installer/.
// Set TVBOX_BROWSER to the browser executable when it is not in the usual place.
//
// Every size is drawn by the browser from the vector logo at its own pixel size (not scaled down from a big
// bitmap), all on one page; one screenshot of that page is then cut into the separate PNG files.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const brand = path.join(root, 'docs/brand');
const client = path.join(root, 'client');
const browser = process.env.TVBOX_BROWSER || [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/chromium',
].find((p) => fs.existsSync(p));
if (!browser) throw new Error('no Edge/Chrome found; set TVBOX_BROWSER');

const dataUrl = (name) => 'data:image/svg+xml;base64,' + fs.readFileSync(path.join(brand, name)).toString('base64');
const FULL = dataUrl('yingzhou-logo.svg');
// 16-32 px: no wave, bigger sail and hull, so the icon still reads in a taskbar.
const SMALL = dataUrl('yingzhou-logo-small.svg');

// Every image to cut out: [key, size, logo, inset]. The inset is a transparent margin (macOS draws icons that way).
const jobs = [];
const art = (size) => jobs.push([`art${size}`, size, size <= 32 ? SMALL : FULL, 0]);
[16, 20, 24, 32, 40, 48, 64, 72, 96, 128, 144, 192, 256, 512].forEach(art);
// The corner image of the Windows installer's wizard: the square it is drawn in at 100, 125, 150, 200 and 250 % scaling.
const WIZARD = [58, 77, 97, 124, 159];
WIZARD.forEach(art);
[16, 32, 64, 128, 256, 512, 1024].forEach((size) => jobs.push([`mac${size}`, size, size <= 32 ? SMALL : FULL, size <= 32 ? 0.04 : 0.1]));

// Lay them out in rows no wider than 2100 px.
const GAP = 8;
let x = 0, y = 0, rowHeight = 0, width = 0;
const placed = jobs.map(([key, size, logo, inset]) => {
  if (x + size > 2100) { x = 0; y += rowHeight + GAP; rowHeight = 0; }
  const p = { key, size, logo, inset, x, y };
  x += size + GAP; rowHeight = Math.max(rowHeight, size); width = Math.max(width, x);
  return p;
});
const height = y + rowHeight;

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'yingzhou-icons-'));
const html = path.join(work, 'atlas.html');
const shot = path.join(work, 'atlas.png');
fs.writeFileSync(html, '<!doctype html><html><body style="margin:0;background:transparent">' + placed.map((p) => {
  const pad = Math.round(p.size * p.inset);
  return `<img src="${p.logo}" style="position:absolute;left:${p.x + pad}px;top:${p.y + pad}px;width:${p.size - 2 * pad}px;height:${p.size - 2 * pad}px">`;
}).join('') + '</body></html>');

execFileSync(browser, ['--headless=new', '--disable-gpu', '--no-first-run', '--hide-scrollbars', '--force-device-scale-factor=1',
  `--user-data-dir=${path.join(work, 'profile')}`, '--default-background-color=00000000',
  `--window-size=${width},${height}`, `--screenshot=${shot}`, 'file:///' + html.replace(/\\/g, '/')], { stdio: 'ignore' });
// Edge's launcher can return before the browser it started has written the file.
for (let i = 0; i < 100 && !fs.existsSync(shot); i++) execFileSync(process.execPath, ['-e', 'setTimeout(()=>{},200)']);
let last = -1;
while (fs.existsSync(shot) && fs.statSync(shot).size !== last) { last = fs.statSync(shot).size; execFileSync(process.execPath, ['-e', 'setTimeout(()=>{},300)']); }
if (!fs.existsSync(shot)) throw new Error('the browser wrote no screenshot');

// ---- minimal PNG reading (8-bit RGB / RGBA, not interlaced) and writing (RGBA) ----
function decode(buf) {
  let pos = 8, w = 0, h = 0, type = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), kind = buf.toString('ascii', pos + 4, pos + 8), body = buf.subarray(pos + 8, pos + 8 + len);
    if (kind === 'IHDR') {
      w = body.readUInt32BE(0); h = body.readUInt32BE(4); type = body[9];
      if (body[8] !== 8 || body[12] !== 0 || (type !== 6 && type !== 2)) throw new Error('unexpected PNG format');
    } else if (kind === 'IDAT') idat.push(body);
    pos += 12 + len;
  }
  const bpp = type === 6 ? 4 : 3, stride = w * bpp, raw = zlib.inflateSync(Buffer.concat(idat));
  const out = Buffer.alloc(w * h * 4), prev = Buffer.alloc(stride), cur = Buffer.alloc(stride);
  for (let r = 0; r < h; r++) {
    const f = raw[r * (stride + 1)];
    raw.copy(cur, 0, r * (stride + 1) + 1, (r + 1) * (stride + 1));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? cur[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      let v = cur[i];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      cur[i] = v & 255;
    }
    for (let px = 0; px < w; px++) {
      out[(r * w + px) * 4] = cur[px * bpp]; out[(r * w + px) * 4 + 1] = cur[px * bpp + 1]; out[(r * w + px) * 4 + 2] = cur[px * bpp + 2];
      out[(r * w + px) * 4 + 3] = bpp === 4 ? cur[px * bpp + 3] : 255;
    }
    cur.copy(prev);
  }
  return { w, h, rgba: out };
}

function chunk(kind, body) {
  const head = Buffer.alloc(8); head.writeUInt32BE(body.length, 0); head.write(kind, 4, 'ascii');
  const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(Buffer.concat([Buffer.from(kind, 'ascii'), body])) >>> 0, 0);
  return Buffer.concat([head, body, crc]);
}

function encode(rgba, w, h) {
  const raw = Buffer.alloc(h * (w * 4 + 1));
  for (let r = 0; r < h; r++) rgba.copy(raw, r * (w * 4 + 1) + 1, r * w * 4, (r + 1) * w * 4);
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

const atlas = decode(fs.readFileSync(shot));
if (atlas.w < width || atlas.h < height) throw new Error(`screenshot is ${atlas.w}x${atlas.h}, page is ${width}x${height}`);
const png = {}, pixels = {};
for (const p of placed) {
  const out = Buffer.alloc(p.size * p.size * 4);
  for (let r = 0; r < p.size; r++) atlas.rgba.copy(out, r * p.size * 4, ((p.y + r) * atlas.w + p.x) * 4, ((p.y + r) * atlas.w + p.x + p.size) * 4);
  pixels[p.key] = out;
  png[p.key] = encode(out, p.size, p.size);
}

/** A 32-bit .bmp with an alpha channel that is not premultiplied (Inno Setup: WizardImageAlphaFormat=defined). */
function bmp(size) {
  const rgba = pixels[`art${size}`], head = Buffer.alloc(54), body = Buffer.alloc(size * size * 4);
  head.write('BM', 0, 'ascii'); head.writeUInt32LE(head.length + body.length, 2); head.writeUInt32LE(head.length, 10);
  head.writeUInt32LE(40, 14); head.writeInt32LE(size, 18); head.writeInt32LE(size, 22);
  head.writeUInt16LE(1, 26); head.writeUInt16LE(32, 28); head.writeUInt32LE(body.length, 34);
  // Rows bottom-up, pixels as blue, green, red, alpha.
  for (let r = 0; r < size; r++) for (let x = 0; x < size; x++) {
    const from = (r * size + x) * 4, to = ((size - 1 - r) * size + x) * 4;
    body[to] = rgba[from + 2]; body[to + 1] = rgba[from + 1]; body[to + 2] = rgba[from]; body[to + 3] = rgba[from + 3];
  }
  return Buffer.concat([head, body]);
}

/** An .ico holding PNG images (Windows Vista and later read these). */
function ico(sizes) {
  const header = Buffer.alloc(6 + 16 * sizes.length);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(sizes.length, 4);
  let offset = header.length;
  const images = sizes.map((size, i) => {
    const data = png[`art${size}`], e = 6 + 16 * i;
    header[e] = size >= 256 ? 0 : size; header[e + 1] = size >= 256 ? 0 : size;
    header.writeUInt16LE(1, e + 4); header.writeUInt16LE(32, e + 6);
    header.writeUInt32LE(data.length, e + 8); header.writeUInt32LE(offset, e + 12);
    offset += data.length;
    return data;
  });
  return Buffer.concat([header, ...images]);
}

const write = (rel, bytes, base = client) => { fs.writeFileSync(path.join(base, rel), bytes); console.log('wrote', path.relative(root, path.join(base, rel))); };
write('windows/runner/resources/app_icon.ico', ico([16, 20, 24, 32, 40, 48, 64, 128, 256]));
for (const size of [16, 32, 64, 128, 256, 512, 1024]) write(`macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png`, png[`mac${size}`]);
for (const [dir, size] of [['mdpi', 48], ['hdpi', 72], ['xhdpi', 96], ['xxhdpi', 144], ['xxxhdpi', 192]]) write(`android/app/src/main/res/mipmap-${dir}/ic_launcher.png`, png[`art${size}`]);
write('web/favicon.png', png.art32);
for (const size of [192, 512]) {
  write(`web/icons/Icon-${size}.png`, png[`art${size}`]);
  write(`web/icons/Icon-maskable-${size}.png`, png[`art${size}`]);
}
for (const size of WIZARD) write(`tools/installer/wizard-${size}.bmp`, bmp(size), root);
write('yingzhou-logo-512.png', png.art512, brand);
write('yingzhou-icon-32.png', png.art32, brand);
fs.rmSync(work, { recursive: true, force: true });
