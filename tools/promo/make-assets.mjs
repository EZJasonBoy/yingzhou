// Turns the screenshots of integration_test/promo_shots_test.dart (dist/promo/build/shots/*.png; the THEME=light run
// in shots-light, as light-*.jpg) and of the web remote (tools/remote/screenshots.mjs into remote-shots) into the
// JPEGs the film and the portfolio load (dist/promo/build/img), and a contact sheet to look them over.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const build = process.env.PROMO_BUILD || resolve(here, '../../dist/promo/build');
const shots = join(build, 'shots'), img = join(build, 'img');
mkdirSync(img, { recursive: true });

const convert = (dir, prefix) => {
  if (!existsSync(dir)) return [];
  const list = readdirSync(dir).filter((f) => f.endsWith('.png')).map((f) => f.slice(0, -4));
  for (const n of list) {
    const scale = n.startsWith('desktop') ? 'scale=2400:-2:flags=lanczos' : 'scale=iw:ih';
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', join(dir, `${n}.png`), '-vf', scale, '-q:v', '2', join(img, `${prefix}${n}.jpg`)]);
  }
  return list;
};
const names = convert(shots, '');
const extra = [...convert(join(build, 'shots-light'), 'light-'), ...convert(join(build, 'remote-shots'), '')];
// Contact sheets: wide shots, tall shots.
const sheet = (list, out, h, cols) => {
  if (!list.length) return;
  const args = ['-y', '-loglevel', 'error'];
  list.forEach((n) => args.push('-i', join(img, `${n}.jpg`)));
  const rows = Math.ceil(list.length / cols);
  const w = Math.round((h * 16) / 9);
  const f = list.map((_, i) => `[${i}:v]scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:color=0x202028[v${i}]`).join(';');
  const layout = list.map((_, i) => `${(i % cols) * (w + 8)}_${Math.floor(i / cols) * (h + 8)}`).join('|');
  args.push('-filter_complex', `${f};${list.map((_, i) => `[v${i}]`).join('')}xstack=inputs=${list.length}:layout=${layout}:fill=0x101014`, '-q:v', '3', join(build, out));
  if (list.length > 1) execFileSync('ffmpeg', args);
  void rows;
};
sheet(names.filter((n) => n.startsWith('desktop')), 'sheet-desktop.jpg', 450, 3);
sheet(names.filter((n) => !n.startsWith('desktop')), 'sheet-devices.jpg', 450, 4);
console.log(`assets done: ${names.length + extra.length} images`);
