// A tiny Chrome DevTools Protocol client (no dependencies; Node 22+ for the global WebSocket).
// Used to render the promo film frame by frame, the posters, and the portfolio PDF.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const CANDIDATES = [
  process.env.CHROME,
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
].filter(Boolean);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function launch({ width = 1920, height = 1080, profileDir }) {
  const chrome = CANDIDATES.find((p) => existsSync(p));
  if (!chrome) throw new Error('No Chrome or Edge found; set CHROME');
  if (!profileDir) throw new Error('profileDir is required');
  rmSync(profileDir, { recursive: true, force: true });
  mkdirSync(profileDir, { recursive: true });
  const proc = spawn(
    chrome,
    [
      '--headless=new',
      '--remote-debugging-port=0',
      `--user-data-dir=${profileDir}`,
      '--hide-scrollbars',
      '--mute-audio',
      '--no-first-run',
      '--no-default-browser-check',
      '--allow-file-access-from-files',
      '--force-color-profile=srgb',
      '--disable-background-timer-throttling',
      '--disable-renderer-backgrounding',
      '--disable-backgrounding-occluded-windows',
      '--disable-features=PaintHolding,Translate',
      `--window-size=${width},${height}`,
      'about:blank',
    ],
    { stdio: 'ignore' },
  );
  const portFile = join(profileDir, 'DevToolsActivePort');
  for (let i = 0; i < 200 && !existsSync(portFile); i++) await sleep(50);
  if (!existsSync(portFile)) {
    proc.kill();
    throw new Error('Chrome did not open a DevTools port');
  }
  await sleep(100);
  const [port, path] = readFileSync(portFile, 'utf8').trim().split('\n');
  const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', () => reject(new Error('DevTools socket failed')), { once: true });
  });
  let seq = 0;
  const pending = new Map();
  const listeners = new Set();
  ws.addEventListener('message', (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(`${msg.error.message} ${msg.error.data ?? ''}`));
      else resolve(msg.result);
    } else if (msg.method) {
      for (const l of listeners) l(msg);
    }
  });
  const raw = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = ++seq;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params, sessionId }));
    });

  async function newPage({ width: w = width, height: h = height, scale = 1 } = {}) {
    const { targetId } = await raw('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await raw('Target.attachToTarget', { targetId, flatten: true });
    const send = (method, params) => raw(method, params, sessionId);
    await send('Page.enable');
    await send('Runtime.enable');
    const errors = [];
    listeners.add((msg) => {
      if (msg.sessionId !== sessionId) return;
      if (msg.method === 'Runtime.exceptionThrown') errors.push(msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text);
      if (msg.method === 'Runtime.consoleAPICalled' && msg.params.type === 'error') errors.push(msg.params.args.map((a) => a.value ?? a.description).join(' '));
    });
    const page = {
      send,
      errors,
      async size(nw, nh, ns = 1) {
        await send('Emulation.setDeviceMetricsOverride', { width: nw, height: nh, deviceScaleFactor: ns, mobile: false });
      },
      async goto(url) {
        const loaded = new Promise((resolve) => {
          const l = (msg) => {
            if (msg.sessionId === sessionId && msg.method === 'Page.loadEventFired') {
              listeners.delete(l);
              resolve();
            }
          };
          listeners.add(l);
        });
        await send('Page.navigate', { url });
        await loaded;
        // Fonts and images first, then whatever the page itself wants to wait for.
        await page.eval('document.fonts.ready.then(() => window.__ready)');
      },
      async eval(expression) {
        const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
        if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
        return r.result.value;
      },
      async shot({ format = 'png', quality, clip } = {}) {
        const { data } = await send('Page.captureScreenshot', { format, quality, clip, optimizeForSpeed: format === 'png', captureBeyondViewport: !!clip });
        return Buffer.from(data, 'base64');
      },
      async pdf(options = {}) {
        const { data } = await send('Page.printToPDF', { printBackground: true, preferCSSPageSize: true, ...options });
        return Buffer.from(data, 'base64');
      },
      async close() {
        await raw('Target.closeTarget', { targetId });
      },
    };
    await page.size(w, h, scale);
    return page;
  }

  return {
    newPage,
    async close() {
      try {
        await raw('Browser.close');
      } catch {}
      await sleep(300);
      try {
        proc.kill();
      } catch {}
    },
  };
}

export const fileUrl = (p) => 'file:///' + p.replace(/\\/g, '/').replace(/^\//, '');
