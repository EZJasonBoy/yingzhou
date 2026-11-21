// The promo film's timeline. Every frame is a pure function of the time: window.__seek(t) draws second t, which is
// how tools/promo/render.mjs records it. Opened in a browser, it simply plays (add ?t=12.5 to hold one moment).
import { createRiver, BRAND } from './river.js';
import { CATALOG } from '../catalog.mjs';

const DURATION = 78;
const W = 1920, H = 1080;
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, t) => a + (b - a) * t;
const seg = (t, a, b) => clamp((t - a) / (b - a));
const E = {
  lin: (x) => x,
  in: (x) => x * x * x,
  out: (x) => 1 - (1 - x) ** 3,
  out5: (x) => 1 - (1 - x) ** 5,
  io: (x) => (x < 0.5 ? 4 * x * x * x : 1 - (-2 * x + 2) ** 3 / 2),
  back: (x) => 1 + 2.70158 * (x - 1) ** 3 + 1.70158 * (x - 1) ** 2,
};
/** Fades in over fi from a, out over fo before b. */
const env = (t, a, b, fi = 0.5, fo = 0.5) => clamp(Math.min((t - a) / fi, (b - t) / fo));
/** Keyframes [[time, value, ease?], ...]: eased between them, held outside. */
const track = (pts) => (t) => {
  if (t <= pts[0][0]) return pts[0][1];
  for (let i = 1; i < pts.length; i++) {
    if (t <= pts[i][0]) {
      const [t0, v0] = pts[i - 1], [t1, v1, e] = pts[i];
      return v0 + (v1 - v0) * (e || E.io)((t - t0) / (t1 - t0 || 1e-9));
    }
  }
  return pts[pts.length - 1][1];
};
const show = (el, a) => {
  el.style.display = a > 0.001 ? 'block' : 'none';
  el.style.opacity = a.toFixed(4);
};

// ---- one-time setup ------------------------------------------------------------------------------------------------

const river = createRiver($('#river'));

for (const el of $$('[data-split]')) {
  const text = el.textContent;
  el.textContent = '';
  for (const ch of text) {
    const s = document.createElement('span');
    s.textContent = ch === ' ' ? ' ' : ch;
    el.append(s);
  }
}
// Headline lines slide up from behind their own edge.
for (const line of $$('.cap .h > span')) {
  const inner = document.createElement('span');
  inner.append(...line.childNodes);
  line.append(inner);
}
for (const img of $$('img[data-shot]')) img.src = `/build/img/${img.dataset.shot}.jpg`;

// The streams of the "sources" scene: from the edges of the frame into the boat.
const SRC_BOAT = [1330, 575];
const SRC = [
  [3, 'rose', '采集站', 'type 0 · 1', 0.17], [8, 'gold', 'jar 蜘蛛', 'csp_*.jar', 0.37], [13, 'mint', 'JS 蜘蛛', '*.js', 0.18], [18.5, 'rose', 'Python 蜘蛛', '*.py', 0.4],
  [24, 'gold', '直播', 'm3u · txt', 0.2], [30, 'mint', '节目单与回看', 'EPG', 0.33], [37, 'rose', '多仓订阅', 'repos[ ]', 0.17], [45, 'gold', '解析与嗅探', 'parses[ ]', 0.52],
  [55, 'mint', '去广告', 'rules[ ]', 0.2], [67, 'rose', '网盘', 'AList · WebDAV', 0.36], [82, 'gold', null, null, 0], [100, 'mint', '本机文件夹', 'file://', 0.16], [118, 'rose', null, null, 0],
].map(([deg, color, name, tag, at], i) => {
  const a = (deg * Math.PI) / 180, [bx, by] = SRC_BOAT;
  // Out from the boat along the angle until the left or the bottom edge.
  let x0 = -60, y0 = by + Math.tan(a) * (bx + 60);
  if (deg >= 90 || y0 > H + 60) { y0 = H + 60; x0 = bx - (H + 60 - by) / Math.tan(a); }
  const nx = -(by - y0), ny = bx - x0, nl = Math.hypot(nx, ny) || 1, bend = (i % 2 ? 1 : -1) * (26 + (i % 3) * 12);
  return {
    x0, y0, x1: bx + (i - 6) * 5, y1: by + 6,
    cx1: lerp(x0, bx, 0.33) + (nx / nl) * bend, cy1: lerp(y0, by, 0.33) + (ny / nl) * bend,
    cx2: lerp(x0, bx, 0.7) - (nx / nl) * bend * 0.6, cy2: lerp(y0, by, 0.7) - (ny / nl) * bend * 0.6,
    color: BRAND[color], w0: 5.5, w1: 1.2, speed: 0.2 + (i % 4) * 0.035, phase: i * 0.37, pulses: 2, lag: (i % 5) * 0.12, name, tag, at,
  };
});
const bez = (s, u) => {
  const v = 1 - u;
  return [v * v * v * s.x0 + 3 * v * v * u * s.cx1 + 3 * v * u * u * s.cx2 + u * u * u * s.x1, v * v * v * s.y0 + 3 * v * v * u * s.cy1 + 3 * v * u * u * s.cy2 + u * u * u * s.y1];
};
const labels = SRC.filter((s) => s.name).map((s) => {
  const el = document.createElement('span');
  el.style.color = s.color;
  el.innerHTML = `<b>${s.name}</b>${s.tag}`;
  $('#labels').append(el);
  const [x, y] = bez(s, s.at);
  return { el, x: x + 6, y: y - 56 };
});

