// 日志与崩溃 (docs/design/web-console.md): the screen's crash records, its log and its engine's output, asked for over
// the control socket (diag.summary, diag.log, diag.crash, diag.engineLog, diag.report). The screen redacts all of it
// before it leaves the device. 下载全部 saves diag.report as a file built here; 生成反馈 opens the project's new-issue
// form and puts the full text on this device's clipboard.

const ISSUE_URL = 'https://github.com/Sa1koro/yingzhou/issues/new';
const ISSUE_TEMPLATE = 'bug_report.yml';
const POLL_MS = 2000;
const PAGE = 200;
const KEEP = 2000;

const LEVEL_NAMES = { info: '信息', warn: '警告', error: '错误' };
const SOURCES = { flutter: '应用', dart: '应用', app: '应用', zone: '应用', isolate: '应用', ui: '界面', player: '播放器', engine: '内置引擎', native: '系统', platform: '系统' };
const ENGINE_KINDS = { builtin: '内置引擎', embedded: '内置引擎', bundled: '内置引擎', local: '本机的引擎', internal: '内置引擎', remote: '别处的引擎', lan: '局域网里的引擎', external: '别处的引擎' };
const FORMS = { desktop: '桌面', phone: '手机', tablet: '平板', tv: '电视' };

function levelOf(raw) {
  const text = String(raw || '').toLowerCase();
  if (/err|fatal|severe|crit|shout/.test(text)) return 'error';
  if (/warn/.test(text)) return 'warn';
  return 'info';
}

/** A time as the screen sent it (epoch milliseconds or an ISO string) as a Date; null when it is neither. */
function dateOf(value) {
  if (value == null || value === '') return null;
  const ms = typeof value === 'number' ? value : /^\d+$/.test(String(value)) ? Number(value) : Date.parse(String(value));
  return Number.isFinite(ms) ? new Date(ms) : null;
}

const pad = (n, w) => String(n).padStart(w || 2, '0');

