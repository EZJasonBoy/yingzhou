// 订阅与站点 (docs/design/web-console.md): push a subscription to the TV by pasting its address, the saved
// subscriptions (switch, rename, delete, reload) and the sites of the one in use. All of it is the engine's REST API
// with this device's token: /subscriptions, /config, /config/reload, /sites.

const RUNTIMES = { cms: '采集', js: 'JS', jar: 'jar', py: 'Python', remote: '远程', unknown: '其他' };
const FIRST_SITES = 30;

export default function mount(root, core) {
  const { h, icon, fmt } = core;

  let subs = [];
  let config = null;
  let sites = [];
  let allSites = false;
  let query = '';
  let visible = false;
  let refreshTimer = 0;

  // ---- 把一个订阅推给电视 ----

  const reload = h('button', { type: 'button', class: 'btn', onclick: reloadConfig }, icon('refresh'), '重新加载订阅');
  const head = core.pageHead({ title: '订阅与站点', actions: [reload], keep: true });

  const url = h('input', { class: 'in', type: 'url', inputmode: 'url', placeholder: '粘贴 http:// 或 https:// 开头的地址', autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false', id: 'push-url' });
  const name = h('input', { class: 'in', type: 'text', placeholder: '比如：家里用的', id: 'push-name' });
  const pushButton = h('button', { type: 'submit', class: 'btn primary', text: '推送并切换' });
  const saveButton = h('button', { type: 'button', class: 'btn', text: '只保存，先不切换', onclick: () => push(false) });
  const form = h(
    'form',
    { class: 'card', autocomplete: 'off' },
    h('h2', { class: 'card-title', text: '把一个订阅推给电视' }),
    h(
      'div',
      { class: 'form-row' },
      h('label', { class: 'field grow', for: 'push-url' }, '订阅地址', url),
      h('label', { class: 'field narrow', for: 'push-name' }, '名字（可以不填）', name),
    ),
    h(
      'div',
      { class: 'actions' },
      pushButton,
      h('button', { type: 'button', class: 'btn', text: '从剪贴板粘贴', onclick: () => core.pasteInto(url) }),
      saveButton,
      h('span', { class: 'note', text: '不用遥控器一个字一个字按。切换以后，电视首页换成这个订阅的站点。' }),
    ),
  );
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    push(true);
  });

  async function push(activate) {
    pushButton.disabled = saveButton.disabled = true;
    const result = await core.pushSubscription(url.value, name.value.trim(), activate);
    pushButton.disabled = saveButton.disabled = false;
    core.toast(result.message, 4000);
    if (result.ok || result.sub) {
      url.value = '';
      name.value = '';
      await load();
    }
  }

  // ---- 已保存的订阅 ----

  const subCount = h('span', { class: 'count' });
  const subRows = h('div', { class: 'rows' });
  const subSection = h('section', { class: 'section' }, h('div', { class: 'section-head' }, h('h2', { class: 'card-title' }, '已保存的订阅', subCount)), subRows);

  function subMeta(sub, active) {
    if (active && config) {
      const parts = [];
      if (config.repos && config.repos.length) parts.push('多仓 · ' + config.repos.filter((r) => !r.group).length + ' 个仓库');
      parts.push((Number(config.sites) || 0) + ' 个站点');
      if (config.refreshing) parts.push('正在核对有没有更新');
      else if (config.fetchedAt) parts.push(fmt.ago(config.fetchedAt) + '更新');
      const line = h('span', { class: 'rowline-sub', text: parts.join(' · ') });
      if (!config.refreshError) return line;
      return [line, h('span', { class: 'warn-line' }, icon('info'), '上次加载失败，还在用之前存下的：' + String(config.refreshError))];
    }
    return h('span', { class: 'rowline-sub', text: sub.usedAt ? '上次用：' + fmt.ago(sub.usedAt) : '还没用过' });
  }

  function repoPicker() {
    const repos = (config && config.repos) || [];
    if (!repos.length) return null;
    const select = h('select', { class: 'in', 'aria-label': '用哪个仓库' });
    for (const repo of repos) {
      const label = '　'.repeat(Math.max(0, Number(repo.depth) || 0)) + String(repo.name || repo.url) + (repo.group ? '（一组）' : '');
      select.append(h('option', { value: String(repo.url), text: label, selected: repo.url === config.url }));
    }
    select.addEventListener('change', () => activate(config.subscriptionId, select.value));
    return h('label', { class: 'field' }, '用哪个仓库', select);
  }

  function renderSubs() {
    subCount.textContent = String(subs.length);
    subRows.textContent = '';
    if (!subs.length) {
      subRows.append(h('div', { class: 'rowline' }, h('span', { class: 'rowline-sub', text: '还没有订阅。在上面粘贴一个地址推给电视。' })));
      return;
    }
    const activeId = config && config.subscriptionId;
    // The one in use first, then the others as the engine lists them.
    const ordered = subs.filter((s) => s.id === activeId).concat(subs.filter((s) => s.id !== activeId));
    for (const sub of ordered) {
      const active = sub.id === activeId;
      const title = h('span', { class: 'rowline-title' }, fmt.subscriptionName(sub));
      if (active) title.append(h('span', { class: 'badge accent' }, icon('wave'), '正在用'));
      const main = h('div', { class: 'rowline-main' }, title, h('span', { class: 'u', title: String(sub.url || ''), text: fmt.shortUrl(sub.url) }), subMeta(sub, active), active ? repoPicker() : null);
      const links = h(
        'span',
        { class: 'rowline-actions' },
        active ? h('button', { type: 'button', class: 'link', text: '看站点', onclick: () => sitesSection.scrollIntoView({ behavior: 'smooth' }) }) : null,
        h('button', { type: 'button', class: 'link', text: '改名', onclick: () => rename(sub) }),
        h('button', { type: 'button', class: 'link danger', text: '删除', onclick: () => remove(sub, active) }),
      );
      subRows.append(h('div', { class: 'rowline' }, main, active ? null : h('button', { type: 'button', class: 'btn small', text: '切换到它', onclick: () => activate(sub.id) }), links));
    }
  }

  async function activate(id, repo) {
    core.toast('正在加载…', 8000);
    const res = await core.api('POST', 'subscriptions/' + encodeURIComponent(id) + '/activate', repo ? { repo } : undefined);
    if (res.status === 200 && res.data) {
      const sub = subs.find((s) => s.id === id);
      core.toast('已切换到「' + fmt.subscriptionName(sub) + '」，' + (Number(res.data.sites) || 0) + ' 个站点。');
    } else {
      core.toast(core.explain(res, '这个订阅没有加载出来，还在用原来的。'), 4000);
    }
    await load();
  }

  async function rename(sub) {
    const value = await core.ask({
      title: '给订阅改个名字',
      text: '空着就用地址当名字。',
      fields: [{ label: '名字', value: sub.name && sub.name !== sub.url ? sub.name : '', placeholder: fmt.hostOf(sub.url) || '比如：家里用的' }],
      ok: '改名',
    });
    if (value == null) return;
    const res = await core.api('PUT', 'subscriptions/' + encodeURIComponent(sub.id), { name: value.trim() });
    if (res.status === 200) core.toast('已改名');
    else core.toast(core.explain(res, '没有改成。'));
    await load();
  }

  async function remove(sub, active) {
    const yes = await core.confirm({
      title: '删除「' + fmt.subscriptionName(sub) + '」？',
      text: active ? '这是正在用的订阅。删掉以后电视上就没有站点了，要再选一个订阅。' : '它会从这台映舟上删掉，以后要用得重新添加。',
      ok: '删除订阅',
      cancel: '保留',
      danger: true,
    });
    if (!yes) return;
    const res = await core.api('DELETE', 'subscriptions/' + encodeURIComponent(sub.id));
    if (res.status === 204 || res.status === 200) core.toast('已删除「' + fmt.subscriptionName(sub) + '」');
    else core.toast(core.explain(res, '没有删掉。'));
    await load();
  }

  async function reloadConfig() {
    reload.disabled = true;
    const res = await core.api('POST', 'config/reload');
    reload.disabled = false;
    if (res.status === 200 && res.data) core.toast('已重新加载，' + (Number(res.data.sites) || 0) + ' 个站点。');
    else core.toast(res.status === 0 ? core.explain(res, '') : '没有下载下来，还在用原来的。' + (/[一-鿿]/.test(res.message) ? res.message : ''), 4000);
    await load();
  }

  // ---- 站点 ----

  const sitesTitle = h('h2', { class: 'card-title', text: '站点' });
  const sitesMeta = h('span', { class: 'note' });
  const siteSearch = h('input', { type: 'search', placeholder: '按名字找', 'aria-label': '按名字找站点' });
  siteSearch.addEventListener('input', () => {
    query = siteSearch.value.trim().toLowerCase();
    renderSites();
  });
  const siteRows = h('div', { class: 'rows plain' });
  const sitesSection = h(
    'section',
    { class: 'section' },
    h('div', { class: 'section-head' }, sitesTitle, sitesMeta, h('label', { class: 'search' }, icon('search'), siteSearch)),
    siteRows,
  );

  function siteNote(site) {
    return [
      site.runtime === 'py' ? '要 Python 运行环境' : '',
      site.changeable === false ? '不参与换源' : '',
      site.filterable ? '能筛选' : '',
    ]
      .filter(Boolean)
      .join(' · ');
  }

  function renderSites() {
    const active = config ? subs.find((s) => s.id === config.subscriptionId) : null;
    sitesTitle.textContent = active ? '站点 · ' + fmt.subscriptionName(active) : '站点';
    const searchable = sites.filter((s) => s.searchable).length;
    sitesMeta.textContent = sites.length ? sites.length + ' 个，能搜索的 ' + searchable + ' 个' : '';
    siteRows.textContent = '';
    if (!sites.length) {
      siteRows.append(h('div', { class: 'rowline' }, h('span', { class: 'rowline-sub', text: config ? '这个订阅里没有站点。' : '还没有加载订阅，所以没有站点。' })));
      return;
    }
    siteRows.append(h('div', { class: 'site head-row' }, h('span', { text: '名字' }), h('span', { text: '类型' }), h('span', { text: '能搜索' }), h('span', { text: '说明' })));
    const shown = sites.filter((s) => !query || String(s.name || s.key).toLowerCase().includes(query));
    const cut = allSites || query ? shown : shown.slice(0, FIRST_SITES);
    for (const site of cut) {
      siteRows.append(
        h(
          'div',
          { class: 'site' },
          h('span', { class: 'name', text: String(site.name || site.key) }),
          h('span', { class: 'tag', text: RUNTIMES[site.runtime] || String(site.runtime || '其他') }),
          h('span', { class: site.searchable ? 'yes' : 'no', text: site.searchable ? '能' : '不能' }),
          h('span', { class: 'what', text: siteNote(site) }),
        ),
      );
    }
    if (!shown.length) siteRows.append(h('div', { class: 'rowline' }, h('span', { class: 'rowline-sub', text: '没有叫这个名字的站点。' })));
    if (cut.length < shown.length) {
      siteRows.append(
        h('div', { class: 'more-row' }, '还有 ' + (shown.length - cut.length) + ' 个站点', h('button', { type: 'button', class: 'link', text: '全部展开', onclick: () => ((allSites = true), renderSites()) })),
      );
    }
  }

  // ---- loading ----

  const problem = h('div', { class: 'empty-note', hidden: true });
  core.append(root, [head, problem, form, subSection, sitesSection]);

  async function load() {
    const [s, c, st] = await Promise.all([core.api('GET', 'subscriptions'), core.api('GET', 'config'), core.api('GET', 'sites')]);
    if (s.status !== 200 || !Array.isArray(s.data)) {
      problem.textContent = '';
      problem.append(h('b', { text: '读不到订阅' }), core.explain(s, '映舟的引擎没有回答。'));
      problem.hidden = false;
    } else {
      problem.hidden = true;
      subs = s.data;
    }
    config = c.status === 200 && c.data && c.data.subscriptionId ? c.data : null;
    sites = st.status === 200 && Array.isArray(st.data) ? st.data : [];
    renderSubs();
    renderSites();
    // The copy kept from last time is being checked: ask again until it is done (the sites may change).
    clearTimeout(refreshTimer);
    if (config && config.refreshing && visible) refreshTimer = setTimeout(load, 1500);
  }

  return {
    show() {
      visible = true;
      load();
    },
    hide() {
      visible = false;
      clearTimeout(refreshTimer);
    },
  };
}