// The streams of the finale: everything runs to the light on the horizon.
const finStreams = (hz) =>
  Array.from({ length: 15 }, (_, i) => {
    const k = i / 14, x0 = lerp(-520, W + 520, k), x1 = W / 2 + (k - 0.5) * 150, bend = (i % 2 ? 1 : -1) * 70;
    return {
      x0, y0: H + 40, x1, y1: hz + 3, cx1: lerp(x0, x1, 0.3) + bend, cy1: lerp(H + 40, hz, 0.36), cx2: lerp(x0, x1, 0.72) - bend * 0.5, cy2: lerp(H + 40, hz, 0.8),
      color: [BRAND.rose, BRAND.gold, BRAND.mint][i % 3], w0: 8, w1: 0.8, speed: 0.16 + (i % 4) * 0.03, phase: i * 0.29, pulses: 2, lag: Math.abs(k - 0.5) * 0.5,
    };
  });

// The poster wall.
{
  const wall = $('#wall');
  const order = [5, 1, 15, 3, 8, 22, 2, 12, 13, 6, 26, 10, 16, 4, 21, 9, 7, 17, 23, 18, 14, 24, 20, 25, 28, 11, 19, 30, 31, 27, 32, 29, 33, 34, 35, 36];
  for (let r = 0; r < 4; r++) {
    const row = document.createElement('div');
    row.className = 'row';
    for (let i = 0; i < 18; i++) {
      const img = new Image();
      img.src = `/build/posters/${order[(r * 9 + i) % order.length]}.jpg`;
      row.append(img);
    }
    wall.append(row);
  }
}
const CHIPS = ['播放缓存', 'm3u8 去广告', '弹幕', '字幕与音轨', '直播 · 节目单 · 回看', '离线下载', '聚合搜索', '自动换线', '网盘', '局域网共享', '手机扫码输入', 'Docker 引擎'];
for (const c of CHIPS) {
  const s = document.createElement('span');
  s.textContent = c;
  $('#chips').append(s);
}

// Film grain, a handful of frames of it.
const grain = $('#grain'), gctx = grain.getContext('2d');
const grains = Array.from({ length: 8 }, (_, k) => {
  const d = gctx.createImageData(480, 270);
  let a = 9001 + k * 7919;
  for (let i = 0; i < d.data.length; i += 4) {
    a = (Math.imul(a, 1664525) + 1013904223) | 0;
    const v = 128 + ((a >>> 16) & 255) - 128;
    d.data[i] = d.data[i + 1] = d.data[i + 2] = v;
    d.data[i + 3] = 16;
  }
  return d;
});

