// Tiles stills (dist/promo/build/stills/t-*.png) four to a sheet, to look a render over: node tools/promo/sheet.mjs [dir]
import { execFileSync } from 'node:child_process';
import { mkdirSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const build = process.env.PROMO_BUILD || resolve(here, '../../dist/promo/build');
const dir = resolve(process.argv[2] || join(build, 'stills'));
const out = join(build, 'peek');
mkdirSync(out, { recursive: true });
for (const f of readdirSync(out).filter((f) => f.startsWith('sheet-'))) rmSync(join(out, f));
const files = readdirSync(dir).filter((f) => f.endsWith('.png')).sort();
for (let i = 0; i < files.length; i += 4) {
  const group = files.slice(i, i + 4), args = ['-y', '-loglevel', 'error'];
  group.forEach((f) => args.push('-i', join(dir, f)));
  const label = (f) => f.replace(/^t-0*/, '').replace('.png', 's');
  const filters = group.map((f, k) => `[${k}:v]scale=960:540,drawtext=text='${label(f)}':x=16:y=12:fontsize=22:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=6[v${k}]`).join(';');
  const layout = ['0_0', '960_0', '0_540', '960_540'].slice(0, group.length).join('|');
  const stackIn = group.map((_, k) => `[v${k}]`).join('');
  args.push('-filter_complex', group.length > 1 ? `${filters};${stackIn}xstack=inputs=${group.length}:layout=${layout}:fill=black` : filters.replace('[v0]', ''), '-q:v', '3', join(out, `sheet-${String(i / 4 + 1).padStart(2, '0')}.jpg`));
  execFileSync('ffmpeg', args);
}
console.log(`${Math.ceil(files.length / 4)} sheets in ${out}`);
