// The promo source: a TVBox config with three plain MacCMS-JSON sites (type 1), fictional titles, generated posters
// and an original clip. No spider code anywhere. Also serves tools/promo itself so the film, poster and portfolio
// pages can be rendered over http.
//
//   node tools/promo/server.mjs [port]        (default 5199)
import { createServer } from 'node:http';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CATALOG, CLASSES, className } from './catalog.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
export const BUILD = process.env.PROMO_BUILD || join(repo, 'dist/promo/build');
const port = Number(process.argv[2] || 5199);

const SITES = [
  { key: 'zhou', name: '孤舟影库', filter: () => true },
  { key: 'xing', name: '星垂放映室', filter: (c) => c.cls === '1' || c.cls === '3' },
  { key: 'jiang', name: '大江纪录', filter: (c) => c.cls === '4' || c.cls === '2' },
];

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.m3u8': 'application/vnd.apple.mpegurl',
  '.ts': 'video/mp2t', '.wav': 'audio/wav', '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.srt': 'text/plain; charset=utf-8',
};

function card(c, base, detail) {
  const o = {
    vod_id: String(c.id),
    vod_name: c.name,
    vod_pic: `${base}/build/posters/${c.id}.jpg`,
    vod_remarks: c.eps === 1 ? (c.id % 3 === 0 ? '4K' : 'HD') : c.id % 2 ? `全${c.eps}集` : `更新至${Math.max(2, c.eps - 3)}集`,
    type_id: c.cls,
    type_name: className(c.cls),
    vod_year: String(c.year),
    vod_score: c.score,
  };
  if (detail) {
    const eps = Array.from({ length: c.eps }, (_, i) => (c.eps === 1 ? '正片' : `第${i + 1}集`));
    const line = () => eps.map((n) => `${n}$${base}/build/media/${c.eps === 1 ? 'film' : 'episode'}.m3u8`).join('#');
    Object.assign(o, {
      vod_area: c.area,
      vod_lang: '国语',
      vod_actor: c.actors.join(','),
      vod_director: c.director,
      vod_content: c.blurb,
      vod_play_from: ['映舟直连', '备用线路', '4K 线路'].join('$$$'),
      vod_play_url: [line(), line(), line()].join('$$$'),
    });
  }
  return o;
}

function api(site, q, base) {
  const all = CATALOG.filter(site.filter);
  const page = (list, pg, detail) => {
    const size = 24;
    return { page: pg, pagecount: Math.max(1, Math.ceil(list.length / size)), limit: String(size), total: list.length, list: list.slice((pg - 1) * size, pg * size).map((c) => card(c, base, detail)) };
  };
  const pg = Math.max(1, Number(q.get('pg') || 1));
  if (q.get('ids') != null) return page(q.get('ids').split(',').map((id) => all.find((c) => String(c.id) === id)).filter(Boolean), 1, true);
  if (q.get('wd') != null) return page(all.filter((c) => c.name.includes(q.get('wd'))), pg, false);
  if (q.get('t') != null) return page(all.filter((c) => c.cls === q.get('t')), pg, false);
  const classes = CLASSES.filter((k) => all.some((c) => c.cls === k.id));
  return { class: classes.map((k) => ({ type_id: k.id, type_name: k.name })), list: all.slice(0, 24).map((c) => card(c, base, false)) };
}

const config = (base) => ({
  wallpaper: '',
  // Asked only after the config's danmaku API is switched on in the engine's settings.
  danmaku: `${base}/danmaku/api?name={name}&episode={episode}`,
  sites: SITES.map((s) => ({ key: s.key, name: s.name, type: 1, api: `${base}/api/${s.key}/`, searchable: 1, quickSearch: 1, filterable: 1 })),
  parses: [],
  lives: existsSync(join(BUILD, 'media/live.m3u8')) ? [{ name: '映舟演示台', type: 0, url: `${base}/live.m3u`, epg: `${base}/epg?ch={name}&date={date}` }] : [],
});