// ---- small animation helpers ---------------------------------------------------------------------------------------

/** Characters of a [data-split] element arrive one after another from t0; all leave at tOut. */
function chars(el, t, t0, { stagger = 0.08, dur = 0.9, y = 26, x = 0, blur = 10, tOut = 1e9, outDur = 0.5 } = {}) {
  const out = 1 - E.in(seg(t, tOut, tOut + outDur));
  const kids = el.children;
  for (let i = 0; i < kids.length; i++) {
    const p = E.out(seg(t, t0 + i * stagger, t0 + i * stagger + dur)), s = kids[i].style;
    s.opacity = (p * out).toFixed(4);
    s.transform = `translate(${((1 - p) * x).toFixed(2)}px, ${((1 - p) * y).toFixed(2)}px)`;
    s.filter = p < 0.999 && blur ? `blur(${((1 - p) * blur).toFixed(2)}px)` : 'none';
  }
}

/** A caption block (.k kicker, .h lines, .s sub) between a and b. */
function cap(el, t, a, b, out = 0.4) {
  const vis = t > a - 0.02 && t < b + 0.02;
  el.style.display = vis ? 'block' : 'none';
  if (!vis) return;
  const fo = 1 - E.in(seg(t, b - out, b));
  const k = el.querySelector(':scope > .k'), s = el.querySelector(':scope > .s'), keys = el.querySelector(':scope > .keys');
  if (k) { const p = E.out(seg(t, a, a + 0.6)); k.style.opacity = (p * fo).toFixed(4); k.style.transform = `translateX(${((1 - p) * -28).toFixed(2)}px)`; }
  el.querySelectorAll(':scope > .h > span > span').forEach((h, i) => {
    const p = E.out5(seg(t, a + 0.1 + i * 0.13, a + 1.0 + i * 0.13));
    h.style.display = 'block';
    h.style.transform = `translateY(${((1 - p) * 108).toFixed(2)}%)`;
    h.style.opacity = fo.toFixed(4);
  });
  if (s) { const p = E.out(seg(t, a + 0.45, a + 1.2)); s.style.opacity = (p * fo).toFixed(4); s.style.transform = `translateY(${((1 - p) * 20).toFixed(2)}px)`; }
  if (keys) { const p = E.out(seg(t, a + 0.7, a + 1.3)); keys.style.opacity = (p * fo).toFixed(4); }
}

/** Shows image i of a stack while its slot [times[i], times[i+1]] runs, with a short dissolve and a slow push-in. */
function stack(imgs, t, times, fade = 0.3) {
  imgs.forEach((img, i) => {
    const a = times[i], b = times[i + 1] ?? 1e9;
    const o = i === 0 ? 1 - seg(t, b, b + fade) : Math.min(seg(t, a, a + fade), b > 1e8 ? 1 : 1 - seg(t, b, b + fade));
    img.style.opacity = o.toFixed(4);
    img.style.transform = `scale(${(1.035 - 0.035 * E.out(seg(t, a, a + 1.6))).toFixed(5)})`;
  });
}

const press = (t, at, len = 0.28) => (t >= at && t < at + len ? Math.sin(((t - at) / len) * Math.PI) : 0);

// ---- the camera and the world --------------------------------------------------------------------------------------

