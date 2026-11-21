// Turns the flows recorded by client/integration_test/flows_test.dart into one page: for every flow, the step count,
// a Mermaid diagram of the screens it passes through, and a film strip of what the user saw after each action.
//
//   node tools/design/storyboard.mjs <flow dir>        -> <flow dir>/index.html (open it in a browser)
//
// Counting: a key press, a tap, typing a text, a mouse move each count one action; the app's waiting is shown in
// seconds but not counted. Repeats of the same key in a row are drawn as one arrow ("→ ×3") and still count each.
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const dir = resolve(process.argv[2] || 'dist/design/flows');
const flows = readdirSync(dir, { withFileTypes: true })
  .filter((d) => d.isDirectory() && existsSync(join(dir, d.name, 'flow.json')))
  .map((d) => JSON.parse(readFileSync(join(dir, d.name, 'flow.json'), 'utf8')));
if (!flows.length) throw new Error(`no flow.json under ${dir}`);

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const mm = (s) => String(s).replace(/"/g, "'").replace(/[\[\]{}()<>|#;]/g, ' ');
const KIND = { key: '按键', tap: '点按', type: '输入', move: '移动鼠标', wait: '等待' };
const FORM = { desktop: '桌面', phone: '手机', tablet: '平板', tv: '电视' };

/** The flow's screens as a chain of nodes; an arrow per run of actions between two different screens. */
function diagram(flow) {
  const lines = ['flowchart LR'];
  const nodes = [];
  let edge = [];
  let last = null;
  const flush = (to) => {
    const id = `S${nodes.length}`;
    nodes.push(id);
    lines.push(`  ${id}["${mm(to)}"]`);
    if (nodes.length > 1) {
      const runs = [];
      for (const a of edge) {
        const prev = runs[runs.length - 1];
        if (prev && prev.label === a.label && a.kind === 'key') prev.n++;
        else runs.push({ label: a.label, kind: a.kind, n: 1 });
      }
      const text = runs.map((r) => (r.n > 1 ? `${r.label} ×${r.n}` : r.label)).join(' · ') || '等待';
      lines.push(`  ${nodes[nodes.length - 2]} -->|"${mm(text)}"| ${id}`);
    }
    edge = [];
  };
  for (const s of flow.steps) {
    if (s.kind !== 'wait') edge.push(s);
    if (s.screen !== last) {
      flush(s.screen);
      last = s.screen;
    }
  }
  lines.push('  classDef default fill:#2F2C55,stroke:#F4A08A,color:#ECE9FF,stroke-width:1px');
  return lines.join('\n');
}

function section(flow) {
  const c = flow.counts || {};
  const parts = ['key', 'tap', 'type', 'move'].filter((k) => c[k]).map((k) => `${KIND[k]} ${c[k]}`);
  const wide = flow.size[0] > flow.size[1];
  const strip = flow.steps
    .map(
      (s) => `<figure class="${s.kind}">
        ${s.image ? `<img src="${esc(flow.id)}/${esc(s.image)}" loading="lazy" alt="">` : '<div class="noimg"></div>'}
        <figcaption><b>${s.kind === 'wait' ? '⏳' : s.n}</b> <span class="k">${KIND[s.kind]}</span> ${esc(s.label)}${s.waitedMs != null ? ` <em>${(s.waitedMs / 1000).toFixed(1)} 秒</em>` : ''}<br><small>${esc(s.screen)}</small></figcaption>
      </figure>`,
    )
    .join('\n');
  return `<section>
    <header>
      <h2>${esc(flow.title)}</h2>
      <div class="meta">${FORM[flow.form] || flow.form} · ${flow.size[0]} × ${flow.size[1]}</div>
      <div class="score"><span class="big">${flow.actions}</span> 步 <span class="parts">${parts.join(' · ')}</span> <span class="wait">应用等待 ${(flow.waitedMs / 1000).toFixed(1)} 秒</span></div>
      ${flow.note ? `<p class="note">${esc(flow.note)}</p>` : ''}
    </header>
    <pre class="mermaid">${esc(diagram(flow))}</pre>
    <div class="strip ${wide ? 'wide' : 'tall'}">${strip}</div>
  </section>`;
}

const html = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>映舟 · 流程分镜</title>
<style>
  :root { --night: #17162E; --bar: #211F40; --ink: #ECE9FF; --muted: rgba(201,198,232,.62); --coral: #F4A08A; --gold: #F0C670; --mint: #84CFAE; }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--night); color: var(--ink); font: 14px/1.6 'Microsoft YaHei UI', 'PingFang SC', 'Noto Sans SC', sans-serif; }
  .top { padding: 28px 40px 8px; }
  .top h1 { margin: 0; font-size: 24px; }
  .top p { margin: 6px 0 0; color: var(--muted); }
  .summary { display: flex; gap: 12px; flex-wrap: wrap; padding: 14px 40px 4px; }
  .summary a { color: var(--ink); text-decoration: none; background: var(--bar); border: 1px solid rgba(255,255,255,.1); border-radius: 12px; padding: 10px 14px; }
  .summary a b { color: var(--coral); font-size: 20px; margin-right: 4px; }
  section { margin: 26px 40px 40px; padding: 22px 24px 18px; background: var(--bar); border-radius: 18px; border: 1px solid rgba(255,255,255,.08); }
  header h2 { margin: 0; font-size: 19px; }
  .meta { color: var(--muted); font-size: 12.5px; margin-top: 2px; }
  .score { margin-top: 10px; }
  .score .big { font-size: 34px; font-weight: 700; color: var(--coral); vertical-align: -4px; }
  .score .parts { margin-left: 10px; color: var(--gold); }
  .score .wait { margin-left: 14px; color: var(--muted); }
  .note { margin: 6px 0 0; color: var(--muted); font-size: 13px; }
  pre.mermaid { background: rgba(0,0,0,.18); border-radius: 12px; padding: 14px; overflow-x: auto; margin: 16px 0; }
  .strip { display: flex; gap: 14px; overflow-x: auto; padding-bottom: 10px; }
  figure { margin: 0; flex: none; }
  .strip.wide figure img, .strip.wide .noimg { width: 360px; }
  .strip.tall figure img, .strip.tall .noimg { width: 200px; }
  figure img { display: block; border-radius: 10px; border: 1px solid rgba(255,255,255,.12); }
  figure.wait img { opacity: .82; border-style: dashed; }
  .noimg { aspect-ratio: 16/9; background: rgba(0,0,0,.25); border-radius: 10px; }
  figcaption { max-width: 360px; margin-top: 6px; font-size: 12.5px; }
  .strip.tall figcaption { max-width: 200px; }
  figcaption b { color: var(--coral); margin-right: 2px; }
  figcaption .k { color: var(--mint); }
  figcaption em { color: var(--muted); font-style: normal; }
  figcaption small { color: var(--muted); }
</style>
</head>
<body>
  <div class="top">
    <h1>映舟 · 流程分镜</h1>
    <p>每个流程在真实应用里走一遍：按键、点按、输入、移动鼠标各算一步，应用的等待只记时间。生成于 ${new Date().toLocaleString('zh-CN', { hour12: false })}。</p>
  </div>
  <div class="summary">${flows.map((f) => `<a href="#${esc(f.id)}"><b>${f.actions}</b>步 · ${esc(f.title)}</a>`).join('')}</div>
  ${flows.map((f) => section(f).replace('<section>', `<section id="${esc(f.id)}">`)).join('\n')}
  <script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
  <script>mermaid.initialize({ startOnLoad: true, theme: 'dark', flowchart: { curve: 'basis' }, themeVariables: { fontFamily: 'Microsoft YaHei UI, PingFang SC, sans-serif', lineColor: '#F4A08A', textColor: '#ECE9FF', edgeLabelBackground: '#211F40' } });</script>
</body>
</html>
`;
writeFileSync(join(dir, 'index.html'), html);
console.log(`storyboard: ${join(dir, 'index.html')} (${flows.length} flows)`);
