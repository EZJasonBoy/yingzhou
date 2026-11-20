// Renders a page that exposes window.__seek(seconds) to a video, frame by frame, or to stills.
//
//   node tools/promo/render.mjs <path-under-promo-server> --out <file.mp4> [--w 1920 --h 1080 --fps 30 --from 0 --to <s> --workers 4 --crf 14]
//   node tools/promo/render.mjs <path> --stills 1.5,4,9.25 --out <dir>          (PNG stills named t-<seconds>.png)
//
// The page: window.__ready (a promise), window.DURATION (seconds), window.__seek(t) -> promise, drawn for time t.
import { spawn } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { launch } from './lib/cdp.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const build = process.env.PROMO_BUILD || resolve(here, '../../dist/promo/build');
const base = process.env.PROMO_URL || 'http://127.0.0.1:5199';

const args = process.argv.slice(2);
const path = args[0];
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i < 0 ? def : args[i + 1];
};
const W = Number(opt('w', 1920)), H = Number(opt('h', 1080)), fps = Number(opt('fps', 30));
const out = resolve(opt('out', join(build, 'out.mp4')));
const stills = opt('stills');
const workers = Number(opt('workers', 4));
const crf = opt('crf', '14');
const tag = opt('tag', 'r');

const url = base + (path.startsWith('/') ? path : '/' + path);
const browsers = [];

// One browser per worker: only a foreground tab gets frames, so tabs of one browser cannot render in parallel.
async function open(k = 0) {
  const browser = await launch({ width: W, height: H, profileDir: join(build, `.chrome-${tag}-${k}`) });
  browsers.push(browser);
  const page = await browser.newPage({ width: W, height: H });
  await page.goto(url);
  return page;
}

try {
  if (stills) {
    mkdirSync(out, { recursive: true });
    const page = await open();
    for (const t of stills.split(',').map(Number)) {
      await page.eval(`window.__seek(${t})`);
      writeFileSync(join(out, `t-${t.toFixed(2).padStart(6, '0')}.png`), await page.shot());
    }
    if (page.errors.length) console.log('page errors:\n' + [...new Set(page.errors)].join('\n'));
  } else {
    const first = await open();
    const duration = await first.eval('window.DURATION');
    const from = Number(opt('from', 0)), to = Number(opt('to', duration));
    const f0 = Math.round(from * fps), f1 = Math.round(to * fps);
    const total = f1 - f0;
    const n = Math.max(1, Math.min(workers, Math.ceil(total / 30)));
    const segDir = join(build, `.segments-${tag}`);
    rmSync(segDir, { recursive: true, force: true });
    mkdirSync(segDir, { recursive: true });
    mkdirSync(dirname(out), { recursive: true });
    let done = 0;
    const started = Date.now();
    const timer = setInterval(() => console.log(`  ${done}/${total} frames, ${((Date.now() - started) / 1000).toFixed(0)} s`), 15000);
    const encode = (file) =>
      spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'png', '-i', '-',
        '-vf', 'scale=in_range=full:out_range=tv:out_color_matrix=bt709,format=yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709',
        '-c:v', 'libx264', '-preset', 'slow', '-crf', crf, '-g', String(fps), '-bf', '2', file], { stdio: ['pipe', 'inherit', 'inherit'] });
    const segs = [];
    await Promise.all(
      Array.from({ length: n }, async (_, k) => {
        const a = f0 + Math.floor((total * k) / n), b = f0 + Math.floor((total * (k + 1)) / n);
        const file = join(segDir, `seg-${String(k).padStart(2, '0')}.mp4`);
        segs[k] = file;
        const page = k === 0 ? first : await open(k);
        const ff = encode(file);
        const closed = new Promise((res, rej) => ff.on('close', (code) => (code === 0 ? res() : rej(new Error(`ffmpeg exited ${code}`)))));
        for (let f = a; f < b; f++) {
          await page.eval(`window.__seek(${f / fps})`);
          const png = await page.shot();
          if (!ff.stdin.write(png)) await new Promise((r) => ff.stdin.once('drain', r));
          done++;
        }
        ff.stdin.end();
        await closed;
        if (page.errors.length) console.log('page errors:\n' + [...new Set(page.errors)].join('\n'));
      }),
    );
    clearInterval(timer);
    writeFileSync(join(segDir, 'list.txt'), segs.map((s) => `file '${s.replace(/\\/g, '/')}'`).join('\n'));
    await new Promise((res, rej) =>
      spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', join(segDir, 'list.txt'), '-c', 'copy', '-movflags', '+faststart', out], { stdio: 'inherit' }).on('close', (c) =>
        c === 0 ? res() : rej(new Error('concat failed')),
      ),
    );
    console.log(`wrote ${out}: ${total} frames at ${fps} fps in ${((Date.now() - started) / 1000).toFixed(0)} s`);
  }
} finally {
  await Promise.all(browsers.map((b) => b.close()));
}