const K = {
  hz: track([[0, 660], [11.99, 660], [12, 600], [17.2, 600], [19.2, 420], [38.99, 420], [39, 800], [52.49, 800], [52.5, 760], [65.99, 760], [66, 620], [71, 620], [73.4, 700], [78, 700]]),
  boatX: track([[0, 700], [11.99, 716], [12, 560], [17.2, 592], [19.2, 1330], [38.99, 1330], [39, 1400], [43.5, 1430], [65.99, 1430], [66, 960], [78, 960]]),
  boatY: track([[5.5, 664], [11.6, 744, E.in], [11.99, 744], [12, 690], [17.2, 690], [19.2, 575], [38.99, 575], [39, 838], [65.99, 838], [66, 800], [71, 786], [73.4, 748], [78, 738]]),
  boatS: track([[5.5, 0.016], [11.6, 0.2, E.in], [11.99, 0.2], [12, 0.52], [17.2, 0.535], [19.2, 0.22], [38.99, 0.22], [39, 0.11], [65.99, 0.11], [66, 0.3], [71, 0.25], [73.4, 0.11], [78, 0.085]]),
  boatA: track([[5.5, 0], [7.2, 1], [23.8, 1], [24.5, 0], [38.99, 0], [39, 1], [43.3, 1], [43.9, 0], [65.99, 0], [66, 1], [78, 1]]),
  stars: track([[0.8, 0], [4.8, 1], [78, 1]]),
  milky: track([[2, 0], [9.5, 0.55], [11.99, 0.55], [12, 0.7], [38.99, 0.7], [39, 1], [65.99, 1], [66, 0.75], [78, 0.75]]),
  dawn: track([[66, 0.04], [77.2, 0.9, E.out]]),
  glow: track([[5.5, 0], [11, 0.5], [11.99, 0.5], [12, 1.7], [13.4, 1, E.out], [17.2, 1], [19.2, 0.75], [38.99, 0.75], [39, 0.8], [65.99, 0.8], [66, 1], [78, 1.15]]),
  waves: track([[8.5, 0], [11, 1], [78, 1]]),
  spread: track([[66, 1], [72, 2], [78, 3.2]]),
  dim: track([[23.8, 0], [24.6, 0.55], [29.7, 0.55], [30.4, 0.74], [38.99, 0.74], [39, 0], [43.3, 0], [44, 0.62], [52.4, 0.62], [53.2, 0.45], [56.8, 0.45], [57.4, 0.7], [65.99, 0.7], [66, 0]]),
  scene: track([[1.4, 0], [4.6, 1], [11.5, 1], [11.98, 0, E.in], [12, 0], [12.45, 1, E.out], [38.5, 1], [38.98, 0, E.in], [39, 0], [39.7, 1, E.out], [65.5, 1], [65.98, 0, E.in], [66, 0], [66.9, 1, E.out], [77.1, 1], [78, 0, E.in]]),
};

function world(t) {
  const hz = K.hz(t);
  const p = {
    hz, scene: K.scene(t), line: E.io(seg(t, 0.3, 2.6)), stars: K.stars(t), milky: K.milky(t), dawn: t < 66 ? 0 : K.dawn(t),
    boatX: K.boatX(t), boatY: K.boatY(t), boatS: K.boatS(t), boatA: K.boatA(t), glow: K.glow(t), reflect: 1,
    waves: K.waves(t), waveDrop: 1, waveSpread: t < 66 ? 1 : K.spread(t), dim: K.dim(t),
    meteor: t > 40.6 && t < 41.5 ? seg(t, 40.6, 41.5) : -1, streams: null, streamGrow: 0, streamAlpha: 0,
  };
  p.glowX = p.boatA > 0.01 ? p.boatX : W / 2;
  if (t > 18.3 && t < 24.6) { p.streams = SRC; p.streamGrow = E.out(seg(t, 18.5, 21.4)); p.streamAlpha = env(t, 18.4, 24.4, 0.5, 0.8); }
  if (t >= 66) { p.streams = finStreams(hz); p.streamGrow = E.out(seg(t, 66.3, 69.8)); p.streamAlpha = 0.95 * seg(t, 66.2, 67.4); }
  river.draw(t, p);
}

// ---- the scenes ----------------------------------------------------------------------------------------------------

const S = Object.fromEntries($$('.scene').map((el) => [el.id.slice(2), el]));
const q = (scene, sel) => $(sel, S[scene]);
const qq = (scene, sel) => $$(sel, S[scene]);

