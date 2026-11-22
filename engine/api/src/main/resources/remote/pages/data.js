// 数据 (docs/design/web-console.md): a backup file out of the engine and back in (GET /api/v1/backup; POST
// /api/v1/backup?dryRun=1 says what an import would do, POST /api/v1/backup writes the parts that are ticked), and
// the watch history and favourites (/history, /favorites). The backup keeps subscription addresses as they are, so
// that it can restore them: the page says so.

const FORMAT = 'yingzhou-backup';
const VERSION = 1;
const FIRST_HISTORY = 8;
const FIRST_FAVORITES = 12;

/** Engine setting keys in a backup, in words; the ones not named here are listed as they are. */
const SETTING_NAMES = {
  githubProxy: 'GitHub 镜像',
  githubProxyPrefix: 'GitHub 镜像',
  httpProxy: 'HTTP 代理',
  proxyScopes: 'HTTP 代理',
  doh: '安全 DNS',
  streamCache: '播放缓存',
  streamCacheMaxMB: '播放缓存',
  danmakuConfigApi: '弹幕服务',
  danmakuApi: '弹幕服务',
};

/** A count in a dry-run summary: a number, or a list of what it counts. */
const count = (v) => (Array.isArray(v) ? v.length : Number(v) || 0);

export default function mount(root, core) {
  const { h, icon, fmt } = core;

  let history = [];
  let favorites = [];
  let siteNames = {};
  let allHistory = false;
  let allFavorites = false;
  let picked = null; // {name, size, backup, plan}

  const head = core.pageHead({ title: '数据' });

  // ---- 导出备份 ----

  const exportText = h('p', { text: '一个文件，装着这台映舟的订阅、引擎设置、观看记录和收藏。换电视、重装之前存一份。' });
  const exportButton = h('button', { type: 'button', class: 'btn primary', onclick: exportBackup }, icon('download'), '导出备份');
  const exportCard = h(
    'section',
    { class: 'card' },
    h('h2', { class: 'card-title', text: '导出备份' }),
    exportText,
    h('p', { class: 'warn-line' }, icon('info'), '文件里的订阅地址是原样的（不遮），不要发给不认识的人。'),
    h('div', { class: 'actions' }, exportButton),
  );

  async function exportBackup() {
    exportButton.disabled = true;
    const res = await core.api('GET', 'backup');
    exportButton.disabled = false;
    if (res.status === 404 && (!res.code || res.code === 'NOT_FOUND')) {
      core.toast('这台映舟的引擎还不能导出备份，先把它更新到新版本。', 4000);
      return;
    }
    if (res.status !== 200 || !res.data || res.data.format !== FORMAT) {
      core.toast(core.explain(res, '没有导出来。'), 4000);
      return;
    }
    const name = 'yingzhou-备份-' + fmt.dateTag() + '.json';
    core.download(name, JSON.stringify(res.data, null, 2), 'application/json;charset=utf-8');
    core.toast('已存成 ' + name);
  }

  // ---- 导入备份 ----

  const fileInput = h('input', { type: 'file', accept: '.json,application/json', class: 'file-input', tabindex: '-1', 'aria-hidden': 'true' });
  fileInput.addEventListener('change', () => {
    const file = fileInput.files && fileInput.files[0];
    fileInput.value = '';
    if (file) readFile(file);
  });
  const importBody = h('div', { class: 'section', 'aria-live': 'polite' });
  const importCard = h('section', { class: 'card' }, h('h2', { class: 'card-title', text: '导入备份' }), fileInput, importBody);

  const choose = (text, primary) => h('button', { type: 'button', class: 'btn' + (primary ? ' primary' : ''), onclick: () => fileInput.click() }, icon('upload'), text);

  function renderImport(message) {
    importBody.textContent = '';
    if (!picked) {
      core.append(importBody, [
        h('p', { class: 'note', text: '选一个从映舟导出的备份文件。导入之前先列出里面有什么，勾上的才导入，现有的不会被删掉。' }),
        message ? h('p', { class: message.ok ? 'ok-line' : 'danger-line' }, icon(message.ok ? 'check' : 'warn'), message.text) : null,
        h('div', { class: 'actions' }, choose('选择备份文件', true)),
      ]);
      return;
    }
    const from = picked.backup.from && picked.backup.from.name ? '来自「' + String(picked.backup.from.name) + '」' : '';
    const exported = Number(picked.backup.exportedAt) || Date.parse(picked.backup.exportedAt) || 0;
    const meta = [fmt.bytes(picked.size), from, exported ? fmt.when(exported, true) + ' 导出' : ''].filter(Boolean).join(' · ');
    importBody.append(
      h(
        'div',
        { class: 'file-row' },
        icon('file'),
        h('span', null, picked.name, ' ', h('span', { class: 'muted', text: '· ' + meta })),
        h('button', { type: 'button', class: 'link', text: '换一个文件', onclick: () => fileInput.click() }),
      ),
    );
    if (!picked.plan) {
      importBody.append(h('p', { class: 'loading', text: '正在看文件里有什么…' }));
      return;
    }
    const plan = picked.plan;
    const items = [];
    const item = (key, has, label, note, on) => {
      const box = h('input', { type: 'checkbox', checked: has && on, disabled: !has });
      box.addEventListener('change', updateApply);
      items.push({ key, box });
      importBody.append(h('label', { class: 'ck' }, box, h('span', null, label, note ? h('span', { class: 'muted', text: '（' + note + '）' }) : null)));
    };
    importBody.append(h('p', { class: 'note', text: '这个文件里有这些。勾上的才会导入，现有的不会被删掉。' }));

    const subAdd = count(plan.subscriptions && plan.subscriptions.add);
    const subSkip = count(plan.subscriptions && plan.subscriptions.skip);
    item('subscriptions', subAdd > 0, subAdd + subSkip + ' 个订阅', subSkip ? (subAdd ? '其中 ' + subSkip + ' 个这台映舟上已经有，跳过' : '这台映舟上都有了') : '', true);

    const hAdd = count(plan.history && plan.history.add);
    const hUpdate = count(plan.history && plan.history.update);
    const hKeep = count(plan.history && plan.history.keep);
    const hNote = hUpdate + hKeep > 0 ? '同一部片两边都有时，留看得靠后的那一边' : '';
    item('history', hAdd + hUpdate > 0, hAdd + hUpdate + hKeep + ' 条观看记录', hAdd + hUpdate === 0 && hKeep ? '这台映舟上的都更新，不用导入' : hNote, true);

    const fAdd = count(plan.favorites && plan.favorites.add);
    const fSkip = count(plan.favorites && plan.favorites.skip);
    item('favorites', fAdd > 0, fAdd + fSkip + ' 部收藏', fSkip ? (fAdd ? '其中 ' + fSkip + ' 部已经收藏了' : '都已经收藏了') : '', true);

    const keys = plan.settings && Array.isArray(plan.settings.keys) ? plan.settings.keys.map(String) : [];
    const names = [...new Set(keys.map((k) => SETTING_NAMES[k] || k))];
    item('settings', keys.length > 0, '引擎设置' + (names.length ? '：' + names.join('、') : ''), keys.length ? '会盖掉这台映舟现在的' : '文件里没有', false);

    const apply = h('button', { type: 'button', class: 'btn primary', onclick: () => applyImport(items, apply) });
    importBody.append(h('div', { class: 'actions' }, apply, h('button', { type: 'button', class: 'btn', text: '不导入了', onclick: () => ((picked = null), renderImport()) })));
    function updateApply() {
      const n = items.filter((i) => i.box.checked).length;
      apply.textContent = n ? '导入勾上的 ' + n + ' 项' : '先勾上要导入的';
      apply.disabled = n === 0;
    }
    updateApply();
  }

  async function readFile(file) {
    let backup = null;
    try {
      backup = JSON.parse(await file.text());
    } catch (_) {
      backup = null;
    }
    if (!backup || typeof backup !== 'object' || backup.format !== FORMAT) {
      picked = null;
      renderImport({ ok: false, text: '「' + file.name + '」不是映舟的备份文件。' });
      return;
    }
    if (Number(backup.version) > VERSION) {
      picked = null;
      renderImport({ ok: false, text: '这个备份来自更新版本的映舟，先把这台映舟更新一下再导入。' });
      return;
    }
    picked = { name: file.name, size: file.size, backup, plan: null };
    renderImport();
    const res = await core.api('POST', 'backup?dryRun=1', backup);
    if (!picked || picked.backup !== backup) return;
    if (res.status === 200 && res.data && typeof res.data === 'object') {
      picked.plan = res.data;
      renderImport();
    } else {
      picked = null;
      const old = res.status === 404 && (!res.code || res.code === 'NOT_FOUND');
      renderImport({ ok: false, text: old ? '这台映舟的引擎还不能导入备份，先把它更新到新版本。' : core.explain(res, '这个文件读不出来。') });
    }
  }

  async function applyImport(items, button) {
    const include = {};
    for (const i of items) include[i.key] = i.box.checked;
    button.disabled = true;
    const res = await core.api('POST', 'backup', { backup: picked.backup, include });
    if (res.status !== 200 || !res.data) {
      button.disabled = false;
      core.toast(core.explain(res, '没有导入成功，这台映舟上的数据没有变。'), 4000);
      return;
    }
    const done = res.data;
    const parts = [];
    if (include.subscriptions && count(done.subscriptions && done.subscriptions.add)) parts.push(count(done.subscriptions.add) + ' 个订阅');
    if (include.history && count(done.history && done.history.add) + count(done.history && done.history.update)) parts.push(count(done.history.add) + count(done.history.update) + ' 条观看记录');
    if (include.favorites && count(done.favorites && done.favorites.add)) parts.push(count(done.favorites.add) + ' 部收藏');
    if (include.settings && done.settings && Array.isArray(done.settings.keys) && done.settings.keys.length) parts.push('引擎设置');
    picked = null;
    renderImport({ ok: true, text: parts.length ? '导入好了：' + parts.join('、') + '。' : '导入好了，没有要改的。' });
    load();
  }

  // ---- 观看记录 ----

  const historyCount = h('span', { class: 'count' });
  const historyRows = h('div', { class: 'rows plain' });
  const clearLink = h('button', { type: 'button', class: 'link danger', text: '清空观看记录', onclick: clearHistory });
  const historySection = h(
    'section',
    { class: 'section' },
    h('div', { class: 'section-head' }, h('h2', { class: 'card-title' }, '观看记录', historyCount), h('span', { class: 'card-meta' }, clearLink)),
    historyRows,
  );

  function renderHistory() {
    historyCount.textContent = String(history.length);
    clearLink.hidden = history.length === 0;
    historyRows.textContent = '';
    if (!history.length) {
      historyRows.append(h('div', { class: 'rowline' }, h('span', { class: 'rowline-sub', text: '还没有观看记录。' })));
      return;
    }
    historyRows.append(
      h('div', { class: 'hist head-row' }, ['片名', '看到', '进度', '站点', '时间', ''].map((t) => h('span', { text: t }))),
    );
    const cut = allHistory ? history : history.slice(0, FIRST_HISTORY);
    for (const entry of cut) {
      const pos = Number(entry.positionMs) || 0;
      const dur = Number(entry.durationMs) || 0;
      const fill = h('span');
      fill.style.width = (dur > 0 ? Math.min(100, Math.max(2, (pos / dur) * 100)) : 0) + '%';
      historyRows.append(
        h(
          'div',
          { class: 'hist' },
          h('span', { class: 'name', text: String(entry.name || entry.vodId) }),
          h('span', { class: 'at', text: [entry.episodeName ? String(entry.episodeName) : '', pos > 0 ? fmt.time(pos) : ''].filter(Boolean).join(' · ') || '刚打开' }),
          h('span', { class: 'bar', role: 'img', 'aria-label': dur > 0 ? '看了 ' + Math.round((pos / dur) * 100) + '%' : '进度不知道' }, fill),
          h('span', { class: 'site-name', text: siteNames[entry.site] || String(entry.site || '') }),
          h('span', { class: 'when', text: fmt.when(Number(entry.updatedAt) || 0, false) }),
          h('button', { type: 'button', class: 'icon-btn', 'aria-label': '删掉「' + String(entry.name || '') + '」这一条', onclick: () => removeHistory(entry) }, icon('cross')),
        ),
      );
    }
    if (cut.length < history.length) {
      historyRows.append(
        h('div', { class: 'more-row' }, '还有 ' + (history.length - cut.length) + ' 条', h('button', { type: 'button', class: 'link', text: '全部展开', onclick: () => ((allHistory = true), renderHistory()) })),
      );
    }
  }

  async function removeHistory(entry) {
    const res = await core.api('DELETE', 'history/' + encodeURIComponent(entry.site) + '/' + encodeURIComponent(entry.vodId));
    if (res.status === 204 || res.status === 200) {
      history = history.filter((e) => e !== entry);
      renderHistory();
      core.toast('已删掉「' + String(entry.name || '') + '」的观看记录');
    } else {
      core.toast(core.explain(res, '没有删掉。'));
    }
  }

  async function clearHistory() {
    const yes = await core.confirm({
      title: '清空观看记录？',
      text: '这台映舟上的 ' + history.length + ' 条观看记录都会删掉，「继续看」也会空。已经导出的备份文件不受影响。',
      ok: '清空观看记录',
      cancel: '保留',
      danger: true,
    });
    if (!yes) return;
    const res = await core.api('DELETE', 'history');
    if (res.status === 204 || res.status === 200) core.toast('观看记录已清空');
    else core.toast(core.explain(res, '没有清空。'));
    load();
  }

  // ---- 收藏 ----

  const favCount = h('span', { class: 'count' });
  const favBox = h('div', { class: 'favs' });
  const favSection = h('section', { class: 'section' }, h('h2', { class: 'card-title' }, '收藏', favCount), favBox);

  function renderFavorites() {
    favCount.textContent = String(favorites.length);
    favBox.textContent = '';
    if (!favorites.length) {
      favBox.append(h('p', { class: 'note', text: '还没有收藏。' }));
      return;
    }
    const cut = allFavorites ? favorites : favorites.slice(0, FIRST_FAVORITES);
    for (const fav of cut) {
      // Posters come from the sites: the page loads nothing from other hosts, so each is its title on the poster colour.
      favBox.append(
        h(
          'div',
          { class: 'fav', title: String(fav.name || '') },
          h('div', { class: 'fav-art', 'aria-hidden': 'true', text: String(fav.name || '') }),
          h('span', { text: String(fav.name || fav.vodId) }),
          h('small', { text: [siteNames[fav.site] || fav.site, fav.remarks].filter(Boolean).map(String).join(' · ') }),
        ),
      );
    }
    if (cut.length < favorites.length) {
      favBox.append(h('button', { type: 'button', class: 'link', text: '还有 ' + (favorites.length - cut.length) + ' 部，全部展开', onclick: () => ((allFavorites = true), renderFavorites()) }));
    }
  }

  // ---- loading ----

  const problem = h('div', { class: 'empty-note', hidden: true });
  core.append(root, [head, problem, h('div', { class: 'grid2' }, exportCard, importCard), historySection, favSection]);

  async function load() {
    const [subs, hist, favs, sites] = await Promise.all([
      core.api('GET', 'subscriptions'),
      core.api('GET', 'history?limit=5000'),
      core.api('GET', 'favorites'),
      core.api('GET', 'sites'),
    ]);
    if (hist.status !== 200 && favs.status !== 200) {
      problem.textContent = '';
      problem.append(h('b', { text: '读不到这台映舟的数据' }), core.explain(hist, '映舟的引擎没有回答。'));
      problem.hidden = false;
    } else {
      problem.hidden = true;
    }
    history = hist.status === 200 && Array.isArray(hist.data) ? hist.data : [];
    favorites = favs.status === 200 && Array.isArray(favs.data) ? favs.data : [];
    siteNames = {};
    if (sites.status === 200 && Array.isArray(sites.data)) for (const s of sites.data) siteNames[s.key] = String(s.name || s.key);
    const subCount = subs.status === 200 && Array.isArray(subs.data) ? subs.data.length : null;
    exportText.textContent =
      '一个文件，装着这台映舟的：' +
      [subCount != null ? '订阅 ' + subCount + ' 个' : '订阅', '引擎设置', '观看记录 ' + history.length + ' 条', '收藏 ' + favorites.length + ' 部'].join('、') +
      '。换电视、重装之前存一份。';
    renderHistory();
    renderFavorites();
  }

  renderImport();

  return {
    show() {
      load();
    },
    hide() {},
  };
}