export default function mount(root, core) {
  const { h, icon, fmt } = core;

  let summary = null; // diag.summary's data, or null
  let support = 'unknown'; // 'yes', 'no' (an older screen), 'offline'
  let entries = [];
  let next = null;
  let level = 'all';
  let query = '';
  let follow = true;
  let selected = null; // the selected entry
  let timer = 0;
  let visible = false;
  let loading = false;
  let report = { text: '', at: 0 };
  let seen = new Set();
  let expanded = null; // the crash shown open

  // ---- the page ----

  const feedbackButtons = [];
  const downloadButtons = [];
  const button = (cls, iconName, text, list, onclick) => {
    const el = h('button', { type: 'button', class: 'btn ' + cls, onclick }, iconName ? icon(iconName) : null, text);
    list.push(el);
    return el;
  };
  const head = core.pageHead({
    title: '日志与崩溃',
    actions: [button('', 'feedback', '生成反馈', feedbackButtons, feedback), button('primary', 'download', '下载全部', downloadButtons, downloadAll)],
  });
  const redacted = h('p', { class: 'ok-line' }, icon('shield'), h('span', { text: '订阅地址、令牌和用户目录在离开电视之前已经遮掉，可以直接贴出去。' }));
  const notice = h('div', { class: 'empty-note', hidden: true });

  const crashCount = h('span', { class: 'count' });
  const crashRows = h('div', { class: 'rows' });
  const crashSection = h('section', { class: 'section' }, h('div', { class: 'section-head' }, h('h2', { class: 'card-title' }, '崩溃记录', crashCount)), crashRows);

  const chips = {};
  const filterChip = (name, label, extra) => {
    const count = h('b');
    const el = h('button', { type: 'button', class: 'chip inv ' + (extra || ''), onclick: () => setLevel(name) }, label + ' ', count);
    el.count = count;
    chips[name] = el;
    return el;
  };
  const followButton = h('button', { type: 'button', class: 'follow', 'aria-pressed': 'true', onclick: () => setFollow(!follow) }, h('i'), '实时跟随');
  const search = h('input', { type: 'search', placeholder: '搜模块、内容或报错', 'aria-label': '搜日志' });
  search.addEventListener('input', () => {
    query = search.value.trim().toLowerCase();
    renderLog();
  });
  const list = h('div', { class: 'log-list', role: 'list' });
  const detail = h('aside', { class: 'card log-detail', 'aria-live': 'polite' });
  const logSection = h(
    'section',
    { class: 'section' },
    h(
      'div',
      { class: 'filters' },
      h('h2', { class: 'card-title', text: '日志' }),
      filterChip('all', '全部'),
      filterChip('info', '信息', 'wide-only'),
      filterChip('warn', '警告', 'lv-warn'),
      filterChip('error', '错误', 'lv-error'),
      followButton,
      h('label', { class: 'search' }, icon('search'), search),
    ),
    h('div', { class: 'log-wrap' }, list, detail),
  );

  const engineText = h('pre', { class: 'pre', text: '' });
  const engineTitle = h('span', { text: '引擎输出' });
  const engineDetails = h(
    'details',
    { class: 'card engine-log' },
    h('summary', null, icon('chevron'), engineTitle, h('span', { class: 'card-meta', text: '最后 300 行' })),
    engineText,
  );
  engineDetails.addEventListener('toggle', () => {
    if (engineDetails.open) loadEngineLog();
  });

  const foot = h('p', {
    class: 'note-faint',
    text: '「下载全部」存成一个文本文件，「生成反馈」打开 GitHub 的新问题页并把全文复制到这台设备的剪贴板。应用一打开就崩的时候这里连不上：记录存在电视上，下次能打开时还在。',
  });
  const bottom = h(
    'div',
    { class: 'bottom-bar' },
    button('', null, '下载全部', downloadButtons, downloadAll),
    button('primary', null, '生成反馈', feedbackButtons, feedback),
  );

  core.append(root, [head, redacted, notice, crashSection, logSection, engineDetails, foot, bottom]);

  // ---- what the screen says about itself ----

  function deviceLine() {
    const screen = core.screen() || {};
    const app = (summary && summary.app) || {};
    const form = app.form || screen.form || '';
    let platform = String(app.platform || '');
    if (platform && form === 'tv' && /^android\b/i.test(platform) && !/tv/i.test(platform)) platform = platform.replace(/^android/i, 'Android TV');
    else if (!platform) platform = fmt.platformLabel(screen.platform, screen.form);
    const version = app.version || screen.version || '';
    const engine = (summary && summary.engine) || {};
    const kind = ENGINE_KINDS[String(engine.kind || '').toLowerCase()] || (engine.kind ? String(engine.kind) : '');
    return [screen.name || '映舟', platform, version ? '映舟 ' + version : '', kind].filter(Boolean).join(' · ');
  }

  function showNotice(title, text) {
    notice.textContent = '';
    notice.append(h('b', { text: title }), text);
    notice.hidden = false;
  }

  function setSupported(yes) {
    for (const el of [crashSection, logSection, foot, redacted]) el.hidden = !yes;
    engineDetails.hidden = !yes || !(summary && summary.hasEngineLog);
    for (const el of feedbackButtons.concat(downloadButtons)) el.disabled = !yes;
    bottom.hidden = !yes;
  }

  async function loadSummary() {
    if (!core.connected()) {
      support = 'offline';
      setSupported(false);
      showNotice('还没有连上屏幕', '连上以后，这里显示它的崩溃记录和日志。');
      head.setSub(deviceLine());
      return;
    }
    const r = await core.command('diag.summary', {}, 8000);
    if (r.ok && r.data) {
      summary = r.data;
      support = 'yes';
      notice.hidden = true;
      setSupported(true);
      renderCrashes();
    } else if (r.offline) {
      support = 'offline';
      setSupported(false);
      showNotice('和屏幕的连接断了', '连回来以后这里会自己刷新。');
    } else {
      summary = null;
      support = 'no';
      setSupported(false);
      showNotice(
        '这块屏幕上的映舟还发不来日志和崩溃记录',
        '把电视上的映舟更新到最新版本后再打开这一页。在那之前，电视上的「设置 → 关于 → 诊断与反馈」里可以复制诊断信息。',
      );
    }
    head.setSub(deviceLine());
  }

  // ---- crash records ----

  function crashTime(date) {
    if (!date) return '';
    const now = new Date();
    const seconds = pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
    if (date.toDateString() === now.toDateString()) return '今天 ' + seconds;
    return (date.getFullYear() === now.getFullYear() ? '' : date.getFullYear() + '-') + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' + seconds;
  }

  function renderCrashes() {
    const crashes = summary && Array.isArray(summary.crashes) ? summary.crashes.filter((c) => c && typeof c === 'object') : [];
    crashCount.textContent = String(crashes.length);
    crashRows.textContent = '';
    if (!crashes.length) {
      crashRows.append(h('div', { class: 'rowline' }, h('span', { class: 'rowline-sub', text: '没有崩溃记录。' })));
      return;
    }
    // On a phone the newest opens by itself, as the record most likely wanted.
    if (expanded == null && !core.wide()) expanded = String(crashes[0].id);
    for (const crash of crashes) {
      const id = String(crash.id);
      const date = dateOf(crash.time);
      const repeated = Number(crash.repeated) || 0;
      const open = expanded === id;
      const body = h('div', { class: 'crash-detail', hidden: !open });
      const row = h(
        'div',
        { class: 'crash' },
        icon('warn'),
        h('span', { class: 't', text: crashTime(date) }),
        h('span', { class: 'm', text: crash.label ? String(crash.label) : SOURCES[String(crash.source || '').toLowerCase()] || String(crash.source || '') }),
        h('span', { class: 'msg', text: String(crash.title || '（没有说明）') }),
        repeated > 1 ? h('span', { class: 'badge warn', text: '重复 ' + repeated + ' 次' }) : null,
        h(
          'span',
          { class: 'rowline-actions' },
          h('button', { type: 'button', class: 'link', text: open ? '收起' : '查看', onclick: () => toggleCrash(id) }),
          h('button', { type: 'button', class: 'link', text: '下载', onclick: () => downloadCrash(crash) }),
        ),
      );
      crashRows.append(h('div', null, row, body));
      if (open) fillCrash(crash, body);
    }
  }

  async function crashText(crash) {
    const r = await core.command('diag.crash', { id: crash.id }, 10000);
    if (r.ok && r.data && typeof r.data.text === 'string') return r.data.text;
    core.toast(r.ok ? '这块屏幕没有发来这条记录' : r.message || '没有拿到这条记录');
    return null;
  }

  async function fillCrash(crash, body) {
    body.textContent = '';
    body.append(h('p', { class: 'loading', text: '正在取这条记录…' }));
    const text = await crashText(crash);
    body.textContent = '';
    if (text == null) return;
    body.append(
      h('pre', { class: 'pre', text }),
      h(
        'div',
        { class: 'detail-actions' },
        h('button', { type: 'button', class: 'btn', text: '复制这一条', onclick: async () => core.toast((await core.copy(text)) ? '已复制这一条' : '这个浏览器不让网页复制') }),
        h('button', { type: 'button', class: 'btn', text: '下载这一条', onclick: () => core.download(crashFileName(crash), text) }),
      ),
    );
  }

  function toggleCrash(id) {
    expanded = expanded === id ? null : id;
    renderCrashes();
  }

  const crashFileName = (crash) => 'yingzhou-崩溃-' + fmt.dateTag(dateOf(crash.time) || new Date()) + '.txt';

  async function downloadCrash(crash) {
    const text = await crashText(crash);
    if (text != null) core.download(crashFileName(crash), text);
  }

  // ---- the log ----

  function entryTime(entry, ms) {
    const date = dateOf(entry.time);
    if (!date) return '';
    const base = pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
    return ms ? base + '.' + pad(date.getMilliseconds(), 3) : base;
  }

  function matches(entry) {
    if (level !== 'all' && entry._level !== level) return false;
    if (!query) return true;
    return [entry.module, entry.message, entry.detail].some((v) => v != null && String(v).toLowerCase().includes(query));
  }

  function setLevel(name) {
    level = name;
    renderLog();
  }

  function setFollow(on) {
    follow = on;
    followButton.setAttribute('aria-pressed', on ? 'true' : 'false');
    if (on) {
      poll();
      if (core.wide()) list.scrollTop = list.scrollHeight;
    } else {
      clearTimeout(timer);
    }
  }

  function take(items) {
    let added = 0;
    for (const raw of items) {
      if (!raw || typeof raw !== 'object') continue;
      const key = raw.seq != null ? 's' + raw.seq : JSON.stringify(raw);
      if (seen.has(key)) continue;
      seen.add(key);
      raw._level = levelOf(raw.level);
      entries.push(raw);
      added++;
    }
    if (entries.length > KEEP) {
      const drop = entries.splice(0, entries.length - KEEP);
      for (const e of drop) seen.delete(e.seq != null ? 's' + e.seq : JSON.stringify(e));
    }
    return added;
  }

  /** The log from the start (the screen keeps its last few hundred lines), a page at a time; then only what is new. */
  async function loadLog(first) {
    if (loading || support !== 'yes') return;
    loading = true;
    try {
      for (let pages = 0; pages < (first ? 6 : 2); pages++) {
        const args = next != null ? { after: next, limit: PAGE } : { limit: PAGE };
        const r = await core.command('diag.log', args, 8000);
        if (!r.ok || !r.data || !Array.isArray(r.data.entries)) break;
        const items = r.data.entries;
        take(items);
        if (r.data.next != null) next = r.data.next;
        else if (items.length && items[items.length - 1].seq != null) next = items[items.length - 1].seq;
        // `more`: the screen has more after these; an older one does not say, then a short page is the end.
        if (typeof r.data.more === 'boolean' ? !r.data.more : items.length < PAGE) break;
      }
    } finally {
      loading = false;
    }
    renderLog();
  }

  function poll() {
    clearTimeout(timer);
    if (!visible || !follow) return;
    timer = setTimeout(async () => {
      if (visible && follow && !document.hidden && core.connected()) await loadLog(false);
      poll();
    }, POLL_MS);
  }

  function renderLog() {
    const counts = { all: entries.length, info: 0, warn: 0, error: 0 };
    for (const e of entries) counts[e._level]++;
    for (const name of Object.keys(chips)) {
      chips[name].count.textContent = String(counts[name]);
      chips[name].classList.toggle('on', level === name);
      chips[name].setAttribute('aria-pressed', level === name ? 'true' : 'false');
    }
    const wide = core.wide();
    const stick = wide && (follow || list.scrollHeight - list.scrollTop - list.clientHeight < 40);
    list.textContent = '';
    list.append(h('div', { class: 'lrow head-row', 'aria-hidden': 'true' }, h('span', { text: '时间' }), h('span', { text: '级别' }), h('span', { text: '模块' }), h('span', { text: '内容' })));
    let shown = entries.filter(matches);
    // Oldest first on a wide window (it reads like a log, the newest at the bottom); newest first on a phone.
    if (!wide) shown = shown.slice().reverse();
    if (!shown.length) {
      list.append(h('div', { class: 'rowline' }, h('span', { class: 'rowline-sub', text: entries.length ? '没有符合条件的记录。' : '还没有日志。' })));
    }
    for (const entry of shown) {
      list.append(
        h(
          'button',
          {
            type: 'button',
            role: 'listitem',
            class: 'lrow ' + entry._level + (entry === selected ? ' on' : ''),
            onclick: () => select(entry),
          },
          h('span', { class: 't', text: entryTime(entry, wide) }),
          h('span', { class: 'lv', text: LEVEL_NAMES[entry._level] }),
          h('span', { class: 'mod', text: entry.module == null ? '' : String(entry.module) }),
          h('span', { class: 'msg', text: entry.message == null ? '' : String(entry.message) }),
        ),
      );
    }
    if (stick) list.scrollTop = list.scrollHeight;
    renderDetail();
  }

  function select(entry) {
    selected = selected === entry ? null : entry;
    renderLog();
    if (selected && !core.wide()) detail.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  }

  function entryText(entry) {
    return [entryTime(entry, true) + ' [' + LEVEL_NAMES[entry._level] + '] ' + (entry.module || ''), String(entry.message || ''), entry.detail ? String(entry.detail) : '']
      .filter(Boolean)
      .join('\n');
  }

  function renderDetail() {
    detail.textContent = '';
    if (!selected) {
      detail.append(h('p', { class: 'note', text: '点一条日志，在这里看它的细节，可以单独复制或下载。' }));
      return;
    }
    const e = selected;
    const badge = e._level === 'error' ? 'badge danger' : e._level === 'warn' ? 'badge warn' : 'badge plain';
    detail.append(
      h('div', { class: 'card-head' }, h('span', { class: badge, text: LEVEL_NAMES[e._level] }), h('span', { class: 't', text: [entryTime(e, true), e.module].filter(Boolean).join(' · ') })),
      h('h3', { text: String(e.message || '（没有内容）') }),
      e.detail ? h('pre', { class: 'pre', text: String(e.detail) }) : h('p', { class: 'note', text: '这一条没有更多细节。' }),
      h(
        'div',
        { class: 'detail-actions' },
        h('button', { type: 'button', class: 'btn', text: '复制这一条', onclick: async () => core.toast((await core.copy(entryText(e))) ? '已复制这一条' : '这个浏览器不让网页复制') }),
        h('button', { type: 'button', class: 'btn', text: '只下载这一条', onclick: () => core.download('yingzhou-日志-' + fmt.dateTag() + '.txt', entryText(e)) }),
      ),
    );
  }

  // ---- the engine's output ----

  async function loadEngineLog() {
    engineText.textContent = '正在取…';
    const r = await core.command('diag.engineLog', { lines: 300 }, 10000);
    const data = r.ok && r.data ? r.data : null;
    if (data && data.title) engineTitle.textContent = String(data.title);
    if (data && data.hasEngineLog === false) engineText.textContent = '这块屏幕连的是别处的引擎，它的输出不在这台设备上。';
    else engineText.textContent = data && typeof data.text === 'string' ? data.text || '（是空的）' : r.message || '没有拿到引擎的输出。';
  }

  // ---- 下载全部, 生成反馈 ----

  /** The full report (diag.report), kept for a minute so that 生成反馈 can copy it in the same click. */
  async function fullReport(fresh) {
    if (!fresh && report.text && Date.now() - report.at < 60000) return report.text;
    const r = await core.command('diag.report', {}, 15000);
    if (r.ok && r.data && typeof r.data.text === 'string') {
      report = { text: r.data.text, at: Date.now() };
      return report.text;
    }
    core.toast(r.ok ? '这块屏幕没有发来诊断信息' : r.message || '没有拿到诊断信息');
    return null;
  }

  async function downloadAll() {
    const text = await fullReport(true);
    if (text != null) {
      core.download('yingzhou-诊断-' + fmt.dateTag() + '.txt', text);
      core.toast('已存成 yingzhou-诊断-' + fmt.dateTag() + '.txt');
    }
  }

  function issueUrl() {
    const app = (summary && summary.app) || {};
    const engine = (summary && summary.engine) || {};
    const screen = core.screen() || {};
    const form = app.form || screen.form || '';
    const params = new URLSearchParams();
    params.set('template', ISSUE_TEMPLATE);
    params.set('version', String(app.version || screen.version || ''));
    params.set('platform', [String(app.platform || fmt.platformLabel(screen.platform, '')), FORMS[form] || form].filter(Boolean).join(' · '));
    const kind = ENGINE_KINDS[String(engine.kind || '').toLowerCase()] || String(engine.kind || '');
    params.set('engine', [engine.version ? 'tvbox-engine ' + engine.version : '', kind].filter(Boolean).join(' · '));
    params.set('logs', '（全文已经复制到剪贴板：在这里粘贴，替换这一行；或者把下载的 yingzhou-诊断-' + fmt.dateTag() + '.txt 拖进来。）');
    return ISSUE_URL + '?' + params.toString();
  }

  /** Copies the report and opens the form; both need the click that asked for them, so the report is fetched first. */
  async function openIssue(text) {
    const copied = await core.copy(text);
    const tab = window.open(issueUrl(), '_blank', 'noopener');
    if (copied) core.toast('全文已复制。粘贴到「诊断信息」一栏，或把「下载全部」存的文件拖进去。', 6000);
    else core.toast('没能复制：先「下载全部」，再把文件拖进「诊断信息」一栏。', 6000);
    return tab;
  }

  async function feedback() {
    if (report.text && Date.now() - report.at < 60000) {
      openIssue(report.text);
      return;
    }
    const text = await fullReport(true);
    if (text == null) return;
    // The click that asked is spent by now: one more, so the browser lets the page copy and open the tab.
    const go = await core.confirm({
      title: '反馈内容准备好了',
      text: '点「打开 GitHub」：全文会复制到这台设备的剪贴板，在新问题页的「诊断信息」一栏粘贴。版本、系统和引擎已经填好。',
      ok: '打开 GitHub',
      cancel: '先不了',
    });
    if (go) openIssue(text);
  }

  // ---- the page's life ----

  function reset() {
    summary = null;
    support = 'unknown';
    entries = [];
    seen = new Set();
    next = null;
    selected = null;
    expanded = null;
    report = { text: '', at: 0 };
    engineDetails.open = false;
    renderLog();
  }

  async function refresh() {
    await loadSummary();
    if (support !== 'yes') return;
    await loadLog(entries.length === 0);
    if (core.wide()) list.scrollTop = list.scrollHeight;
    poll();
    // Ready for 生成反馈 in the same click.
    fullReport(false);
  }

  core.on('screen', () => {
    reset();
    if (visible) refresh();
  });
  core.on('connection', (up) => {
    if (visible && up) refresh();
  });
  core.on('layout', () => {
    if (visible) renderLog();
  });

  renderLog();

  return {
    show() {
      visible = true;
      refresh();
    },
    hide() {
      visible = false;
      clearTimeout(timer);
    },
  };
}