function poem(scene, t, a, c1, c2, sealAt, citeAt, out, o = {}) {
  const vis = env(t, a, out + 0.5, 0.01, 0.01);
  show(S[scene], vis > 0 ? 1 : 0);
  if (!vis) return;
  const cols = qq(scene, '.col');
  chars(cols[0], t, c1, { stagger: 0.26, dur: 1.5, y: o.h ? 30 : -22, blur: 14, tOut: out, outDur: 0.5 });
  chars(cols[1], t, c2, { stagger: 0.26, dur: 1.5, y: o.h ? 30 : -22, blur: 14, tOut: out, outDur: 0.5 });
  const fo = 1 - E.in(seg(t, out, out + 0.5));
  const seal = q(scene, '.seal');
  if (seal) {
    const p = seg(t, sealAt, sealAt + 0.34);
    seal.style.opacity = (Math.min(1, p * 2.5) * fo).toFixed(4);
    seal.style.transform = `scale(${(2.1 - 1.1 * E.out5(p)).toFixed(4)}) rotate(${(-7 + 5 * E.out(p)).toFixed(3)}deg)`;
  }
  const cite = q(scene, '.cite');
  if (cite) { const p = E.out(seg(t, citeAt, citeAt + 1)); cite.style.opacity = (p * fo).toFixed(4); cite.style.transform = `translateY(${((1 - p) * 14).toFixed(2)}px)`; }
}

function title(t) {
  const a = env(t, 12.05, 17.45, 0.01, 0.01);
  show(S.title, a > 0 ? 1 : 0);
  if (!a) return;
  const out = 16.85;
  chars(q('title', '.name'), t, 12.3, { stagger: 0.2, dur: 1.2, y: 46, blur: 20, tOut: out });
  chars(q('title', '.latin'), t, 12.95, { stagger: 0.05, dur: 0.7, y: 0, x: 26, blur: 6, tOut: out });
  const rule = q('title', '.rule');
  rule.style.width = `${(600 * E.out5(seg(t, 13.3, 14.5))).toFixed(1)}px`;
  rule.style.opacity = (1 - E.in(seg(t, out, out + 0.5))).toFixed(4);
  chars(q('title', '.tag'), t, 13.55, { stagger: 0.03, dur: 0.8, y: 18, blur: 6, tOut: out });
  S.title.style.transform = `translateX(${(-60 * E.in(seg(t, out, 17.45))).toFixed(2)}px)`;
}

function sources(t) {
  const a = env(t, 18.3, 24.1, 0.01, 0.01);
  show(S.sources, a > 0 ? 1 : 0);
  if (!a) return;
  cap(q('sources', '.cap'), t, 18.6, 23.9, 0.45);
  labels.forEach((l, i) => {
    const t0 = 19.7 + i * 0.17, p = E.out5(seg(t, t0, t0 + 0.6)), fo = 1 - E.in(seg(t, 23.3 + i * 0.02, 23.8 + i * 0.02));
    l.el.style.opacity = (p * fo).toFixed(4);
    l.el.style.transform = `translate(${(l.x - (1 - p) * 40).toFixed(1)}px, ${(l.y + Math.sin(t * 0.9 + i) * 4).toFixed(1)}px)`;
  });
}

function wall(t) {
  const a = env(t, 23.9, 30.25, 0.7, 0.45);
  show(S.wall, a);
  if (!a) return;
  const el = $('#wall'), p = E.out5(seg(t, 23.9, 26.4)), drift = (t - 24) / 6;
  el.style.transform = `perspective(2200px) rotateX(${(26 - 3 * drift).toFixed(3)}deg) rotateY(${(-17 + 4 * drift).toFixed(3)}deg) rotateZ(${(7 - drift).toFixed(3)}deg) scale(${(1.42 - 0.2 * p - 0.05 * drift).toFixed(4)})`;
  $$('.row', el).forEach((row, r) => {
    const dir = r % 2 ? 1 : -1, speed = 46 + r * 14, enter = (1 - p) * 900 * dir;
    row.style.transform = `translate(${(-2400 + dir * 200 + dir * (t - 24) * speed + enter).toFixed(1)}px, ${(-766 + r * 386).toFixed(1)}px)`;
  });
  cap(q('wall', '.cap'), t, 24.8, 29.9, 0.45);
}