const CHANNELS = [
  ['江上', '江上纪实'], ['江上', '大江电影'], ['江上', '孤舟剧场'], ['星野', '星野音乐'], ['星野', '平野新闻'], ['星野', '月涌体育'], ['星野', '万流少儿'],
];
// Made-up comments for the player's danmaku layer (`p` = time,mode,colour,uid).
const SAID = ['这镜头绝了', '每一帧都是壁纸', '配乐一响，我人没了', '日出这段我能看十遍', '船！是那条船', '壁纸预定', '二刷报到', '这调色太舒服了', '好安静，好喜欢', '已截图',
  '谁谓河广，一苇杭之', '摄影加鸡腿', '前方高能', '光影满分', '打卡', '泪目', '镜头语言好克制', '这一幕值回票价', '慢一点，再慢一点', '映舟启动', '大江流～', '想去这里看日出',
  '导演是懂留白的', '弹幕护体', '第一次看，求不剧透', '这是什么神仙开场', '音乐叫什么名字', '好像一幅画', '星垂平野阔', '月涌大江流', '晚上好', '周末愉快'];
const DANMAKU = Array.from({ length: 90 }, (_, i) => {
  const time = (i * 0.95 + (i % 5) * 0.3).toFixed(2), mode = 1;
  const colour = [0xffffff, 0xffffff, 0xffffff, 0xf4a08a, 0xffffff, 0xf0c670, 0xffffff, 0x84cfae][i % 8];
  return { cid: i, p: `${time},${mode},${colour},promo${i}`, m: SAID[(i * 7) % SAID.length] };
});

const PROGRAMMES = ['晨间航线', '大江流（1）', '纸船远航', '午间放映室', '群岛纪事', '匠人手记', '星垂平野', '傍晚新闻', '山海长歌', '深夜渡口', '极夜观测站', '夜航'];

function sendFile(req, res, file) {
  const st = statSync(file);
  const type = TYPES[extname(file).toLowerCase()] || 'application/octet-stream';
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
  const head = { 'Content-Type': type, 'Accept-Ranges': 'bytes', 'Cache-Control': 'no-store', 'Access-Control-Allow-Origin': '*' };
  if (range) {
    const start = range[1] ? Number(range[1]) : Math.max(0, st.size - Number(range[2]));
    const end = range[1] && range[2] ? Math.min(Number(range[2]), st.size - 1) : st.size - 1;
    res.writeHead(206, { ...head, 'Content-Range': `bytes ${start}-${end}/${st.size}`, 'Content-Length': end - start + 1 });
    if (req.method === 'HEAD') return res.end();
    return createReadStream(file, { start, end }).pipe(res);
  }
  res.writeHead(200, { ...head, 'Content-Length': st.size });
  if (req.method === 'HEAD') return res.end();
  createReadStream(file).pipe(res);
}

createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const base = `http://${req.headers.host}`;
  const json = (o) => {
    res.writeHead(200, { 'Content-Type': TYPES['.json'], 'Access-Control-Allow-Origin': '*' });
    res.end(JSON.stringify(o));
  };
  const path = decodeURIComponent(url.pathname);
  if (path === '/config.json') return json(config(base));
  const m = /^\/api\/(\w+)\/?$/.exec(path);
  if (m) {
    const site = SITES.find((s) => s.key === m[1]);
    if (site) return json(api(site, url.searchParams, base));
  }
  if (path === '/danmaku/api') return json(url.searchParams.get('name') ? { url: `${base}/danmaku/comments.json` } : {});
  if (path === '/danmaku/comments.json') return json({ count: DANMAKU.length, comments: DANMAKU });
  if (path === '/live.m3u') {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end('#EXTM3U\n' + CHANNELS.map(([g, n], i) => `#EXTINF:-1 tvg-name="${n}" tvg-logo="${base}/build/posters/${i * 3 + 1}.jpg" group-title="${g}",${n}\n${base}/build/media/live.m3u8`).join('\n') + '\n');
  }
  if (path === '/epg') {
    const date = url.searchParams.get('date') || new Date().toISOString().slice(0, 10);
    const seed = [...(url.searchParams.get('ch') || '')].reduce((a, c) => a + c.charCodeAt(0), 0);
    const hh = (h) => String(h).padStart(2, '0') + ':00';
    return json({ date, epg_data: PROGRAMMES.map((_, i) => ({ start: hh(i * 2), end: hh(i * 2 + 2 === 24 ? 0 : i * 2 + 2), title: PROGRAMMES[(i + seed) % PROGRAMMES.length] })) });
  }
  const root = path.startsWith('/build/') ? BUILD : here;
  const rel = normalize(path.startsWith('/build/') ? path.slice(7) : path).replace(/^([/\\])+/, '');
  const file = join(root, rel);
  if (!file.startsWith(root) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    return res.end('not found');
  }
  sendFile(req, res, file);
}).listen(port, '127.0.0.1', () => console.log(`promo source on http://127.0.0.1:${port}  (build dir ${BUILD})`));
