// Screenshots of the web remote's two screens (遥控 and 播放) at a phone's size, in a headless Edge or Chrome:
//
//   node tools/remote/screenshots.mjs [engine address, default http://127.0.0.1:19990] [output folder, default .]
//
// The engine must be running (--demo on a port of its own) with a screen registered, e.g. tools/remote/fake-screen.mjs.
// The page is opened from this machine, so it needs no pairing. Uses the DevTools protocol over Node's own
// WebSocket (Node 22+); a fresh browser profile each run, deleted afterwards. Set TVBOX_BROWSER to pick the browser.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const args = process.argv.slice(2);
const base = (args[0] ?? 'http://127.0.0.1:19990').replace(/\/$/, '');
const out = resolve(args[1] ?? '.');
mkdirSync(out, { recursive: true });

const candidates = [
  process.env.TVBOX_BROWSER,
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/usr/bin/chromium',
  '/usr/bin/google-chrome',
].filter(Boolean);
const browser = candidates.find((p) => existsSync(p));
if (!browser) {
  console.error('no Edge / Chrome found; set TVBOX_BROWSER');
  process.exit(2);
}

const profile = mkdtempSync(join(tmpdir(), 'yz-remote-shots-'));
// Edge's first process hands over to another and exits: where its DevTools listen is read from the profile.
const proc = spawn(browser, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', 'about:blank'], {
  stdio: 'ignore',
});
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
let browserWs = '';

try {
  const portFile = join(profile, 'DevToolsActivePort');
  const started = Date.now();
  while (!existsSync(portFile) || readFileSync(portFile, 'utf8').trim().split('\n').length < 2) {
    if (Date.now() - started > 20000) throw new Error('the browser did not start');
    await sleep(200);
  }
  const [port, browserPath] = readFileSync(portFile, 'utf8').trim().split('\n').map((l) => l.trim());
  browserWs = `ws://127.0.0.1:${port}${browserPath}`;
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((done) => ws.addEventListener('open', done, { once: true }));
  let seq = 0;
  const pending = new Map();
  ws.addEventListener('message', (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  });
  const call = (method, params = {}) =>
    new Promise((done, fail) => {
      const id = ++seq;
      pending.set(id, (msg) => (msg.error ? fail(new Error(`${method}: ${msg.error.message}`)) : done(msg.result)));
      ws.send(JSON.stringify({ id, method, params }));
    });

  await call('Page.enable');
  await call('Runtime.enable');
  // An iPhone 14's screen: 390 x 844 at 3x, as a touch device.
  await call('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });
  await call('Emulation.setTouchEmulationEnabled', { enabled: true });

  const shoot = async (url, name, ready) => {
    // A fresh load each time: from /remote/ to /remote/#tab=play would only change the fragment.
    await call('Page.navigate', { url: 'about:blank' });
    await call('Page.navigate', { url });
    const deadline = Date.now() + 15000;
    for (;;) {
      const { result } = await call('Runtime.evaluate', { expression: ready, returnByValue: true });
      if (result.value === true) break;
      if (Date.now() > deadline) throw new Error(`${name}: the page did not get ready (${ready})`);
      await sleep(250);
    }
    await sleep(800);
    const { data } = await call('Page.captureScreenshot', { format: 'png' });
    const file = join(out, `web-remote-${name}.png`);
    writeFileSync(file, Buffer.from(data, 'base64'));
    console.log(file);
  };

  // Connected to a screen that plays something: the now-playing strip is up.
  await shoot(`${base}/remote/`, 'remote', `!document.getElementById('now').hidden && !document.getElementById('tab-remote').hidden`);
  await shoot(`${base}/remote/#tab=play`, 'play', `!document.getElementById('play-body').hidden && !document.getElementById('tab-play').hidden`);
  ws.close();
} finally {
  // The browser that does the work is not the process started above: it is asked to close.
  if (browserWs) {
    await new Promise((done) => {
      const b = new WebSocket(browserWs);
      b.addEventListener('open', () => b.send(JSON.stringify({ id: 1, method: 'Browser.close' })));
      b.addEventListener('close', done);
      b.addEventListener('error', done);
      setTimeout(done, 3000);
    });
  }
  proc.kill();
  await sleep(500);
  try {
    rmSync(profile, { recursive: true, force: true });
  } catch {
    // The browser still holds a file: the temp folder is cleared some other time.
  }
}