function desk(t) {
  const a = env(t, 29.9, 38.85, 0.6, 0.35);
  show(S.desk, a);
  if (!a) return;
  const win = $('#win'), p = E.out5(seg(t, 29.9, 31.4)), d = (t - 30) / 9;
  win.style.transform = `perspective(2600px) translateY(${((1 - p) * 110).toFixed(2)}px) rotateY(${(-17 + 10 * p + 3.5 * d).toFixed(3)}deg) rotateX(${(5 - 3.4 * p).toFixed(3)}deg) scale(${(0.94 + 0.06 * p + 0.025 * d).toFixed(5)})`;
  const cuts = [30, 32.7, 34.7, 36.3];
  stack(qq('desk', '.view img'), t, cuts);
  qq('desk', '.caps .cap').forEach((c, i) => cap(c, t, cuts[i] + (i ? 0.05 : 0.4), (cuts[i + 1] ?? 38.75) + 0.02, 0.3));
  qq('desk', 'kbd').forEach((k, i) => {
    const v = press(t, 37.0 + i * 0.3);
    k.style.transform = `translateY(${(v * 5).toFixed(2)}px)`;
    k.style.boxShadow = `0 ${(5 - v * 5).toFixed(2)}px 0 #14132C, 0 10px 22px rgba(0,0,0,.45), 0 0 ${(v * 34).toFixed(1)}px rgba(244,160,138,${(v * 0.9).toFixed(3)})`;
    k.style.borderColor = v > 0.05 ? 'rgba(244,160,138,.95)' : 'rgba(255,255,255,.16)';
  });
}

function touch(t) {
  const a = env(t, 43.5, 48.1, 0.5, 0.35);
  show(S.touch, a);
  if (!a) return;
  cap(q('touch', '.cap'), t, 43.8, 48.05, 0.35);
  const tab = $('#tablet'), ph = $('#phone'), p1 = E.out5(seg(t, 43.6, 45.2)), p2 = E.out5(seg(t, 43.9, 45.5)), d = (t - 43.5) / 4.5;
  tab.style.opacity = Math.min(1, p1 * 2).toFixed(4);
  tab.style.transform = `perspective(2400px) translate(${((1 - p1) * 160).toFixed(1)}px, ${((1 - p1) * 60).toFixed(1)}px) rotateY(${(-13 + 3 * d).toFixed(3)}deg) rotateX(3deg)`;
  ph.style.opacity = Math.min(1, p2 * 2).toFixed(4);
  ph.style.transform = `perspective(2400px) translate(${((1 - p2) * -60 - 10 * d).toFixed(1)}px, ${((1 - p2) * 150).toFixed(1)}px) rotateY(${(12 - 4 * d).toFixed(3)}deg) rotateX(2deg)`;
  const ph2 = $('#phone2'), p3 = E.out5(seg(t, 44.3, 45.9));
  ph2.style.opacity = Math.min(1, p3 * 2).toFixed(4);
  ph2.style.transform = `perspective(2400px) translate(${((1 - p3) * 120 - 12 * d).toFixed(1)}px, ${((1 - p3) * 110).toFixed(1)}px) rotateY(${(-10 + 3 * d).toFixed(3)}deg) rotateX(4deg)`;
  // a double tap, then a drag up the right edge for the volume
  const tap = $('#tap');
  const r1 = seg(t, 46.15, 46.6), r2 = seg(t, 46.4, 46.85), r = t < 46.4 ? r1 : r2;
  tap.style.opacity = (t > 46.15 && t < 46.85 ? 1 - r : 0).toFixed(4);
  tap.style.transform = `scale(${(0.4 + r * 1.1).toFixed(4)})`;
  const swipe = $('#swipe'), sv = E.io(seg(t, 47.0, 47.75));
  swipe.style.opacity = env(t, 46.9, 47.95, 0.15, 0.2).toFixed(4);
  swipe.firstElementChild.style.height = `${(34 + 52 * sv).toFixed(1)}%`;
}

