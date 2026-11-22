// 设置 (docs/design/web-console.md): the few settings worth changing from a phone. The app's own (用法, what it opens
// on, line checks, danmaku, the on-screen clock) go to the screen as setting.get / setting.set over the control
// socket; the engine's (GitHub mirror, HTTP proxy, secure DNS) are its REST API. When 设置 is locked on the screen,
// the same 4-digit PIN is asked here first, and forgotten when the page is left.

/** The app's setting for danmaku being on when playing starts. */
const DANMAKU_KEY = 'danmaku.enabled';
/** The screen keeps booleans as the strings 'true' / 'false'. */
const BOOLEANS = ['play.probeOnDetail', DANMAKU_KEY];
const KEYS = ['ui.userMode', 'ui.startPage', 'play.probeOnDetail', 'player.osdClock', DANMAKU_KEY];

const MODES = [
  ['simple', '简单', '打开就看：上次没看完的、收藏和推荐。按钮少，线路坏了自动换。能做的事和另外两种一样，只是摆得靠后。'],
  ['standard', '标准', '全部功能：多个站点、搜索和筛选、下载、网盘、直播回看。'],
  ['developer', '开发者', '标准之上：播放统计、片源从哪来、日志，方便排查和调订阅。'],
];
const STARTS = [
  ['resume', '继续看'],
  ['home', '站点推荐'],
  ['library', '我的'],
];
const CLOCKS = [
  ['off', '关'],
  ['osd', '随屏显出现'],
  ['always', '一直显示'],
];
const SCOPES = [
  ['config', '订阅'],
  ['modules', '模块'],
  ['playback', '播放'],
];

const truthy = (v) => v === true || v === 'true' || v === 1 || v === '1';

