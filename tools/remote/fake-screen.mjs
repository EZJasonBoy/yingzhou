// A stand-in for a 映舟 client on the remote control's hub, for working on the web remote without the app:
//
//   node tools/remote/fake-screen.mjs [engine address, default http://127.0.0.1:19990] [--idle] [--live] [--text]
//
// It registers as a screen "演示屏幕", reports a film that plays (or nothing with --idle, a live channel with --live,
// a focused text field with --text), prints every command it gets and acts on the ones that change what it reports
// (pause, seek, speed, volume, line, episode, subtitle, danmaku, text), so the page can be tried end to end.
// Needs Node 22+ (the built-in WebSocket). Start the engine with --demo on a port of its own; see docs/development.md.
const args = process.argv.slice(2);
const base = (args.find((a) => !a.startsWith('--')) ?? 'http://127.0.0.1:19990').replace(/\/$/, '');
const idle = args.includes('--idle');
const live = args.includes('--live');

const episodes = Array.from({ length: 24 }, (_, i) => `第${i + 1}集`);
const vod = {
  kind: 'vod',
  title: '星河往事 第二季',
  position: 754_000,
  duration: 2_712_000,
  seekable: true,
  paused: false,
  buffering: false,
  error: '',
  speed: 1,
  speeds: [0.5, 0.75, 1, 1.25, 1.5, 2, 3],
  volume: 80,
  muted: false,
  fullscreen: true,
  canFullscreen: true,
  lines: ['演示直链', '演示解析', '备用线路'],
  line: 0,
  episodes,
  episode: 2,
  subtitles: [
    { id: 'off', name: '关闭' },
    { id: 'ext:1', name: '简体中文' },
    { id: 'ext:2', name: '双语特效（ASS）' },
  ],
  subtitleId: 'ext:1',
  audios: [
    { id: '1', name: '音轨 1 · 国语 · 立体声' },
    { id: '2', name: '音轨 2 · English · 立体声' },
  ],
  audioId: '1',
  danmaku: true,
};
const channels = ['CCTV-1 综合', 'CCTV-5 体育', 'CCTV-6 电影', 'CCTV-13 新闻', '演示卫视'];
const tv = {
  kind: 'live',
  title: 'CCTV-6 电影',
  position: 0,
  duration: 0,
  seekable: false,
  paused: false,
  buffering: false,
  error: '',
  speed: 1,
  speeds: [],
  volume: 60,
  muted: false,
  fullscreen: true,
  canFullscreen: true,
  groups: ['央视', '卫视', '地方'],
  group: 0,
  lines: ['线路 1', '线路 2'],
  line: 0,
  episodes: channels,
  episode: 2,
};
const player = idle ? null : live ? tv : vod;
let measuredAt = Date.now();
let text = args.includes('--text') ? { value: '', hint: '搜索', secret: false } : null;
let form = 'tv';

function now() {
  if (player && !player.paused && player.duration > 0) {
    const t = Date.now();
    player.position = Math.min(player.duration, player.position + (t - measuredAt) * player.speed);
    measuredAt = t;
  } else {
    measuredAt = Date.now();
  }
}

function state() {
  now();
  const p = player && { ...player };
  if (p && p.kind === 'vod') p.subtitle = `${p.episodes[p.episode]} · ${p.lines[p.line]}`;
  if (p && p.kind === 'live') p.subtitle = `${p.groups[p.group]} · 正在播出：午间影院`;
  return {
    title: p ? (p.kind === 'vod' ? `${p.title} · ${p.episodes[p.episode]}` : p.title) : '首页',
    page: p ? (p.kind === 'live' ? 'live' : 'player') : 'browse',
    form,
    canTv: true,
    text,
    player: p,
  };
}

const ws = new WebSocket(base.replace(/^http/, 'ws') + '/api/v1/remote/screen', ['yingzhou.remote.v1']);
const publish = () => ws.send(JSON.stringify({ type: 'state', state: state() }));

ws.addEventListener('open', () => {
  ws.send(JSON.stringify({ type: 'hello', id: 'fake-screen', name: '演示屏幕', platform: 'fake', form, version: 'dev' }));
  publish();
  setInterval(publish, 5000);
  console.log(`registered with ${base}; open ${base}/remote/`);
});
ws.addEventListener('close', (e) => {
  console.log(`closed: ${e.code} ${e.reason}`);
  process.exit(e.code === 1000 ? 0 : 1);
});
ws.addEventListener('error', () => console.log('could not connect: is the engine running there?'));
ws.addEventListener('message', (e) => {
  const msg = JSON.parse(e.data);
  if (msg.type !== 'command') {
    if (msg.type !== 'pong') console.log(JSON.stringify(msg));
    if (msg.type === 'controllers') publish();
    return;
  }
  console.log(`${msg.name} ${JSON.stringify(msg.args)}`);
  const a = msg.args ?? {};
  let ok = true;
  let message = '';
  now();
  const needsPlayer = () => {
    if (player) return true;
    ok = false;
    message = '现在没有在播放';
    return false;
  };
  switch (msg.name) {
    case 'key':
    case 'home':
    case 'submit':
      break;
    case 'uiMode':
      form = a.mode === 'tv' ? 'tv' : 'desktop';
      break;
    case 'text':
      if (text) text = { ...text, value: String(a.value ?? '') };
      break;
    case 'toggle':
      if (needsPlayer()) player.paused = !player.paused;
      break;
    case 'play':
    case 'pause':
      if (needsPlayer()) player.paused = msg.name === 'pause';
      break;
    case 'seek':
      if (needsPlayer()) player.position = Math.max(0, Math.min(player.duration, Number(a.position) || 0));
      break;
    case 'seekBy':
      if (needsPlayer()) player.position = Math.max(0, Math.min(player.duration, player.position + (Number(a.delta) || 0)));
      break;
    case 'speed':
      if (needsPlayer()) player.speed = Number(a.value) || 1;
      break;
    case 'volume':
      if (needsPlayer()) player.volume = Math.max(0, Math.min(100, Number(a.value) || 0));
      break;
    case 'volumeBy':
      if (needsPlayer()) player.volume = Math.max(0, Math.min(100, player.volume + (Number(a.delta) || 0)));
      break;
    case 'mute':
      if (needsPlayer()) player.muted = !player.muted;
      break;
    case 'fullscreen':
      if (needsPlayer()) player.fullscreen = !player.fullscreen;
      break;
    case 'danmaku':
      if (needsPlayer()) player.danmaku = !player.danmaku;
      break;
    case 'line':
      if (needsPlayer()) player.line = Number(a.index) || 0;
      break;
    case 'group':
      if (needsPlayer()) player.group = Number(a.index) || 0;
      break;
    case 'episode':
      if (needsPlayer()) {
        player.episode = Number(a.index) || 0;
        if (player.kind === 'vod') player.position = 0;
        else player.title = player.episodes[player.episode];
      }
      break;
    case 'next':
    case 'previous':
      if (needsPlayer()) {
        player.episode = Math.max(0, Math.min(player.episodes.length - 1, player.episode + (msg.name === 'next' ? 1 : -1)));
        if (player.kind === 'vod') player.position = 0;
      }
      break;
    case 'subtitle':
      if (needsPlayer()) player.subtitleId = String(a.id);
      break;
    case 'audio':
      if (needsPlayer()) player.audioId = String(a.id);
      break;
    default:
      ok = false;
      message = `不认识的命令：${msg.name}`;
  }
  ws.send(JSON.stringify({ type: 'result', to: msg.from, id: msg.id, ok, message }));
  publish();
});