function tv(t) {
  const a = env(t, 48, 52.6, 0.5, 0.35);
  show(S.tv, a);
  if (!a) return;
  cap(q('tv', '.cap'), t, 48.3, 52.55, 0.35);
  const el = $('#tv'), p = E.out5(seg(t, 48.05, 49.6)), d = (t - 48) / 4.5;
  el.style.transform = `perspective(2600px) translateY(${((1 - p) * 90).toFixed(2)}px) rotateY(${(-9 + 3 * d).toFixed(3)}deg) scale(${(0.95 + 0.05 * p + 0.02 * d).toFixed(5)})`;
  const cuts = [48, 49.5, 50.5, 51.5];
  stack(qq('tv', '.panel img'), t, cuts, 0.18);
  const rem = $('#remote'), pr = E.out5(seg(t, 48.5, 49.6));
  rem.style.opacity = pr.toFixed(4);
  rem.style.transform = `translateY(${((1 - pr) * 80).toFixed(2)}px) rotate(${(8 - 2 * d).toFixed(3)}deg)`;
  const right = press(t, 49.35, 0.3), ok = Math.max(press(t, 50.35, 0.3), press(t, 51.35, 0.3));
  const ri = $('.key.r', rem), ob = $('.key.ok', rem);
  ri.style.opacity = right.toFixed(4);
  ri.style.transform = `scale(${(0.7 + right * 0.4).toFixed(3)})`;
  ob.style.opacity = ok.toFixed(4);
  ob.style.transform = `scale(${(0.75 + ok * 0.35).toFixed(3)})`;
}

function fleet(t) {
  const a = env(t, 52.5, 57.1, 0.45, 0.4);
  show(S.fleet, a);
  if (!a) return;
  cap(q('fleet', '.cap'), t, 52.8, 57.05, 0.4);
  const d = (t - 52.5) / 4.5;
  [['#f-tv', 0, 0], ['#f-win', 0.18, -1], ['#f-tab', 0.3, 1], ['#f-phone', 0.42, 1]].forEach(([sel, delay, side]) => {
    const el = $(sel), p = E.out5(seg(t, 52.6 + delay, 54.2 + delay));
    el.style.opacity = Math.min(1, p * 2.2).toFixed(4);
    el.style.transform = `perspective(2600px) translate(${(side * (1 - p) * 90 - side * 8 * d).toFixed(2)}px, ${((1 - p) * 120).toFixed(2)}px) rotateY(${(side * -9).toFixed(2)}deg) scale(${(1 + 0.015 * d).toFixed(5)})`;
  });
  qq('fleet', '.plats span').forEach((s, i) => {
    const p = E.out5(seg(t, 53.7 + i * 0.12, 54.4 + i * 0.12));
    s.style.opacity = p.toFixed(4);
    s.style.transform = `translateY(${((1 - p) * 18).toFixed(2)}px)`;
  });
}

function engine(t) {
  const a = env(t, 57, 65.85, 0.5, 0.4);
  show(S.engine, a);
  if (!a) return;
  cap(q('engine', '.cap'), t, 57.2, 65.8, 0.4);
  const out1 = 1 - E.in(seg(t, 62.3, 62.8));
  qq('engine', '.pillar').forEach((el, i) => {
    const p = E.out5(seg(t, 57.35 + i * 0.22, 58.5 + i * 0.22));
    el.style.opacity = (Math.min(1, p * 2) * out1).toFixed(4);
    el.style.transform = `translateY(${((1 - p) * 70 - (1 - out1) * 30).toFixed(2)}px)`;
  });
  qq('engine', '.chips span').forEach((el, i) => {
    const t0 = 59.5 + i * 0.09, p = E.back(seg(t, t0, t0 + 0.45));
    el.style.opacity = (seg(t, t0, t0 + 0.2) * out1).toFixed(4);
    el.style.transform = `scale(${(0.8 + 0.2 * p).toFixed(4)}) translateY(${(-(1 - out1) * 30).toFixed(2)}px)`;
    const lit = press(t, t0 + 0.1, 0.6);
    el.style.borderColor = `rgba(${lit > 0.02 ? '244,160,138' : '255,255,255'},${(0.13 + lit * 0.8).toFixed(3)})`;
  });
  $('.pillars', S.engine).style.display = $('#chips').style.display = t < 62.85 ? 'grid' : 'none';
  const nums = $('#nums');
  nums.style.display = t > 62.8 ? 'grid' : 'none';
  $$('.num', nums).forEach((el, i) => {
    const t0 = 63.0 + i * 0.16, p = E.out5(seg(t, t0, t0 + 0.9));
    el.style.opacity = Math.min(1, p * 2).toFixed(4);
    el.style.transform = `translateY(${((1 - p) * 60).toFixed(2)}px)`;
    const b = $('b', el);
    b.textContent = String(Math.round(Number(b.dataset.to) * E.out5(seg(t, t0, t0 + 1.25))));
  });
  const next = $('#next'), pn = E.out5(seg(t, 64.1, 65));
  next.style.display = t > 62.8 ? 'flex' : 'none';
  next.style.opacity = pn.toFixed(4);
  next.style.transform = `translateX(${((1 - pn) * -30).toFixed(2)}px)`;
}

