// The film's world: a night river under stars, and the boat of the logo on it. Everything is drawn for a time t
// and a set of parameters, so any frame can be rendered on its own.

const lerp = (a, b, t) => a + (b - a) * t;
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const mixRgb = (a, b, t) => hex(a).map((v, i) => Math.round(lerp(v, hex(b)[i], t)));
const rgba = (c, a) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;
const fract = (x) => x - Math.floor(x);

export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const BRAND = { indigo: '#2F2C55', coral: '#F4A08A', rose: '#EE8C86', gold: '#F0C670', mint: '#84CFAE' };

/** The logo's boat (sail and hull, no waves) on a 1024 canvas, in the logo's own coordinates. */
function boatSprite() {
  const c = document.createElement('canvas');
  c.width = c.height = 1024;
  const g = c.getContext('2d');
  g.lineJoin = 'round';
  g.fillStyle = g.strokeStyle = '#fff';
  g.lineWidth = 56;
  g.beginPath();
  g.moveTo(420, 236); g.lineTo(420, 560); g.lineTo(694, 398); g.closePath();
  g.fill(); g.stroke();
  g.fillStyle = BRAND.coral;
  g.fill(new Path2D('M216 636 H808 Q770 806 512 806 Q254 806 216 636 Z'));
  return c;
}

