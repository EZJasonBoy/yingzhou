// The film's soundtrack, synthesised here from sine waves and noise (no samples, no downloads): a drone and a pad in
// D, plucked figures that follow the poems, soft pulses under the product scenes, and a few transitions.
// 80 BPM, so a bar is 3 s and the film's cuts fall on bars.   ->  dist/promo/build/audio.wav
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const build = process.env.PROMO_BUILD || resolve(here, '../../dist/promo/build');
const SR = 48000, DUR = 78, N = SR * DUR, TAU = Math.PI * 2;
const L = new Float32Array(N), R = new Float32Array(N), SL = new Float32Array(N), SRr = new Float32Array(N);

const SEMI = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
const hz = (name) => {
  const m = /^([A-G])(#?)(\d)$/.exec(name);
  return 440 * 2 ** ((SEMI[m[1]] + (m[2] ? 1 : 0) + (Number(m[3]) + 1) * 12 - 69) / 12);
};
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const seg = (t, a, b) => clamp((t - a) / (b - a));

/** Adds fn(t) (t from 0) at t0 for dur seconds, panned, with a share sent to the reverb. */
function add(t0, dur, fn, pan = 0, send = 0.3) {
  const i0 = Math.floor(t0 * SR), n = Math.floor(dur * SR), gl = Math.cos(((pan + 1) * Math.PI) / 4), gr = Math.sin(((pan + 1) * Math.PI) / 4);
  for (let i = 0; i < n; i++) {
    const j = i0 + i;
    if (j < 0 || j >= N) continue;
    const v = fn(i / SR);
    L[j] += v * gl; R[j] += v * gr; SL[j] += v * gl * send; SRr[j] += v * gr * send;
  }
}

/** A plucked string: harmonics that die away the faster the higher they are. */
const pluck = (note, t0, amp = 0.1, pan = 0, send = 0.45) => {
  const f = hz(note);
  amp *= 1.5;
  add(t0, 3.4, (t) => {
    const bend = 1 + 0.006 * Math.exp(-t * 40);
    let v = 0;
    for (let h = 1; h <= 7; h++) v += (Math.sin(TAU * f * h * t * bend) * Math.exp(-t * (1.3 + h * 1.15))) / h ** 1.15;
    return amp * v * Math.min(1, t / 0.004);
  }, pan, send);
};
/** A soft bell (two-operator FM). */
const bell = (note, t0, amp = 0.05, pan = 0, send = 0.6) => {
  const f = hz(note);
  amp *= 1.3;
  add(t0, 4.5, (t) => amp * Math.sin(TAU * f * t + 1.6 * Math.exp(-t * 3.2) * Math.sin(TAU * f * 2.76 * t)) * Math.exp(-t * 1.25) * Math.min(1, t / 0.005), pan, send);
};
/** A pad chord: a few soft harmonics per note, slightly detuned between left and right. */
function pad(notes, t0, dur, amp = 0.03) {
  amp *= 1.7;
  const i0 = Math.floor(t0 * SR), att = 1.9, rel = 2.6, n = Math.floor((dur + rel) * SR);
  notes.forEach((note, k) => {
    const f = hz(note), ph = k * 1.7;
    for (let i = 0; i < n; i++) {
      const j = i0 + i;
      if (j < 0 || j >= N) continue;
      const t = i / SR, e = Math.min(1, t / att) ** 1.5 * (t > dur ? Math.exp(-(t - dur) * 1.5) : 1) * (0.84 + 0.16 * Math.sin(TAU * 0.11 * (t0 + t) + ph));
      let l = 0, r = 0;
      for (let h = 1; h <= 4; h++) {
        const a = 1 / h ** 2;
        l += a * Math.sin(TAU * f * 0.9982 * h * t + ph * h);
        r += a * Math.sin(TAU * f * 1.0018 * h * t + ph * h + 0.6);
      }
      L[j] += amp * e * l; R[j] += amp * e * r; SL[j] += amp * e * l * 0.5; SRr[j] += amp * e * r * 0.5;
    }
  });
}
const kick = (t0, amp = 0.2) => {
  let ph = 0;
  add(t0, 0.5, (t) => {
    ph += (TAU * (44 + 62 * Math.exp(-t * 26))) / SR;
    return amp * Math.sin(ph) * Math.exp(-t * 8.5) * Math.min(1, t / 0.003);
  }, 0, 0.05);
};
const boom = (t0, amp = 0.3) => {
  let ph = 0;
  add(t0, 4, (t) => {
    ph += (TAU * (36 + 46 * Math.exp(-t * 5))) / SR;
    return amp * Math.sin(ph) * Math.exp(-t * 1.25) * Math.min(1, t / 0.006);
  }, 0, 0.25);
};
const tick = (t0, f = 1300, amp = 0.035, pan = 0) => add(t0, 0.09, (t) => amp * Math.sin(TAU * f * t) * Math.exp(-t * 90), pan, 0.35);
const thump = (t0, amp = 0.16) => add(t0, 0.6, (t) => amp * Math.sin(TAU * (70 + 40 * Math.exp(-t * 30)) * t) * Math.exp(-t * 9), 0.2, 0.5);

// ---- the score --------------------------------------------------------------------------------------------------------

// The drone, from the first second to the end.
add(0.6, DUR - 0.6, (t) => {
  const e = Math.min(1, t / 4) * (0.8 + 0.2 * Math.sin(TAU * 0.07 * t));
  return e * (0.036 * Math.sin(TAU * hz('D2') * t) + 0.026 * Math.sin(TAU * hz('A2') * t + 1) + 0.016 * Math.sin(TAU * hz('D3') * t + 2));
}, 0, 0.3);

// Pads: [start, length, notes, level]
[
  [1.5, 10.5, ['D3', 'A3', 'E4'], 0.016],
  [12, 6, ['D3', 'F#3', 'A3', 'E4', 'A4'], 0.034],
  [18, 6, ['B2', 'F#3', 'A3', 'D4'], 0.028],
  [24, 6, ['G2', 'D3', 'A3', 'B3', 'F#4'], 0.028],
  [30, 6, ['A2', 'E3', 'B3', 'D4'], 0.028],
  [36, 3, ['A2', 'E3', 'A3', 'C#4', 'E4'], 0.028],
  [39, 4.5, ['B2', 'F#3', 'D4', 'A4'], 0.02],
  [43.5, 4.5, ['G2', 'D3', 'B3', 'F#4'], 0.028],
  [48, 4.5, ['A2', 'E3', 'B3', 'D4'], 0.028],
  [52.5, 4.5, ['B2', 'F#3', 'A3', 'D4', 'F#4'], 0.03],
  [57, 3, ['G2', 'D3', 'B3', 'D4'], 0.03],
  [60, 3, ['A2', 'E3', 'B3', 'E4'], 0.031],
  [63, 3, ['A2', 'E3', 'A3', 'C#4', 'G4'], 0.033],
  [66, 6, ['D3', 'A3', 'D4', 'F#4', 'A4', 'E5'], 0.036],
  [72, 4.6, ['D3', 'A3', 'D4', 'F#4', 'A4'], 0.03],
].forEach(([t0, len, notes, amp]) => pad(notes, t0, len, amp));

// Plucked figures on the poems: one note per character as it appears.
const figure = (t0, notes, step = 0.26, amp = 0.1, pan = 0.25) => notes.forEach((n, i) => pluck(n, t0 + i * step, amp * (0.85 + 0.05 * i), pan + (i % 2 ? 0.12 : -0.12)));
figure(2.3, ['A3', 'D4', 'E4', 'A4']);
figure(7.5, ['B3', 'D4', 'F#4', 'D5']);
thump(9.7);
figure(39.5, ['B3', 'D4', 'E4', 'F#4', 'A4'], 0.26, 0.1, -0.25);
figure(41.0, ['A3', 'B3', 'D4', 'F#4', 'B4'], 0.26, 0.1, -0.25);
thump(42.5);
[0, 1, 2, 3, 4].forEach((i) => bell(['A6', 'F#6', 'E6', 'D6', 'A5'][i], 40.62 + i * 0.09, 0.012, 0.5 - i * 0.2));
figure(66.9, ['D4', 'E4', 'F#4', 'A4', 'B4'], 0.26, 0.11, -0.1);
figure(68.5, ['D4', 'F#4', 'A4', 'B4', 'D5'], 0.26, 0.11, 0.1);
['D5', 'E5', 'F#5', 'A5', 'B5'].forEach((n, i) => bell(n, 66.9 + i * 0.26, 0.022, -0.3));
['D5', 'F#5', 'A5', 'B5', 'D6'].forEach((n, i) => bell(n, 68.5 + i * 0.26, 0.022, 0.3));

// The title and the two other landings.
boom(12);
['D5', 'A5', 'D6', 'F#6', 'A6'].forEach((n, i) => bell(n, 12 + i * 0.11, 0.045 - i * 0.005, i % 2 ? 0.5 : -0.5));
pluck('D3', 12, 0.2, 0, 0.5); pluck('A3', 12.02, 0.12, -0.3); pluck('D4', 12.04, 0.1, 0.3);
boom(39, 0.14); boom(66, 0.28);
['D5', 'F#5', 'A5', 'D6'].forEach((n, i) => bell(n, 66 + i * 0.1, 0.035, i % 2 ? 0.4 : -0.4));
['A4', 'D5', 'F#5', 'A5', 'D6'].forEach((n, i) => bell(n, 72.2 + i * 0.16, 0.034, i % 2 ? -0.35 : 0.35));
pluck('D3', 72.2, 0.16, 0, 0.5);

// The arpeggio under the product scenes: eighth notes (0.375 s) over the chord of the bar.
const ARP = { D: ['D4', 'A4', 'F#4', 'A4', 'E5', 'A4', 'F#4', 'A4'], Bm: ['B3', 'F#4', 'D4', 'F#4', 'A4', 'F#4', 'D4', 'F#4'], G: ['G3', 'D4', 'B3', 'D4', 'A4', 'D4', 'B3', 'D4'], A: ['A3', 'E4', 'B3', 'E4', 'D5', 'E4', 'B3', 'E4'] };
const chordAt = (t) => (t < 24 ? 'Bm' : t < 30 ? 'G' : t < 39 ? 'A' : t < 48 ? 'G' : t < 52.5 ? 'A' : t < 57 ? 'Bm' : t < 60 ? 'G' : 'A');
for (let t = 18, i = 0; t < 65.6; t += 0.375, i++) {
  if (t >= 38.6 && t < 43.5) continue;
  const lift = t >= 57 ? 0.085 + 0.03 * seg(t, 57, 66) : t >= 43.5 ? 0.075 : 0.06 * seg(t, 18, 20) + 0.01;
  pluck(ARP[chordAt(t)][i % 8], t, lift * (i % 4 === 0 ? 1.15 : 0.8), i % 2 ? 0.45 : -0.45, 0.5);
}
// A soft pulse: beats one and three, a little more from the second act on.
for (let t = 18; t < 66; t += 1.5) {
  if (t >= 38.6 && t < 43.5) continue;
  kick(t, t < 21 ? 0.1 : t >= 57 ? 0.2 : 0.16);
  if (t >= 43.5) kick(t + 1.125, 0.07);
}
// Small sounds on what the picture does: keys, taps, the remote.
[0, 1, 2, 3, 4].forEach((i) => tick(37.0 + i * 0.3, 1500 + i * 120, 0.03, -0.5 + i * 0.1));
tick(46.15, 900, 0.03, 0.2); tick(46.4, 900, 0.03, 0.2);
[49.35, 50.35, 51.35].forEach((t, i) => tick(t, 1100 + i * 150, 0.032, 0.6));
for (let i = 0; i < 12; i++) tick(59.5 + i * 0.09, 1700 + (i % 4) * 160, 0.014, -0.6 + i * 0.1);
['D4', 'F#4', 'A4', 'D5'].forEach((n, i) => pluck(n, 63.0 + i * 0.16, 0.12, -0.4 + i * 0.25));

// ---- noise: water, transitions, a shaker ------------------------------------------------------------------------------
{
  let seed = 123456789;
  const rnd = () => ((seed = (Math.imul(seed, 1664525) + 1013904223) | 0) / 2147483648);
  const water = (t) => 0.3 + 0.7 * (t < 12 ? 1 : t < 18 ? 0.55 : t < 38.5 ? 0.25 : t < 43.5 ? 0.9 : t < 66 ? 0.2 : 0.7);
  const swells = [[11.15, 12, 0.5], [23.3, 24, 0.3], [29.3, 30, 0.3], [38.2, 39, 0.4], [43.0, 43.5, 0.22], [47.5, 48, 0.22], [52.0, 52.5, 0.22], [56.4, 57, 0.3], [62.4, 63, 0.3], [63.2, 66, 0.75], [71.4, 72.2, 0.3]];
  let lpL = 0, lpR = 0, lp2L = 0, lp2R = 0, hpL = 0, hpR = 0, mdL = 0, mdR = 0;
  for (let i = 0; i < N; i++) {
    const t = i / SR, a = rnd(), b = rnd();
    // water: a band of noise between roughly 400 Hz and 2 kHz, slowly breathing, well under the music
    lpL += 0.05 * (a - lpL); lpR += 0.05 * (b - lpR); lp2L += 0.05 * (lpL - lp2L); lp2R += 0.05 * (lpR - lp2R);
    mdL += 0.24 * (a - mdL); mdR += 0.24 * (b - mdR);
    const w = 0.085 * water(t) * Math.min(1, t / 3) * (0.55 + 0.45 * Math.sin(TAU * t / 5.7)) * (0.8 + 0.2 * Math.sin(TAU * t / 1.9 + 1));
    let l = (mdL - lp2L) * w, r = (mdR - lp2R) * w;
    // swells before the cuts: brighter as they rise
    let s = 0, bright = 0;
    for (const [t0, t1, amp] of swells) {
      if (t >= t0 && t < t1 + 0.35) { const u = t < t1 ? ((t - t0) / (t1 - t0)) ** 2.2 : Math.exp(-(t - t1) * 9); if (amp * u > s) { s = amp * u; bright = t < t1 ? (t - t0) / (t1 - t0) : 1; } }
    }
    if (s > 0) {
      const k = 0.02 + 0.5 * bright * bright;
      hpL += k * (a - hpL); hpR += k * (b - hpR);
      l += hpL * s * 0.2; r += hpR * s * 0.2;
    }
    // a shaker on the eighths
    if ((t >= 24 && t < 38.6) || (t >= 43.5 && t < 65.8)) {
      const beat = (t - 18) / 0.375, f = beat - Math.floor(beat), acc = Math.floor(beat) % 2 ? 1 : 0.55;
      const e = Math.exp(-f * 0.375 * 55) * 0.014 * acc * (t >= 57 ? 1.3 : 1);
      l += (a - lpL) * e * (Math.floor(beat) % 2 ? 0.6 : 1); r += (b - lpR) * e * (Math.floor(beat) % 2 ? 1 : 0.6);
    }
    L[i] += l; R[i] += r; SL[i] += l * 0.25; SRr[i] += r * 0.25;
  }
}

// ---- reverb (four combs and two all-passes a side), mix, limit --------------------------------------------------------
function reverb(input, combMs, apMs) {
  const out = new Float32Array(N);
  for (const ms of combMs) {
    const len = Math.round((ms * SR) / 1000), buf = new Float32Array(len);
    let p = 0, damp = 0;
    for (let i = 0; i < N; i++) {
      const y = buf[p];
      damp += 0.32 * (y - damp);
      buf[p] = input[i] + damp * 0.9;
      out[i] += y;
      p = p + 1 === len ? 0 : p + 1;
    }
  }
  for (const ms of apMs) {
    const len = Math.round((ms * SR) / 1000), buf = new Float32Array(len);
    let p = 0;
    for (let i = 0; i < N; i++) {
      const b = buf[p], x = out[i];
      buf[p] = x + b * 0.6;
      out[i] = b - x * 0.6;
      p = p + 1 === len ? 0 : p + 1;
    }
  }
  return out;
}
const WL = reverb(SL, [41.3, 47.9, 53.1, 59.7], [6.1, 1.9]);
const WR = reverb(SRr, [42.7, 46.3, 54.9, 58.1], [5.3, 2.3]);

let peak = 0, dcL = 0, dcR = 0;
for (let i = 0; i < N; i++) {
  const t = i / SR, fade = Math.min(1, t / 0.25) * (1 - seg(t, 75.2, 77.9) ** 1.6);
  const l = L[i] + WL[i] * 0.22, r = R[i] + WR[i] * 0.22;
  dcL += 0.004 * (l - dcL); dcR += 0.004 * (r - dcR);
  L[i] = Math.tanh((l - dcL) * 1.5) * fade;
  R[i] = Math.tanh((r - dcR) * 1.5) * fade;
  peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
}
const gain = 0.89 / peak;
const pcm = Buffer.alloc(44 + N * 4);
pcm.write('RIFF', 0); pcm.writeUInt32LE(36 + N * 4, 4); pcm.write('WAVEfmt ', 8); pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(2, 22);
pcm.writeUInt32LE(SR, 24); pcm.writeUInt32LE(SR * 4, 28); pcm.writeUInt16LE(4, 32); pcm.writeUInt16LE(16, 34); pcm.write('data', 36); pcm.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) {
  pcm.writeInt16LE(Math.round(clamp(L[i] * gain, -1, 1) * 32767), 44 + i * 4);
  pcm.writeInt16LE(Math.round(clamp(R[i] * gain, -1, 1) * 32767), 46 + i * 4);
}
mkdirSync(build, { recursive: true });
writeFileSync(join(build, 'audio.wav'), pcm);
console.log(`audio done: ${DUR} s, peak before gain ${peak.toFixed(3)}`);