function end(t) {
  const a = env(t, 72.1, 78.2, 0.01, 0.01);
  show(S.end, a > 0 ? 1 : 0);
  if (!a) return;
  const steps = [['.logo', 72.2, 40], ['.name', 72.5, 30], ['.tag', 72.95, 24], ['.credits', 73.5, 0], ['.plats', 73.6, 20], ['.url', 73.95, 16], ['.fine', 74.3, 12]];
  for (const [sel, t0, y] of steps) {
    const el = q('end', sel), p = E.out5(seg(t, t0, t0 + 1.1));
    el.style.opacity = Math.min(1, p * 1.8).toFixed(4);
    el.style.transform = `translateY(${((1 - p) * y).toFixed(2)}px)${sel === '.logo' ? ` scale(${(0.86 + 0.14 * p).toFixed(4)})` : ''}`;
  }
}

function frame(t) {
  world(t);
  poem('poem1', t, 2, 2.3, 7.5, 9.7, 8.8, 11.2);
  title(t);
  sources(t);
  wall(t);
  desk(t);
  poem('poem2', t, 39.2, 39.5, 41.0, 42.5, 41.9, 43.0);
  touch(t);
  tv(t);
  fleet(t);
  engine(t);
  poem('poem3', t, 66.5, 66.9, 68.5, 0, 69.7, 71.1, { h: true });
  end(t);
  $('#flash').style.opacity = (0.85 * (1 - E.out(seg(t, 12, 13.1))) * (t >= 12 ? 1 : 0)).toFixed(4);
  $('#black').style.opacity = Math.max(1 - seg(t, 0, 0.4), seg(t, 77.4, 78)).toFixed(4);
  gctx.putImageData(grains[Math.floor(t * 30) % grains.length], 0, 0);
}

// ---- running it ----------------------------------------------------------------------------------------------------

window.DURATION = DURATION;
window.__seek = (t) => {
  frame(t);
  return Promise.resolve(true);
};
window.__ready = Promise.all($$('img').map((img) => (img.complete ? Promise.resolve() : new Promise((r) => (img.onload = img.onerror = r))).then(() => img.decode?.().catch(() => {}))));

const params = new URLSearchParams(location.search);
if (params.has('plain')) document.body.classList.add('plain'); // the world alone, for stills
window.__ready.then(() => {
  const stage = $('#stage'), fit = Math.min(innerWidth / W, innerHeight / H);
  if (fit < 0.999) { stage.style.transformOrigin = '0 0'; stage.style.transform = `scale(${fit})`; }
  if (params.has('t')) return frame(Number(params.get('t')));
  if (navigator.webdriver || params.has('hold')) return frame(0);
  const t0 = performance.now() - Number(params.get('from') || 0) * 1000;
  const tick = () => {
    frame(((performance.now() - t0) / 1000) % DURATION);
    requestAnimationFrame(tick);
  };
  tick();
});