export default function mount(root, core) {
  const { h, icon } = core;

  let values = {};
  let appState = 'unknown'; // 'yes', 'no' (an older screen), 'offline'
  let locked = false;
  let pin = '';
  let engine = null; // GET /settings
  let presets = [];
  let network = null;
  let visible = false;

  const head = core.pageHead({ title: '设置', sub: '' });

  // ---- the lock ----

  const lockText = h('span');
  const lockButton = h('button', { type: 'button', class: 'btn small', text: '输入密码', onclick: () => unlock() });
  const lockBar = h('div', { class: 'lock-bar', hidden: true }, icon('lock'), lockText, lockButton);

  function renderLock() {
    lockBar.hidden = !locked;
    lockBar.classList.toggle('open', !!pin);
    lockBar.replaceChild(icon(pin ? 'unlock' : 'lock'), lockBar.firstChild);
    lockText.textContent = pin
      ? '已经输过密码，可以改了。离开这一页就重新锁上。'
      : '电视上的「设置」上了锁。在这里改也要先输那 4 位密码；离开这一页就重新锁上。';
    lockButton.hidden = !!pin;
    root.classList.toggle('locked', locked && !pin);
  }

  /** Asks for the PIN and tries it by setting 用法 to what it already is: a wrong one is refused by the screen. */
  async function unlock() {
    const value = await core.ask({
      title: '输入设置密码',
      text: '和电视上「设置」的密码一样，4 位数字。',
      fields: [{ pin: true, label: '' }],
      ok: '解锁',
      check: async ([typed]) => {
        if (!/^\d{4}$/.test(typed)) return '密码是 4 位数字。';
        const r = await core.command('setting.set', { key: 'ui.userMode', value: values['ui.userMode'] || 'standard', pin: typed }, 8000);
        return r.ok ? '' : r.message || '密码不对。';
      },
    });
    if (value == null) return false;
    pin = value;
    renderLock();
    return true;
  }

  async function allowed() {
    if (!locked || pin) return true;
    return unlock();
  }

  // ---- the app's settings, on the screen ----

  async function setApp(key, value) {
    if (!(await allowed())) {
      renderApp();
      return;
    }
    const before = values[key];
    const sent = BOOLEANS.indexOf(key) >= 0 ? String(!!value) : value;
    values[key] = sent;
    renderApp();
    const r = await core.command('setting.set', pin ? { key, value: sent, pin } : { key, value: sent }, 8000);
    if (r.ok) {
      // The screen answers with its settings as they are now.
      if (r.data && r.data.values && typeof r.data.values === 'object') values = Object.assign({}, values, r.data.values);
      if (r.data && typeof r.data.locked === 'boolean') locked = r.data.locked;
      renderLock();
      renderApp();
      return;
    }
    values[key] = before;
    if (locked && /密码|pin/i.test(r.message)) {
      pin = '';
      renderLock();
    }
    renderApp();
    core.toast(r.message || '没有改成。', 3600);
  }

  function seg(label, options, current, pick, hiddenWhen) {
    const box = h('div', { class: 'seg', role: 'group', 'aria-label': label });
    for (const [value, text] of options) {
      if (hiddenWhen && hiddenWhen(value)) continue;
      const on = value === current;
      box.append(h('button', { type: 'button', class: on ? 'on' : '', 'aria-pressed': on ? 'true' : 'false', text, onclick: () => !on && pick(value) }));
    }
    return box;
  }

  /** A boolean setting; [fallback] when the screen did not send it (its own default). */
  const flag = (key, fallback) => (values[key] == null || values[key] === '' ? fallback : truthy(values[key]));

  function toggle(label, small, on, pick) {
    return h(
      'div',
      { class: 'opt' },
      h('span', null, label, small ? h('small', { text: small }) : null),
      h('button', { type: 'button', class: 'switch', role: 'switch', 'aria-checked': on ? 'true' : 'false', 'aria-label': label, onclick: () => pick(!on) }),
    );
  }

  const modeCard = h('section', { class: 'card settings-card' });
  const playCard = h('section', { class: 'card settings-card' });

  function renderApp() {
    modeCard.textContent = '';
    playCard.textContent = '';
    modeCard.append(h('h2', { class: 'card-title', text: '用法' }));
    playCard.append(h('h2', { class: 'card-title', text: '播放' }));
    if (appState !== 'yes') {
      const text =
        appState === 'offline'
          ? '还没有连上屏幕。连上以后，这里可以改它的用法和播放设置。'
          : appState === 'no'
            ? '这块屏幕上的映舟还不能从这里改这些设置。把它更新到新版本后就可以。'
            : '正在问屏幕…';
      modeCard.append(h('p', { class: 'note', text }));
      playCard.append(h('p', { class: 'note', text }));
      return;
    }
    const mode = MODES.find((m) => m[0] === values['ui.userMode']) || MODES[1];
    modeCard.append(
      seg('用法', MODES, mode[0], (v) => setApp('ui.userMode', v)),
      h('span', { class: 'lab', text: mode[2] }),
      h('span', { class: 'lab', text: '打开映舟时先显示' }),
      seg('打开映舟时先显示', STARTS, mode[0] === 'simple' && values['ui.startPage'] === 'library' ? 'resume' : values['ui.startPage'] || 'resume', (v) => setApp('ui.startPage', v), (v) => v === 'library' && mode[0] === 'simple'),
    );
    playCard.append(
      toggle('打开详情时先测线路', '知道哪条能播、哪条快，再开始播', flag('play.probeOnDetail', (core.screen() || {}).form !== 'phone'), (v) => setApp('play.probeOnDetail', v)),
      toggle('弹幕默认打开', '', flag(DANMAKU_KEY, true), (v) => setApp(DANMAKU_KEY, v)),
      h('span', { class: 'lab', text: '屏显时间' }),
      seg('屏显时间', CLOCKS, values['player.osdClock'] || 'osd', (v) => setApp('player.osdClock', v)),
    );
  }

  async function loadApp() {
    if (!core.connected()) {
      appState = 'offline';
      locked = false;
    } else {
      const r = await core.command('setting.get', { keys: KEYS }, 8000);
      if (r.ok && r.data && r.data.values && typeof r.data.values === 'object') {
        appState = 'yes';
        values = r.data.values;
        locked = !!r.data.locked;
        if (!locked) pin = '';
      } else {
        appState = r.offline ? 'offline' : 'no';
        locked = false;
      }
    }
    renderLock();
    renderApp();
  }

  // ---- the engine's network settings ----

  const netCard = h('section', { class: 'card settings-card' });

  async function putEngine(patch, what) {
    if (!(await allowed())) {
      renderNetwork();
      return;
    }
    const res = await core.api('PUT', 'settings', patch);
    if (res.status === 200 && res.data) {
      engine = res.data;
      core.toast('已改好' + (what ? '：' + what : ''));
    } else {
      core.toast(core.explain(res, '没有改成。'), 3600);
    }
    if (patch.doh !== undefined) {
      const n = await core.api('GET', 'network');
      if (n.status === 200) network = n.data;
    }
    renderNetwork();
  }

  function renderNetwork() {
    netCard.textContent = '';
    netCard.append(h('h2', { class: 'card-title', text: '网络' }));
    if (!engine) {
      netCard.append(h('p', { class: 'note', text: '读不到引擎的网络设置。' }));
      return;
    }
    // GitHub 镜像: none, one of the engine's presets, or the address set elsewhere.
    const mirror = h('select', { class: 'in', id: 'set-mirror' });
    mirror.append(h('option', { value: '', text: '不用镜像（直接连 GitHub）' }));
    const prefixes = presets.map((p) => String(p.prefix));
    for (const p of presets) mirror.append(h('option', { value: String(p.prefix), text: String(p.name) + '（' + (core.fmt.hostOf(p.prefix) || p.prefix) + '）' }));
    if (engine.githubProxyPrefix && prefixes.indexOf(engine.githubProxyPrefix) < 0) mirror.append(h('option', { value: engine.githubProxyPrefix, text: '自己填的：' + engine.githubProxyPrefix }));
    mirror.value = engine.githubProxy ? engine.githubProxyPrefix || '' : '';
    mirror.addEventListener('change', () =>
      putEngine(mirror.value ? { githubProxy: true, githubProxyPrefix: mirror.value } : { githubProxy: false }, mirror.value ? 'GitHub 镜像' : '不用 GitHub 镜像'),
    );

    const proxy = h('input', { class: 'in', id: 'set-proxy', type: 'text', value: engine.httpProxy || '', placeholder: '比如 192.168.1.2:7890，空着就是不用', autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false' });
    const saveProxy = () => {
      const value = proxy.value.trim();
      if (value !== (engine.httpProxy || '')) putEngine({ httpProxy: value }, value ? 'HTTP 代理' : '不用 HTTP 代理');
    };
    proxy.addEventListener('change', saveProxy);
    proxy.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        proxy.blur();
      }
    });
    const scopes = Array.isArray(engine.proxyScopes) ? engine.proxyScopes.map(String) : [];
    const tags = h('div', { class: 'tags' }, h('span', { class: 'lab', text: '代理用在' }));
    for (const [scope, text] of SCOPES) {
      const on = scopes.indexOf(scope) >= 0;
      tags.append(
        h('button', {
          type: 'button',
          class: 'tag-toggle',
          'aria-pressed': on ? 'true' : 'false',
          text,
          onclick: () => putEngine({ proxyScopes: on ? scopes.filter((s) => s !== scope) : scopes.concat(scope) }, '代理用在哪'),
        }),
      );
    }

    const dns = h('select', { class: 'in', id: 'set-dns' });
    dns.append(h('option', { value: '', text: '不用（系统 DNS）' }));
    const options = network && Array.isArray(network.dohOptions) ? network.dohOptions : [];
    for (const o of options) dns.append(h('option', { value: String(o.url), text: String(o.name || o.url) + (o.source === 'config' ? '（订阅里写的）' : '') }));
    if (engine.doh && !options.some((o) => o.url === engine.doh)) dns.append(h('option', { value: engine.doh, text: engine.doh }));
    dns.value = engine.doh || '';
    dns.addEventListener('change', () => putEngine({ doh: dns.value }, dns.value ? '安全 DNS' : '不用安全 DNS'));
    const status = network && typeof network.dohStatus === 'string' ? network.dohStatus : '';

    core.append(netCard, [
      h('label', { class: 'field', for: 'set-mirror' }, 'GitHub 镜像', mirror),
      h('label', { class: 'field', for: 'set-proxy' }, 'HTTP 代理', proxy),
      tags,
      h('label', { class: 'field', for: 'set-dns' }, '安全 DNS', dns),
      engine.doh && status.startsWith('failed') ? h('p', { class: 'warn-line' }, icon('info'), '上次没连上这个 DNS，已经改用系统 DNS 应答。') : null,
      h('p', { class: 'note-faint', text: '改了 GitHub 镜像，下次加载订阅时生效。这几项和电视上「设置 → 网络」里的是同一份。' }),
    ]);
  }

  async function loadNetwork() {
    const [s, g, n] = await Promise.all([core.api('GET', 'settings'), core.api('GET', 'github-proxy'), core.api('GET', 'network')]);
    engine = s.status === 200 && s.data ? s.data : null;
    presets = g.status === 200 && g.data && Array.isArray(g.data.presets) ? g.data.presets : [];
    network = n.status === 200 && n.data ? n.data : null;
    renderNetwork();
  }

  // ---- this TV and this device ----

  const tvCard = h('section', { class: 'card settings-card' });

  function renderTv() {
    const screen = core.screen() || {};
    tvCard.textContent = '';
    tvCard.append(
      h('h2', { class: 'card-title', text: '这台电视' }),
      h('span', { class: 'lab', text: '在局域网里叫什么' }),
      h('div', { class: 'opt' }, h('span', null, String(screen.name || '映舟'), h('small', { text: [core.fmt.platformLabel(screen.platform, screen.form), screen.version ? '映舟 ' + screen.version : ''].filter(Boolean).join(' · ') }))),
      h('p', { class: 'note-faint', text: '名字在电视上的映舟里改。配对过哪些设备、撤销配对，在电视上的「设置 → 局域网」里管。' }),
      h('div', { class: 'divider' }),
      h('span', { class: 'lab', text: '这台设备' }),
      h('div', { class: 'opt' }, h('span', null, core.thisDevice(), h('small', { text: '已配对，令牌存在这个浏览器里' })), h('button', { type: 'button', class: 'link danger', text: '取消配对', onclick: core.forget })),
    );
  }

  core.append(root, [head, lockBar, h('div', { class: 'grid2' }, modeCard, playCard, netCard, tvCard)]);

  function refreshHead() {
    const screen = core.screen() || {};
    head.setSub('这里改的是「' + (screen.name || '映舟') + '」上那台映舟。改了马上生效。');
  }

  core.on('screen', () => {
    pin = '';
    if (visible) {
      refreshHead();
      renderTv();
      loadApp();
    }
  });
  core.on('connection', (up) => {
    if (visible && up) loadApp();
  });

  renderApp();
  renderNetwork();

  return {
    show() {
      visible = true;
      refreshHead();
      renderTv();
      loadApp();
      loadNetwork();
    },
    hide() {
      visible = false;
      // 离开这一页就重新锁上.
      pin = '';
      renderLock();
    },
  };
}