export function createRiver(canvas) {
  const W = canvas.width, H = canvas.height;
  const g = canvas.getContext('2d');
  const R = rng(20261112);
  const sprite = boatSprite();
  const WATERLINE = 792;

  const stars = Array.from({ length: 900 }, () => {
    const big = R() < 0.07;
    return { x: R(), y: Math.pow(R(), 0.85), r: big ? 1.3 + R() * 1.5 : 0.35 + R() * 0.9, b: big ? 0.75 + R() * 0.25 : 0.25 + R() * 0.6, tw: 0.6 + R() * 2.2, ph: R() * 6.28, tint: R() };
  });
  const bright = stars.filter((s) => s.r > 1.25);
  const ripples = Array.from({ length: 300 }, () => ({ x: R(), d: R(), len: 0.4 + R() * 0.9, ph: R() * 6.28, sp: 0.5 + R() * 1.6 }));
  const shore = Array.from({ length: 97 }, () => R());

  // A glow sprite for the bigger stars.
  const glow = document.createElement('canvas');
  glow.width = glow.height = 64;
  {
    const gg = glow.getContext('2d'), gr = gg.createRadialGradient(32, 32, 0, 32, 32, 32);
    gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(0.12, 'rgba(255,255,255,.75)'); gr.addColorStop(0.4, 'rgba(200,205,255,.14)'); gr.addColorStop(1, 'rgba(200,205,255,0)');
    gg.fillStyle = gr; gg.fillRect(0, 0, 64, 64);
  }

  // The Milky Way, painted once: a soft band with dust and a thousand faint stars.
  const milky = document.createElement('canvas');
  milky.width = W; milky.height = 900;
  {
    const m = milky.getContext('2d');
    const at = (u) => [lerp(-200, W + 200, u), lerp(760, 40, u) - 150 * Math.sin(u * Math.PI)];
    m.globalCompositeOperation = 'lighter';
    for (let i = 0; i < 260; i++) {
      const u = R(), [x, y] = at(u), rad = 60 + R() * 190, ox = (R() - 0.5) * 240, oy = (R() - 0.5) * 150;
      const col = [[122, 116, 200], [150, 120, 190], [200, 130, 160], [110, 140, 210]][Math.floor(R() * 4)];
      const gr = m.createRadialGradient(x + ox, y + oy, 0, x + ox, y + oy, rad);
      gr.addColorStop(0, rgba(col, 0.05)); gr.addColorStop(1, rgba(col, 0));
      m.fillStyle = gr; m.fillRect(x + ox - rad, y + oy - rad, rad * 2, rad * 2);
    }
    for (let i = 0; i < 2600; i++) {
      const u = R(), [x, y] = at(u), spread = 70 + 90 * Math.sin(u * Math.PI);
      const gx = x + (R() + R() + R() - 1.5) * spread * 1.6, gy = y + (R() + R() + R() - 1.5) * spread;
      m.fillStyle = `rgba(235,235,255,${(0.1 + R() * 0.5).toFixed(2)})`;
      const s = R() < 0.9 ? 1 : 1.8;
      m.fillRect(gx, gy, s, s);
    }
  }

  function bezier(s, u) {
    const v = 1 - u;
    return [
      v * v * v * s.x0 + 3 * v * v * u * s.cx1 + 3 * v * u * u * s.cx2 + u * u * u * s.x1,
      v * v * v * s.y0 + 3 * v * v * u * s.cy1 + 3 * v * u * u * s.cy2 + u * u * u * s.y1,
    ];
  }

  function drawStreams(t, list, grow, alpha) {
    if (!list || alpha <= 0.002 || grow <= 0) return;
    g.save();
    g.lineCap = 'round';
    g.globalCompositeOperation = 'lighter';
    for (const s of list) {
      const c = hex(s.color), gmax = clamp(grow * (1 + s.lag) - s.lag);
      if (gmax <= 0) continue;
      // The stream itself, thinner towards its far end.
      const n = 44;
      for (let i = 0; i < n; i++) {
        const u0 = (i / n) * gmax, u1 = ((i + 1) / n) * gmax, [ax, ay] = bezier(s, u0), [bx, by] = bezier(s, u1);
        g.strokeStyle = rgba(c, (0.2 * alpha).toFixed(3));
        g.lineWidth = lerp(s.w0, s.w1, u0);
        g.beginPath(); g.moveTo(ax, ay); g.lineTo(bx, by); g.stroke();
      }
      // Light running along it.
      for (let j = 0; j < s.pulses; j++) {
        const head = fract(t * s.speed + s.phase + j / s.pulses) * 1.25, tail = 0.2;
        for (let i = 0; i < 16; i++) {
          const u0 = head - tail + (tail * i) / 16, u1 = head - tail + (tail * (i + 1)) / 16;
          if (u1 <= 0 || u0 >= gmax) continue;
          const [ax, ay] = bezier(s, clamp(u0)), [bx, by] = bezier(s, clamp(Math.min(u1, gmax)));
          g.strokeStyle = rgba(c, (alpha * 0.85 * Math.pow((i + 1) / 16, 2)).toFixed(3));
          g.lineWidth = lerp(s.w0, s.w1, clamp(u0)) * 1.7;
          g.beginPath(); g.moveTo(ax, ay); g.lineTo(bx, by); g.stroke();
        }
      }
    }
    g.restore();
  }

  function drawBoat(t, p) {
    const S = p.boatS, a = p.boatA;
    if (a <= 0.002 || S <= 0) return;
    const bx = p.boatX, by = p.boatY + Math.sin(t * 1.15) * 3.2 * Math.min(1, S * 2.2), rot = Math.sin(t * 0.83) * 0.014;
    g.save();
    // Light around the sail.
    if (p.glow > 0) {
      g.globalCompositeOperation = 'lighter';
      const gx = bx + 40 * S, gy = by - 400 * S, rad = 760 * S * (0.9 + 0.1 * Math.sin(t * 0.9));
      const gr = g.createRadialGradient(gx, gy, 0, gx, gy, rad);
      gr.addColorStop(0, `rgba(255,236,214,${(0.5 * p.glow * a).toFixed(3)})`);
      gr.addColorStop(0.25, `rgba(244,160,138,${(0.2 * p.glow * a).toFixed(3)})`);
      gr.addColorStop(1, 'rgba(244,160,138,0)');
      g.fillStyle = gr; g.fillRect(gx - rad, gy - rad, rad * 2, rad * 2);
      g.globalCompositeOperation = 'source-over';
    }
    // The reflection: the boat upside down, cut into rows that slide sideways.
    const rows = Math.min(H - by, 640 * S * 0.9), q = 0.9, step = S > 0.5 ? 2 : 1;
    for (let r = 0; r < rows; r += step) {
      const sy = WATERLINE - 18 - r / (S * q);
      if (sy < 180) break;
      const k = r / rows, dx = Math.sin(r * 0.085 / Math.sqrt(S) + t * 2.5) * (1.2 + r * 0.045) * Math.min(1.4, S * 2 + 0.3) + Math.sin(r * 0.031 + t * 1.3) * 3 * S;
      g.globalAlpha = a * p.reflect * 0.34 * Math.pow(1 - k, 1.25);
      g.drawImage(sprite, 0, sy, 1024, Math.max(1, step / (S * q)), bx - 512 * S + dx, by + r, 1024 * S, step + 0.6);
    }
    g.globalAlpha = a;
    g.translate(bx, by); g.rotate(rot);
    g.drawImage(sprite, -512 * S, -WATERLINE * S, 1024 * S, 1024 * S);
    g.setTransform(1, 0, 0, 1, 0, 0);
    // The three-colour wave under the hull, as in the logo, rolling.
    if (p.waves > 0.002) {
      const y0 = by + (892 - WATERLINE) * S * p.waveDrop, amp = 17 * S, ph = t * 2.1;
      const part = (xa, xb, col) => {
        g.strokeStyle = col; g.beginPath();
        const n = Math.max(6, Math.round(((xb - xa) * S) / 4));
        for (let i = 0; i <= n; i++) {
          const x = lerp(xa, xb, i / n), y = y0 - amp * Math.sin(((x - 262) / 100) * Math.PI + ph);
          const px = bx + (x - 512) * S;
          i ? g.lineTo(px, y) : g.moveTo(px, y);
        }
        g.stroke();
      };
      g.lineCap = 'round'; g.lineJoin = 'round'; g.lineWidth = Math.max(1.2, 30 * S);
      g.globalAlpha = a * p.waves;
      const spread = p.waveSpread; // 1 = the logo's width; more = the wave runs out to both sides
      part(512 - 250 * spread, 512 - 150, BRAND.rose);
      part(512 - 150, 512 + 50, BRAND.gold);
      part(512 + 50, 512 + 250 * spread, BRAND.mint);
    }
    g.restore();
  }

  /**
   * p: hz (horizon y), scene (0..1 fade from black), line (0..1 the horizon drawing itself), stars, milky, dawn,
   * boatX, boatY, boatS, boatA, glow, reflect, waves, waveDrop, waveSpread, streams, streamGrow, streamAlpha,
   * meteor (0..1 or <0), dim (0..1 black over everything), glowX (where the horizon's light sits).
   */
  function draw(t, p) {
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.globalAlpha = 1; g.globalCompositeOperation = 'source-over';
    g.fillStyle = '#04040F'; g.fillRect(0, 0, W, H);
    const hz = p.hz, d = p.dawn, A = p.scene;
    if (A > 0.002) {
      g.globalAlpha = A;
      // sky
      const sky = g.createLinearGradient(0, 0, 0, hz);
      sky.addColorStop(0, rgba(mixRgb('#05051A', '#1B1D4A', d), 1));
      sky.addColorStop(0.45, rgba(mixRgb('#0D0C2A', '#4A3A78', d), 1));
      sky.addColorStop(0.82, rgba(mixRgb('#1D1B45', '#C0708A', d), 1));
      sky.addColorStop(1, rgba(mixRgb('#322E63', '#F6B48E', d), 1));
      g.fillStyle = sky; g.fillRect(0, 0, W, hz + 1);
      // the Milky Way and the stars
      g.globalCompositeOperation = 'lighter';
      if (p.milky > 0.002) { g.globalAlpha = A * p.milky * (1 - d * 0.85); g.drawImage(milky, 0, 0, W, 900, 0, hz - 900 * (hz / 760), W, 900 * (hz / 760)); }
      const sa = A * p.stars * (1 - d * 0.8);
      if (sa > 0.002) {
        for (const s of stars) {
          const y = s.y * hz, fade = clamp((hz - y) / 90);
          const a = sa * s.b * (0.62 + 0.38 * Math.sin(t * s.tw + s.ph)) * fade;
          if (a < 0.01) continue;
          if (s.r > 1.25) { g.globalAlpha = a; const k = s.r * 7; g.drawImage(glow, s.x * W - k, y - k, k * 2, k * 2); }
          else { g.globalAlpha = 1; g.fillStyle = s.tint < 0.15 ? `rgba(255,214,190,${a.toFixed(3)})` : s.tint > 0.85 ? `rgba(190,210,255,${a.toFixed(3)})` : `rgba(255,255,255,${a.toFixed(3)})`; g.fillRect(s.x * W, y, s.r * 1.6, s.r * 1.6); }
        }
      }
      // a shooting star
      if (p.meteor > 0 && p.meteor < 1) {
        const u = p.meteor, x = lerp(1240, 760, u), y = lerp(110, 330, u), len = 190 * Math.sin(u * Math.PI);
        const mg = g.createLinearGradient(x, y, x + len * 0.92, y - len * 0.42);
        mg.addColorStop(0, `rgba(255,255,255,${(0.95 * A).toFixed(3)})`); mg.addColorStop(1, 'rgba(255,255,255,0)');
        g.globalAlpha = 1; g.strokeStyle = mg; g.lineWidth = 2.2; g.lineCap = 'round';
        g.beginPath(); g.moveTo(x, y); g.lineTo(x + len * 0.92, y - len * 0.42); g.stroke();
      }
      // light on the horizon
      g.globalAlpha = 1;
      const hx = p.glowX ?? W / 2, hr = 900;
      const hg = g.createRadialGradient(hx, hz, 0, hx, hz, hr);
      hg.addColorStop(0, `rgba(246,180,150,${(A * (0.16 + 0.55 * d)).toFixed(3)})`);
      hg.addColorStop(0.3, `rgba(238,140,134,${(A * (0.07 + 0.25 * d)).toFixed(3)})`);
      hg.addColorStop(1, 'rgba(238,140,134,0)');
      g.save(); g.translate(hx, hz); g.scale(1, 0.42); g.translate(-hx, -hz); g.fillStyle = hg; g.fillRect(hx - hr, hz - hr, hr * 2, hr * 2); g.restore();
      g.globalCompositeOperation = 'source-over';
      // water
      g.globalAlpha = A;
      const water = g.createLinearGradient(0, hz, 0, H);
      water.addColorStop(0, rgba(mixRgb('#2B285C', '#E3988C', d), 1));
      water.addColorStop(0.22, rgba(mixRgb('#1A183F', '#7A4F86', d), 1));
      water.addColorStop(1, rgba(mixRgb('#08081C', '#15132F', d), 1));
      g.fillStyle = water; g.fillRect(0, hz, W, H - hz);
      // the far shore: a plain, almost flat
      g.fillStyle = rgba(mixRgb('#0A0A1E', '#3A2A55', d), 1);
      g.beginPath(); g.moveTo(0, hz + 1.5);
      for (let i = 0; i <= 96; i++) g.lineTo((i / 96) * W, hz - 1 - 5 * shore[i] * (0.4 + 0.6 * Math.abs(Math.sin(i * 0.21))));
      g.lineTo(W, hz + 1.5); g.closePath(); g.fill();
      // reflections of the brighter stars, and ripples
      g.globalCompositeOperation = 'lighter';
      if (sa > 0.002) {
        for (const s of bright) {
          const y = hz + (hz - s.y * hz) * 0.5 + 10;
          if (y > H) continue;
          const depth = (y - hz) / (H - hz), a = sa * s.b * 0.34 * (1 - depth * 0.6);
          g.fillStyle = `rgba(210,214,255,${a.toFixed(3)})`;
          for (let k = 0; k < 3; k++) g.fillRect(s.x * W + Math.sin(t * 1.9 + s.ph + k * 2.3) * (1 + depth * 3) - 3, y + k * (5 + depth * 8), 6 + depth * 10, 1.2);
        }
      }
      const rc = mixRgb('#8F8AD0', '#FFD9BC', d);
      for (const r of ripples) {
        const dd = Math.pow(r.d, 1.6), y = hz + 5 + dd * (H - hz - 5), w = (16 + 230 * dd) * r.len, h = 0.9 + 2.6 * dd;
        const x = fract(r.x + (t * (0.004 + 0.02 * dd)) % 1) * (W + w) - w, a = A * (0.035 + 0.13 * Math.max(0, Math.sin(t * r.sp + r.ph))) * (0.5 + 0.5 * dd + d * 0.5);
        g.fillStyle = rgba(rc, a.toFixed(3));
        g.fillRect(x, y, w, h);
      }
      g.globalCompositeOperation = 'source-over';
      g.globalAlpha = 1;
      drawStreams(t, p.streams, p.streamGrow, p.streamAlpha * A);
      drawBoat(t, { ...p, boatA: p.boatA * A });
    }
    // the horizon drawing itself, before there is a world
    if (p.line > 0.002 && p.line < 1) {
      const half = (W / 2) * p.line;
      const lg = g.createLinearGradient(W / 2 - half, 0, W / 2 + half, 0);
      lg.addColorStop(0, 'rgba(200,196,236,0)'); lg.addColorStop(0.5, 'rgba(232,228,255,.9)'); lg.addColorStop(1, 'rgba(200,196,236,0)');
      g.globalAlpha = 1 - A; g.fillStyle = lg; g.fillRect(W / 2 - half, hz - 0.75, half * 2, 1.5);
    }
    if (p.dim > 0.002) { g.globalAlpha = p.dim; g.fillStyle = '#05050F'; g.fillRect(0, 0, W, H); }
    g.globalAlpha = 1;
  }

  return { draw, W, H };
}
