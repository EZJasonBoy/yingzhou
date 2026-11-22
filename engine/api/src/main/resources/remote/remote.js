// 映舟遥控 / 映舟控制台: the web remote and console (docs/protocol.md, "遥控"; docs/design/web-console.md). No
// dependencies, no build step.
//
// The page is served by the engine without a token. It pairs itself (POST /api/v1/pair with the code the screen
// shows, or the one in the address's #code=), keeps the token in localStorage, lists the screens and opens a
// WebSocket to one: the screen's state comes in, key presses and commands go out, and a command's result may carry
// data back. This file is the frame (pairing, connection, navigation), the remote and 正在播放; the other pages are
// modules in pages/ loaded when first opened (MODULE_PAGES), each given the `core` below.
//
// Everything a screen or the engine reports (titles, episode names, site names, log lines) comes from third parties,
// so it only ever reaches the page through textContent: nothing here or in the modules builds markup from strings.
(() => {
  'use strict';

  const PROTOCOL = 'yingzhou.remote.v1';
  const TOKEN_PROTOCOL = 'yingzhou.token.';
  /** The pages that live in their own module, pages/<name>.js (the engine serves exactly these). */
  const MODULE_PAGES = ['sources', 'data', 'logs', 'settings'];
  const PAGES = ['remote', 'play', 'more'].concat(MODULE_PAGES);
  /** The wide layout; the same condition as in remote.css (a phone on its side keeps the phone's layout). */
  const WIDE = window.matchMedia('(min-width: 900px) and (min-height: 500px)');
  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

  // ---- what the phone keeps ----

  const memory = {};
  const store = {
    get(key) {
      try {
        return localStorage.getItem('yz.remote.' + key) || '';
      } catch (_) {
        return memory[key] || '';
      }
    },
    set(key, value) {
      memory[key] = value;
      try {
        if (value) localStorage.setItem('yz.remote.' + key, value);
        else localStorage.removeItem('yz.remote.' + key);
      } catch (_) {
        // Private browsing: it lasts until the page is closed.
      }
    },
  };

  async function api(method, path, body) {
    const headers = {};
    const token = store.get('token');
    if (token) headers.Authorization = 'Bearer ' + token;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    let response;
    try {
      response = await fetch('/api/v1/' + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), cache: 'no-store' });
    } catch (_) {
      return { status: 0, data: null, code: 'UNREACHABLE', message: '' };
    }
    let data = null;
    try {
      data = await response.json();
    } catch (_) {
      // No body, or not JSON.
    }
    const error = (data && data.error) || {};
    return { status: response.status, data, code: error.code || '', message: error.message || '' };
  }

  /** A sentence about a failed request for the person holding the phone; the engine's own words when they are Chinese. */
  function explain(res, fallback) {
    if (!res || res.status === 0) return '连不上映舟。手机和它要在同一个 Wi-Fi 或路由器下。';
    if (res.status === 401) return '这台设备的配对已经失效，重新配对后再试。';
    if (res.status === 404 && (!res.code || res.code === 'NOT_FOUND') && !/[一-鿿]/.test(res.message)) return '这台映舟的引擎还不能做这件事，先把它更新到新版本。';
    if (/[一-鿿]/.test(res.message || '')) return res.message;
    return fallback;
  }

  // ---- building the page: elements and icons, never from markup strings ----

  const PROPERTIES = { value: 1, checked: 1, disabled: 1, hidden: 1, selected: 1, indeterminate: 1 };

  /** An element: `h('button', {class: 'btn', onclick: fn, text: '导出'}, child, …)`. Strings become text. */
  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    if (props) {
      for (const key of Object.keys(props)) {
        const value = props[key];
        if (value == null || value === false) continue;
        if (key === 'class') el.className = value;
        else if (key === 'text') el.textContent = String(value);
        else if (key.startsWith('on') && typeof value === 'function') el.addEventListener(key.slice(2), value);
        else if (PROPERTIES[key]) el[key] = value;
        else if (key !== 'style') el.setAttribute(key, value === true ? '' : String(value));
      }
    }
    append(el, children);
    return el;
  }

  function append(el, children) {
    for (const child of children) {
      if (child == null || child === false) continue;
      if (Array.isArray(child)) append(el, child);
      else el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return el;
  }

  const SVG = 'http://www.w3.org/2000/svg';
  const ICONS = {
    check: ['0 0 24 24', ['path', { d: 'M4 12.5l5.5 5.5L20 6.5' }]],
    cross: ['0 0 24 24', ['path', { d: 'M6 6l12 12M18 6L6 18' }]],
    warn: ['0 0 24 24', ['path', { d: 'M12 3.5l9.5 16.5h-19z' }], ['path', { d: 'M12 10v4.5M12 17v.4' }]],
    info: ['0 0 24 24', ['circle', { cx: 12, cy: 12, r: 9.5 }], ['path', { d: 'M12 7v6M12 16.5v.5' }]],
    shield: ['0 0 20 20', ['path', { d: 'M10 2.5L16 5v4.5c0 4-2.5 6.8-6 8-3.5-1.2-6-4-6-8V5z' }], ['path', { d: 'M7.3 9.8l2 2 3.5-3.8' }]],
    lock: ['0 0 24 24', ['rect', { x: 5, y: 11, width: 14, height: 9, rx: 2 }], ['path', { d: 'M8 11V8a4 4 0 018 0v3' }]],
    unlock: ['0 0 24 24', ['rect', { x: 5, y: 11, width: 14, height: 9, rx: 2 }], ['path', { d: 'M8 11V8a4 4 0 017.7-1.5' }]],
    download: ['0 0 20 20', ['path', { d: 'M3 12v4h14v-4M10 3v9M6.5 8.5L10 12l3.5-3.5' }]],
    feedback: ['0 0 20 20', ['path', { d: 'M6 3h6l3 3v11H6z' }], ['path', { d: 'M9 9v5M6.8 11.8L9 14l2.2-2.2' }]],
    refresh: ['0 0 24 24', ['path', { d: 'M20 12a8 8 0 11-2.4-5.7' }], ['path', { d: 'M20 3v5h-5' }]],
    search: ['0 0 24 24', ['circle', { cx: 11, cy: 11, r: 6.5 }], ['path', { d: 'M16 16l4 4' }]],
    back: ['0 0 22 22', ['path', { d: 'M14 3l-8 8 8 8' }]],
    chevron: ['0 0 12 20', ['path', { d: 'M3 3l7 7-7 7' }]],
    file: ['0 0 20 20', ['path', { d: 'M5 2.5h7L15.5 6v11.5H5z' }]],
    upload: ['0 0 20 20', ['path', { d: 'M3 12v4h14v-4M10 12V3M6.5 6.5L10 3l3.5 3.5' }]],
    hourglass: ['0 0 24 24', ['path', { d: 'M7 3h10M7 21h10M8 3c0 5 8 5 8 9s-8 4-8 9M16 3c0 5-8 5-8 9s8 4 8 9' }]],
    good: ['0 0 24 24', ['circle', { cx: 12, cy: 12, r: 10, class: 'solid' }], ['path', { d: 'M7 12.5l3.5 3.5L17.5 8.5', class: 'cut' }]],
    fine: ['0 0 24 24', ['circle', { cx: 12, cy: 12, r: 9.5 }], ['path', { d: 'M7.5 12.5l3 3 6-6.5' }]],
    wave: ['0 0 22 6', ['path', { d: 'M1 4q2.5-3 5 0', class: 'w1' }], ['path', { d: 'M6 4q2.5 3 5 0', class: 'w2' }], ['path', { d: 'M11 4q2.5-3 5 0 2.5 3 5 0', class: 'w3' }]],
    dash: ['0 0 24 24', ['path', { d: 'M7 12h10' }]],
  };

  function icon(name, cls) {
    const def = ICONS[name];
    const svg = document.createElementNS(SVG, 'svg');
    svg.setAttribute('viewBox', def[0]);
    svg.setAttribute('aria-hidden', 'true');
    if (cls || name === 'wave') svg.setAttribute('class', [name === 'wave' ? 'wave' : '', cls || ''].join(' ').trim());
    for (let i = 1; i < def.length; i++) {
      const [tag, attrs] = def[i];
      const shape = document.createElementNS(SVG, tag);
      for (const key of Object.keys(attrs)) shape.setAttribute(key, String(attrs[key]));
      svg.append(shape);
    }
    return svg;
  }

  // ---- words for numbers and times ----

  const pad2 = (n) => String(n).padStart(2, '0');

  /** 42:10, 1:31:20. */
  function time(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const hours = Math.floor(total / 3600);
    const m = pad2(Math.floor((total % 3600) / 60));
    const s = pad2(total % 60);
    return hours > 0 ? hours + ':' + m + ':' + s : m + ':' + s;
  }

  const clock = (d) => pad2(d.getHours()) + ':' + pad2(d.getMinutes());
  const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

  /** 今天 21:07, 昨天 22:40, 11-19, 2025-11-19. */
  function when(ms, withTime) {
    if (!ms) return '';
    const d = new Date(ms);
    const now = new Date();
    const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
    if (sameDay(d, now)) return '今天 ' + clock(d);
    if (sameDay(d, yesterday)) return '昨天 ' + clock(d);
    const day = pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
    const date = d.getFullYear() === now.getFullYear() ? day : d.getFullYear() + '-' + day;
    return withTime ? date + ' ' + clock(d) : date;
  }

  /** 刚刚, 5 分钟前, 2 小时前, 昨天, 11-18. */
  function ago(ms) {
    if (!ms) return '';
    const minutes = Math.floor((Date.now() - ms) / 60000);
    if (minutes < 1) return '刚刚';
    if (minutes < 60) return minutes + ' 分钟前';
    if (minutes < 24 * 60 && sameDay(new Date(ms), new Date())) return Math.floor(minutes / 60) + ' 小时前';
    const text = when(ms, false);
    return text.startsWith('昨天') ? '昨天' : text;
  }

  /** 2026-11-22: for file names. */
  function dateTag(d) {
    const day = d || new Date();
    return day.getFullYear() + '-' + pad2(day.getMonth() + 1) + '-' + pad2(day.getDate());
  }

  const bytes = (n) => (n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB');
  const speed = (bps) => (bps >= 1048576 ? (bps / 1048576).toFixed(1) + ' MB/s' : Math.round(bps / 1024) + ' KB/s');

  /** 1080p, 4K …: by the width, so a film cropped to 1920×800 still counts as 1080p (as the app says it). */
  function quality(width, height) {
    if (width >= 3840 || height >= 2160) return '4K';
    if (width >= 2560 || height >= 1440) return '2K';
    if (width >= 1920 || height >= 1080) return '1080p';
    if (width >= 1280 || height >= 720) return '720p';
    return height + 'p';
  }

  const PLATFORMS = { android: 'Android', windows: 'Windows', macos: 'macOS', linux: 'Linux', ios: 'iOS', ohos: '鸿蒙' };
  const FORMS = { tv: '电视', desktop: '桌面', phone: '手机', tablet: '平板' };

  /** Android TV, Windows · 电视模式, macOS. */
  function platformLabel(platform, form) {
    const raw = String(platform || '');
    const name = PLATFORMS[raw.toLowerCase()] || raw;
    if (form === 'tv') return raw.toLowerCase() === 'android' ? 'Android TV' : (name ? name + ' · 电视模式' : '电视');
    return name || FORMS[form] || '';
  }

  /** A subscription's name: what it was called, or its host when it never was (the name is then the address). */
  function subscriptionName(sub) {
    if (!sub) return '';
    if (sub.name && sub.name !== sub.url) return String(sub.name);
    return hostOf(sub.url) || String(sub.url || '');
  }

  function hostOf(url) {
    try {
      return new URL(String(url)).host;
    } catch (_) {
      return '';
    }
  }

  /** https://config.example.com/…/tv.json: enough to tell them apart without the whole (often secret) path. */
  function shortUrl(url) {
    const text = String(url || '');
    try {
      const u = new URL(text);
      const parts = u.pathname.split('/').filter(Boolean);
      if (parts.length <= 1) return u.origin + u.pathname;
      return u.origin + '/…/' + parts[parts.length - 1];
    } catch (_) {
      return text.length > 60 ? text.slice(0, 28) + '…' + text.slice(-24) : text;
    }
  }

  // ---- views, toasts and dialogs ----

  let view = 'boot';
  function show(name) {
    view = name;
    for (const v of ['boot', 'pair', 'screens', 'remote']) $('view-' + v).hidden = v !== name;
  }

  let toastTimer = 0;
  function toast(text, ms) {
    const el = $('toast');
    el.textContent = text;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (el.hidden = true), ms || 2600);
  }

  function buzz() {
    try {
      if (navigator.vibrate) navigator.vibrate(8);
    } catch (_) {
      // No haptics here (iOS).
    }
  }

  /**
   * A dialog: a title, a sentence, optional fields, two buttons that say what each does. Resolves to null when it is
   * dismissed, otherwise to the fields' values (an empty array without fields). [check] may refuse the values with a
   * sentence, which shows in the dialog.
   */
  function dialog({ title, text, fields, ok, cancel, danger, check }) {
    const box = $('dialog');
    if (!box.showModal) {
      // A browser without <dialog>: the plain ones.
      if (!fields || !fields.length) return Promise.resolve(window.confirm([title, text].filter(Boolean).join('\n\n')) ? [] : null);
      const value = window.prompt([title, text].filter(Boolean).join('\n\n'), fields[0].value || '');
      return Promise.resolve(value == null ? null : [value]);
    }
    return new Promise((resolve) => {
      const inputs = (fields || []).map((f) =>
        h('input', {
          class: 'in' + (f.pin ? ' pin' : ''),
          type: f.pin ? 'password' : f.type || 'text',
          value: f.value || '',
          placeholder: f.placeholder || '',
          inputmode: f.pin ? 'numeric' : null,
          maxlength: f.pin ? 4 : null,
          autocomplete: 'off',
          'aria-label': f.label || title,
        }),
      );
      const error = h('p', { class: 'error', role: 'alert' });
      const form = h(
        'form',
        { autocomplete: 'off' },
        h('h2', { text: title }),
        text ? h('p', { text }) : null,
        inputs.map((input, i) => (fields[i].label ? h('label', { class: 'field' }, fields[i].label, input) : input)),
        error,
        h(
          'div',
          { class: 'dialog-actions' },
          h('button', { type: 'button', class: 'btn', text: cancel || '取消', onclick: () => finish(null) }),
          h('button', { type: 'submit', class: 'btn ' + (danger ? 'danger' : 'primary'), text: ok || '好' }),
        ),
      );
      let done = false;
      function finish(result) {
        if (done) return;
        done = true;
        box.close();
        resolve(result);
      }
      form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const values = inputs.map((input) => input.value);
        if (check) {
          const refused = await check(values);
          if (refused) {
            error.textContent = refused;
            return;
          }
        }
        finish(values);
      });
      box.textContent = '';
      box.append(form);
      box.oncancel = (e) => {
        e.preventDefault();
        finish(null);
      };
      box.showModal();
      if (inputs[0]) {
        inputs[0].focus();
        inputs[0].select();
      }
    });
  }

  const confirm = (options) => dialog(options).then((r) => r !== null);
  const ask = (options) => dialog(options).then((r) => (r === null ? null : r[0]));

  /** Saves [text] as a file on this device: built here, it never goes through a server. */
  function download(name, text, type) {
    const blob = text instanceof Blob ? text : new Blob([text], { type: type || 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = h('a', { href: url, download: name, hidden: true });
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 30000);
  }

  /**
   * Puts [text] on this device's clipboard. Over plain http on the LAN browsers keep the clipboard API from pages, so
   * the old way first (it needs the click that called it, which an await would lose).
   */
  async function copy(text) {
    if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (_) {
        // Fall through to the old way.
      }
    }
    const area = h('textarea', { class: 'clip', 'aria-hidden': 'true', tabindex: '-1' });
    area.value = text;
    document.body.append(area);
    area.select();
    area.setSelectionRange(0, text.length);
    let ok = false;
    try {
      ok = document.execCommand('copy');
    } catch (_) {
      ok = false;
    }
    area.remove();
    return ok;
  }

  /** What is on the clipboard, where the browser lets a page read it (https or localhost); null otherwise. */
  async function paste() {
    if (!(window.isSecureContext && navigator.clipboard && navigator.clipboard.readText)) return null;
    try {
      return await navigator.clipboard.readText();
    } catch (_) {
      return null;
    }
  }

  // ---- this device ----

  function deviceLabel() {
    const ua = navigator.userAgent || '';
    if (/iPhone/.test(ua)) return 'iPhone';
    if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'iPad';
    if (/HarmonyOS/i.test(ua)) return '鸿蒙手机';
    if (/Android/.test(ua)) return /Mobile/.test(ua) ? '安卓手机' : '安卓平板';
    if (/Windows|Macintosh|Linux|CrOS/.test(ua)) return '电脑';
    return '浏览器';
  }

  /** The name this device paired under, as the screen lists it. */
  const deviceName = () => '遥控 · ' + deviceLabel();
  const thisDevice = () => store.get('deviceName') || deviceLabel();

  function renderDevice() {
    for (const el of document.querySelectorAll('.device-name')) el.textContent = thisDevice();
  }

  async function forget(askFirst) {
    if (askFirst) {
      const yes = await confirm({
        title: '取消这台设备的配对？',
        text: '这台' + thisDevice() + '会忘掉和映舟的配对，之后要在电视上看配对码重新配对。电视「设置 → 局域网」里的配对记录可以在电视上删除。',
        ok: '取消配对',
        cancel: '留着',
        danger: true,
      });
      if (!yes) return;
    }
    store.set('token', '');
    store.set('screen', '');
    manual = false;
    start('');
  }

  // ---- pages and the address ----

  let page = 'remote';
  let section = '';
  const scrolls = {};
  const modules = {};

  function hashParams() {
    return new URLSearchParams(location.hash.replace(/^#/, ''));
  }

  /** The page the address names (#page=logs, #page=playing, #tab=play); null when it names none. */
  function pageFromHash() {
    const params = hashParams();
    if (params.get('tab') === 'play') return 'play';
    const name = params.get('page');
    if (name === 'playing') return 'play';
    return PAGES.indexOf(name) >= 0 ? name : null;
  }

  const hashFor = (name) => '#page=' + (name === 'play' ? 'playing' : name);

  function go(name) {
    if (location.hash === hashFor(name)) setPage(name);
    else location.hash = hashFor(name);
  }

  function sectionFor(name) {
    if (name === 'remote' || name === 'play') return 'playing';
    if (name === 'more') return WIDE.matches ? 'playing' : 'more';
    return name;
  }

  function setPage(name) {
    page = PAGES.indexOf(name) >= 0 ? name : 'remote';
    if (page === 'remote' || page === 'play') store.set('tab', page);
    layout();
  }

  /** Shows the page (or, on a wide window, the remote and 正在播放 together) and marks it in the navigation. */
  function layout() {
    const wide = WIDE.matches;
    const next = sectionFor(page);
    const pages = $('pages');
    $('view-remote').dataset.page = page;
    if (next !== section) scrolls[section] = pages.scrollTop;
    for (const name of ['playing', 'more'].concat(MODULE_PAGES)) $('page-' + name).hidden = name !== next;
    $('remote-col').hidden = !wide && page !== 'remote';
    $('play-cols').hidden = !wide && page !== 'play';
    for (const el of document.querySelectorAll('[data-nav]')) {
      const on = el.dataset.nav === (next === 'playing' ? 'remote' : next);
      el.classList.toggle('on', on);
      if (on) el.setAttribute('aria-current', 'page');
      else el.removeAttribute('aria-current');
    }
    const tab = page === 'remote' || page === 'play' ? page : 'more';
    for (const el of document.querySelectorAll('[data-tab]')) {
      el.classList.toggle('on', el.dataset.tab === tab);
      if (el.dataset.tab === tab) el.setAttribute('aria-current', 'page');
      else el.removeAttribute('aria-current');
    }
    if (next !== section) {
      const previous = section;
      section = next;
      const old = modules[previous];
      if (old && old.instance && old.instance.hide) old.instance.hide();
      pages.scrollTop = scrolls[next] || 0;
      if (MODULE_PAGES.indexOf(next) >= 0) openModule(next);
      if (next === 'more') showMore();
    }
    if (next === 'playing') render();
  }

  WIDE.addEventListener('change', () => {
    layout();
    emit('layout', WIDE.matches);
  });
  window.addEventListener('hashchange', () => {
    const name = pageFromHash();
    if (name && name !== page) setPage(name);
  });

  /** Loads pages/<name>.js the first time the page is opened; it gets [core] and its own <section>. */
  function openModule(name) {
    let entry = modules[name];
    if (!entry) {
      const box = $('page-' + name);
      entry = modules[name] = { instance: null };
      box.textContent = '';
      box.append(h('p', { class: 'loading', text: '正在打开…' }));
      entry.ready = import('./pages/' + name + '.js').then(
        (mod) => {
          box.textContent = '';
          entry.instance = mod.default(box, core);
          return entry.instance;
        },
        () => {
          delete modules[name];
          box.textContent = '';
          box.append(
            h('div', { class: 'empty-note' }, h('b', { text: '这一页没有打开' }), '网络断了一下，或者这台映舟的版本和网页对不上。', ' '),
            h('button', { type: 'button', class: 'btn', text: '再试一次', onclick: () => openModule(name) }),
          );
          return null;
        },
      );
    }
    entry.ready.then((instance) => {
      if (instance && section === name && instance.show) instance.show();
    });
  }

  /** A page's header: on a phone with the way back to 更多, on a wide window the title and the page's buttons. */
  function pageHead({ title, sub, actions, keep }) {
    const subLine = h('span', { class: 'page-sub', text: sub || '', hidden: !sub });
    const head = h(
      'header',
      { class: 'page-head' },
      h('a', { class: 'back', href: '#page=more', 'aria-label': '返回「更多」' }, icon('back')),
      h('div', { class: 'page-titles' }, h('h1', { class: 'page-title', text: title }), subLine),
      // [keep]: the buttons stay in the header on a phone too (otherwise the page puts them at the bottom there).
      actions && actions.length ? h('div', { class: 'page-actions' + (keep ? '' : ' top-actions') }, actions) : null,
    );
    head.setSub = (text) => {
      subLine.textContent = text || '';
      subLine.hidden = !text;
    };
    return head;
  }

  // ---- events for the modules ----

  const listeners = {};
  function on(type, fn) {
    (listeners[type] = listeners[type] || new Set()).add(fn);
    return () => listeners[type].delete(fn);
  }
  function emit(type, value) {
    for (const fn of listeners[type] || []) {
      try {
        fn(value);
      } catch (e) {
        console.warn(e);
      }
    }
  }

  // ---- starting: is a token needed, is there one, which screen ----

  let current = null; // the screen being driven: {id, name, …}
  let manual = false; // the user asked for the list of screens
  let startSeq = 0;

  /** The pairing code of a QR code (`#code=123456`), taken out of the address so it is not used twice. */
  function takeCode() {
    const params = hashParams();
    const code = /^\d{6}$/.test(params.get('code') || '') ? params.get('code') : '';
    const named = pageFromHash();
    if (named === 'play') store.set('tab', 'play');
    if (location.hash) {
      try {
        history.replaceState(null, '', location.pathname + location.search + (named ? hashFor(named) : ''));
      } catch (_) {
        // Stays in the address; a used code is refused anyway.
      }
    }
    return code;
  }

  function boot(text, retry) {
    show('boot');
    $('boot-text').textContent = text;
    $('boot-retry').hidden = !retry;
  }

  async function start(code) {
    const seq = ++startSeq;
    stopScreensPoll();
    closeSocket();
    boot('正在连接…', false);
    const res = await api('GET', 'remote/screens');
    if (seq !== startSeq) return;
    if (res.status === 401) {
      // No token, or one that was revoked.
      store.set('token', '');
      if (code) {
        const failed = await pair(code);
        if (seq !== startSeq) return;
        if (!failed) return start('');
        return showPair(failed);
      }
      return showPair('');
    }
    if (res.status === 200 && Array.isArray(res.data)) return chooseScreen(res.data);
    if (res.status === 403) return boot(res.message || '这台映舟没有开启局域网共享。', true);
    if (res.status === 404) return boot('这台映舟的版本还没有遥控功能，请先更新。', true);
    boot('连不上映舟。手机和它要在同一个 Wi-Fi 或路由器下。', true);
    await sleep(3000);
    if (seq === startSeq && view === 'boot') start(code);
  }

  // ---- pairing ----

  async function pair(code) {
    const name = deviceName();
    const res = await api('POST', 'pair', { code, name });
    if (res.status === 200 && res.data && res.data.token) {
      store.set('token', res.data.token);
      store.set('deviceName', deviceLabel());
      return '';
    }
    return res.message || (res.status === 0 ? '连不上映舟。' : '配对没有成功。');
  }

  function showPair(error) {
    show('pair');
    $('pair-error').textContent = error;
    $('pair-code').value = '';
    // An engine without a screen prints a code when it is asked for one; this is that request.
    api('POST', 'pair', { code: '', name: deviceName() });
  }

  $('pair-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const code = $('pair-code').value.replace(/\D/g, '');
    if (code.length !== 6) {
      $('pair-error').textContent = '配对码是 6 位数字。';
      return;
    }
    $('pair-go').disabled = true;
    $('pair-error').textContent = '';
    const failed = await pair(code);
    $('pair-go').disabled = false;
    if (failed) $('pair-error').textContent = failed;
    else start('');
  });

  $('boot-retry').addEventListener('click', () => start(''));

  // ---- the list of screens ----

  let screensTimer = 0;
  function stopScreensPoll() {
    clearInterval(screensTimer);
    screensTimer = 0;
  }

  function chooseScreen(list) {
    const wanted = store.get('screen');
    const pick = list.find((s) => s.id === wanted) || (list.length === 1 ? list[0] : null);
    if (pick && !manual) return connect(pick);
    showScreens(list);
  }

  function showScreens(list) {
    show('screens');
    const box = $('screens-list');
    box.textContent = '';
    $('screens-title').textContent = list.length ? '选一块屏幕' : '没有可以遥控的屏幕';
    $('screens-hint').textContent = list.length
      ? ''
      : '在要遥控的那台映舟里打开「设置 → 局域网 → 允许手机遥控」。打开后这里会自己出现。';
    for (const screen of list) {
      box.append(
        h(
          'button',
          {
            type: 'button',
            class: 'screen-card',
            onclick: () => {
              manual = false;
              connect(screen);
            },
          },
          h('span', { class: 'dot' }),
          h('span', null, h('b', { text: screen.name || '映舟' }), h('small', { text: [platformLabel(screen.platform, screen.form), screen.title || ''].filter(Boolean).join(' · ') })),
        ),
      );
    }
    $('screens-forget').hidden = !store.get('token');
    if (!screensTimer) {
      screensTimer = setInterval(async () => {
        if (view !== 'screens' || document.hidden) return;
        const res = await api('GET', 'remote/screens');
        if (view !== 'screens') return;
        if (res.status === 200 && Array.isArray(res.data)) chooseScreen(res.data);
        else if (res.status === 401 || res.status === 403) start('');
      }, 2000);
    }
  }

  $('screens-forget').addEventListener('click', () => forget(false));
  for (const el of document.querySelectorAll('[data-forget]')) el.addEventListener('click', () => forget(true));

  async function pickScreen() {
    manual = true;
    closeSocket();
    const res = await api('GET', 'remote/screens');
    if (res.status === 200 && Array.isArray(res.data)) showScreens(res.data);
    else start('');
  }
  $('screen-button').addEventListener('click', pickScreen);
  $('side-screen').addEventListener('click', pickScreen);

  // ---- the connection to a screen ----

  let socket = null;
  let state = null; // the screen's last state
  let stateAt = 0; // when it came, on performance.now()
  let lastHeard = 0;
  let retries = 0;
  let reconnecting = false;
  let commandSeq = 0;
  const pending = new Map(); // command id → what to do with its result

  function setStatus(text, kind) {
    const el = $('screen-status');
    el.textContent = text;
    el.className = kind || '';
    const side = $('side-screen-status');
    const where = current ? platformLabel(current.platform, current.form) : '';
    side.textContent = kind === 'ok' ? ['已连接', where].filter(Boolean).join(' · ') : text;
    $('side-dot').classList.toggle('off', kind !== 'ok');
  }

  function setScreenName(name) {
    $('screen-name').textContent = name || '映舟';
    $('side-screen-name').textContent = name || '映舟';
  }

  function connect(screen) {
    stopScreensPoll();
    const changed = !current || current.id !== screen.id;
    current = screen;
    store.set('screen', screen.id);
    state = null;
    show('remote');
    renderDevice();
    setScreenName(screen.name);
    setStatus('正在连接…', '');
    layout();
    render();
    retries = 0;
    openSocket();
    if (changed) emit('screen', current);
  }

  function closeSocket() {
    const ws = socket;
    socket = null;
    if (ws) {
      try {
        ws.close();
      } catch (_) {
        // Already gone.
      }
    }
    failPending();
  }

  /** Commands still waiting when the connection ends are answered here: they will never be answered by the screen. */
  function failPending() {
    for (const [id, done] of pending) {
      pending.delete(id);
      done({ ok: false, offline: true, message: '和屏幕的连接断了' });
    }
  }

  function openSocket() {
    closeSocket();
    const token = store.get('token');
    const url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/api/v1/remote/control?screen=' + encodeURIComponent(current.id);
    let ws;
    try {
      // Browsers cannot put a header on a WebSocket: the token travels as a second subprotocol.
      ws = new WebSocket(url, token ? [PROTOCOL, TOKEN_PROTOCOL + token] : [PROTOCOL]);
    } catch (_) {
      reconnect();
      return;
    }
    socket = ws;
    ws.onopen = () => {
      if (socket !== ws) return;
      lastHeard = Date.now();
      retries = 0;
      setStatus('已连接', 'ok');
      emit('connection', true);
    };
    ws.onmessage = (e) => {
      if (socket !== ws) return;
      lastHeard = Date.now();
      let msg;
      try {
        msg = JSON.parse(e.data);
      } catch (_) {
        return;
      }
      handle(msg);
    };
    ws.onclose = () => {
      if (socket !== ws) return;
      socket = null;
      lost();
    };
  }

  function lost() {
    state = null;
    failPending();
    render();
    setStatus('连接断开，正在重连…', 'bad');
    emit('connection', false);
    reconnect();
  }

  /**
   * After the socket closed (or never opened): ask the engine over HTTP what is the matter, where a status code can
   * be read (a failed WebSocket says nothing), and open the socket again once the screen is on the list.
   */
  async function reconnect() {
    if (reconnecting) return;
    reconnecting = true;
    try {
      while (view === 'remote' && !socket && current) {
        await sleep(Math.min(5000, 300 * 2 ** retries));
        retries = Math.min(retries + 1, 5);
        if (view !== 'remote' || socket || !current) break;
        const res = await api('GET', 'remote/screens');
        if (view !== 'remote' || socket || !current) break;
        if (res.status === 200 && Array.isArray(res.data)) {
          const found = res.data.find((s) => s.id === current.id);
          if (found) {
            current = found;
            setScreenName(found.name);
            openSocket();
            break;
          }
          setStatus('屏幕不在线，等它回来…', 'bad');
          retries = Math.min(retries, 3);
        } else if (res.status === 401 || res.status === 403 || res.status === 404) {
          start('');
          break;
        } else {
          setStatus('连不上映舟，正在重试…', 'bad');
        }
      }
    } finally {
      reconnecting = false;
    }
  }

  function handle(msg) {
    switch (msg.type) {
      case 'screen':
        if (msg.screen) {
          current = Object.assign({}, current, msg.screen);
          setScreenName(current.name);
          if (socket) setStatus('已连接', 'ok');
          emit('screen', current);
        }
        break;
      case 'state':
        state = msg.state && typeof msg.state === 'object' ? msg.state : null;
        stateAt = performance.now();
        render();
        emit('state', state);
        break;
      case 'result': {
        const done = pending.get(String(msg.id));
        if (done) {
          pending.delete(String(msg.id));
          done(msg);
        } else if (msg.ok === false && msg.message) {
          toast(String(msg.message));
        }
        break;
      }
      default:
        break;
    }
  }

  function send(name, args) {
    if (!socket || socket.readyState !== 1) {
      toast('还没有连上屏幕');
      return false;
    }
    socket.send(JSON.stringify({ type: 'command', id: String(++commandSeq), name, args: args || {} }));
    return true;
  }

  /**
   * A command whose answer is wanted: resolves to {ok, message, data}. `data` is the result's object when the screen
   * sent one (an older screen or engine sends none: null). Never rejects: no connection, no answer in [timeoutMs] or
   * a refusal all come back as ok=false with a sentence.
   */
  function command(name, args, timeoutMs) {
    return new Promise((resolve) => {
      if (!socket || socket.readyState !== 1) {
        resolve({ ok: false, offline: true, message: '还没有连上屏幕', data: null });
        return;
      }
      const id = String(++commandSeq);
      const timer = setTimeout(() => {
        pending.delete(id);
        resolve({ ok: false, timeout: true, message: '屏幕没有回答', data: null });
      }, timeoutMs || 10000);
      pending.set(id, (msg) => {
        clearTimeout(timer);
        const data = msg.data && typeof msg.data === 'object' && !Array.isArray(msg.data) ? msg.data : null;
        resolve({ ok: msg.ok !== false, message: msg.message ? String(msg.message) : '', data, offline: !!msg.offline });
      });
      socket.send(JSON.stringify({ type: 'command', id, name, args: args || {} }));
    });
  }

  // A phone that sleeps or changes network leaves a socket that looks open: ping it, and start over when it is silent.
  setInterval(() => {
    const ws = socket;
    if (!ws || ws.readyState !== 1 || view !== 'remote') return;
    if (Date.now() - lastHeard > 25000) {
      socket = null;
      try {
        ws.close();
      } catch (_) {
        // Already gone.
      }
      lost();
    } else {
      ws.send('{"type":"ping"}');
    }
  }, 10000);

  document.addEventListener('visibilitychange', () => {
    if (document.hidden || view !== 'remote') return;
    retries = 0;
    if (!socket) reconnect();
    else if (socket.readyState === 1) socket.send('{"type":"ping"}');
  });

  // ---- keys ----

  /** A button that can be held: [down] at once, [repeat] while it is held, [up] when it is let go. */
  function hold(el, down, repeat, up) {
    let delay = 0;
    let timer = 0;
    let held = false;
    const end = () => {
      if (!held) return;
      held = false;
      clearTimeout(delay);
      clearInterval(timer);
      el.classList.remove('down');
      if (up) up();
    };
    el.addEventListener('pointerdown', (e) => {
      if (e.button) return;
      e.preventDefault();
      if (held) end();
      held = true;
      try {
        el.setPointerCapture(e.pointerId);
      } catch (_) {
        // Not capturable: the pointer leaving the button ends the hold below.
      }
      el.classList.add('down');
      buzz();
      down();
      if (repeat) delay = setTimeout(() => (timer = setInterval(repeat, 110)), 380);
    });
    for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) el.addEventListener(type, end);
    el.addEventListener('contextmenu', (e) => e.preventDefault());
    // A keyboard on the button itself (Tab to it, then Enter or Space).
    el.addEventListener('keydown', (e) => {
      if ((e.key === 'Enter' || e.key === ' ') && !e.repeat) {
        e.preventDefault();
        e.stopPropagation();
        down();
        if (up) up();
      }
    });
  }

  for (const el of document.querySelectorAll('[data-key]')) {
    const key = el.dataset.key;
    hold(
      el,
      () => send('key', { key, action: 'down' }),
      () => send('key', { key, action: 'repeat' }),
      () => send('key', { key, action: 'up' }),
    );
  }
  for (const el of document.querySelectorAll('[data-press]')) {
    hold(el, () => send('key', { key: el.dataset.press, action: 'press' }), null, null);
  }
  for (const el of document.querySelectorAll('[data-command]')) {
    hold(el, () => send(el.dataset.command, {}), null, null);
  }
  for (const el of document.querySelectorAll('[data-seek]')) {
    hold(el, () => send('seekBy', { delta: Number(el.dataset.seek) }), null, null);
  }
  for (const el of document.querySelectorAll('[data-repeat-command]')) {
    const act = () => send(el.dataset.repeatCommand, { delta: Number(el.dataset.delta) });
    hold(el, act, act, null);
  }

  $('mode-button').addEventListener('click', () => {
    buzz();
    send('uiMode', { mode: state && state.form === 'tv' ? 'auto' : 'tv' });
  });

  // The keyboard of a computer drives the screen on 遥控与播放: arrows, Enter for OK, Esc for back.
  const KEYS = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', Enter: 'ok', Escape: 'back' };
  const keysHeld = new Set();
  function flash(key, down) {
    const el = document.querySelector('.pad [data-key="' + key + '"]');
    if (el) el.classList.toggle('down', down);
  }
  document.addEventListener('keydown', (e) => {
    const key = KEYS[e.key];
    if (!key || view !== 'remote' || (page !== 'remote' && page !== 'play') || e.altKey || e.ctrlKey || e.metaKey) return;
    const target = e.target instanceof Element ? e.target : null;
    if (target && target.closest('input, select, textarea, dialog, [contenteditable]')) return;
    if (key === 'ok' && target && target.closest('button, a, summary, label')) return;
    e.preventDefault();
    if (key === 'back') {
      if (!e.repeat) send('key', { key, action: 'press' });
      return;
    }
    if (e.repeat && keysHeld.has(key)) {
      send('key', { key, action: 'repeat' });
      return;
    }
    keysHeld.add(key);
    flash(key, true);
    send('key', { key, action: 'down' });
  });
  document.addEventListener('keyup', (e) => {
    const key = KEYS[e.key];
    if (!key || !keysHeld.has(key)) return;
    keysHeld.delete(key);
    flash(key, false);
    if (socket) send('key', { key, action: 'up' });
  });
  window.addEventListener('blur', () => {
    for (const key of keysHeld) {
      flash(key, false);
      if (socket) send('key', { key, action: 'up' });
    }
    keysHeld.clear();
  });

  // ---- sliders ----

  function fill(input, buffered) {
    const max = Number(input.max) || 1;
    const at = Math.max(0, Math.min(100, (Number(input.value) / max) * 100));
    input.style.setProperty('--fill', at + '%');
    input.style.setProperty('--buf', Math.max(at, Math.min(100, buffered || 0)) + '%');
  }

  /** Where the film is now: the last position reported, moved on by the time since, while it plays. */
  function position() {
    const p = state && state.player;
    if (!p) return 0;
    let at = Number(p.position) || 0;
    if (!p.paused && !p.buffering && !p.error) at += (performance.now() - stateAt) * (Number(p.speed) || 1);
    const duration = Number(p.duration) || 0;
    return duration > 0 ? Math.min(at, duration) : at;
  }

  let dragging = null;
  const seekBars = [
    { input: $('now-seek'), pos: $('now-pos'), dur: $('now-dur') },
    { input: $('play-seek'), pos: $('play-pos'), dur: $('play-dur'), full: true },
  ];
  for (const bar of seekBars) {
    const input = bar.input;
    const begin = () => (dragging = input);
    input.addEventListener('pointerdown', begin);
    input.addEventListener('touchstart', begin, { passive: true });
    input.addEventListener('input', () => {
      dragging = input;
      bar.pos.textContent = time(Number(input.value) * 1000);
      fill(input);
    });
    // Once, when the bar is let go: one seek, not one per step of the finger.
    input.addEventListener('change', () => {
      const target = Number(input.value) * 1000;
      dragging = null;
      if (state && state.player) {
        state.player.position = target;
        stateAt = performance.now();
      }
      buzz();
      send('seek', { position: target });
      tick();
    });
    const end = () => setTimeout(() => (dragging === input ? (dragging = null) : 0), 300);
    input.addEventListener('pointerup', end);
    input.addEventListener('touchend', end);
  }

  function tick() {
    const p = state && state.player;
    if (!p) return;
    const duration = Number(p.duration) || 0;
    const at = position();
    const info = p.info && typeof p.info === 'object' ? p.info : null;
    const ahead = info && Number(info.bufferSeconds) > 0 ? Number(info.bufferSeconds) * 1000 : 0;
    for (const bar of seekBars) {
      const seconds = Math.max(1, Math.floor(duration / 1000));
      if (bar.input.max !== String(seconds)) bar.input.max = String(seconds);
      bar.input.disabled = !(duration > 0) || p.seekable === false;
      let dur = duration > 0 ? time(duration) : '直播';
      // 54:30 · 约 21:19 看完, while it plays at a known speed.
      if (bar.full && duration > 0 && !p.paused && !p.error && p.kind !== 'live') {
        const left = (duration - at) / (Number(p.speed) || 1);
        if (left > 60000) dur += ' · 约 ' + clock(new Date(Date.now() + left)) + ' 看完';
      }
      if (bar.dur.textContent !== dur) bar.dur.textContent = dur;
      if (dragging !== bar.input) {
        bar.input.value = String(Math.floor(at / 1000));
        bar.pos.textContent = time(at);
        fill(bar.input, duration > 0 ? ((at + ahead) / duration) * 100 : 0);
      }
    }
  }
  setInterval(tick, 400);

  let volumeHeld = false;
  let volumeTimer = 0;
  const volume = $('volume');
  volume.addEventListener('input', () => {
    volumeHeld = true;
    fill(volume);
    $('volume-value').textContent = volume.value;
    if (volumeTimer) return;
    volumeTimer = setTimeout(() => {
      volumeTimer = 0;
      send('volume', { value: Number(volume.value) });
    }, 80);
  });
  volume.addEventListener('change', () => {
    send('volume', { value: Number(volume.value) });
    setTimeout(() => (volumeHeld = false), 600);
  });

  // ---- what is typed for the screen's text field: the phone's floating bar, or the field in the wide remote ----

  const textBar = $('text-bar');
  const textInputs = [$('text-input'), $('text-field')];
  let typing = null; // the input being typed in, while composing or just after
  let typedAt = 0;
  let textTimer = 0;
  let textOpen = false;

  function sendText(input) {
    typedAt = Date.now();
    typing = input;
    for (const other of textInputs) if (other !== input) other.value = input.value;
    if (textTimer) return;
    textTimer = setTimeout(() => {
      textTimer = 0;
      send('text', { value: input.value });
    }, 60);
  }
  function submitText(input) {
    clearTimeout(textTimer);
    textTimer = 0;
    send('text', { value: input.value });
    send('submit', {});
    input.blur();
  }
  for (const input of textInputs) {
    input.addEventListener('compositionstart', () => (input.composing = true));
    input.addEventListener('compositionend', () => {
      input.composing = false;
      sendText(input);
    });
    input.addEventListener('input', () => {
      // While an input method is composing (pinyin), the field on the screen waits for the finished text.
      if (!input.composing) sendText(input);
    });
  }
  textBar.addEventListener('submit', (e) => {
    e.preventDefault();
    submitText($('text-input'));
  });
  $('text-form').addEventListener('submit', (e) => {
    e.preventDefault();
    submitText($('text-field'));
  });

  function renderText(text) {
    const field = $('text-field');
    if (!text) {
      if (textOpen) {
        textOpen = false;
        textBar.hidden = true;
        for (const input of textInputs) input.blur();
      }
      field.disabled = true;
      field.value = '';
      field.type = 'text';
      field.placeholder = '现在电视上没有输入框';
      return;
    }
    const value = typeof text.value === 'string' ? text.value : '';
    const hint = (text.hint ? String(text.hint) + '：' : '') + '在这里输入，屏幕上同步';
    if (!textOpen) {
      textOpen = true;
      textBar.hidden = false;
      for (const input of textInputs) {
        input.type = text.secret ? 'password' : 'text';
        input.placeholder = hint;
        input.value = value;
      }
      field.disabled = false;
    } else {
      const busy = typing && (typing.composing || Date.now() - typedAt <= 1200);
      // Changed on the screen (its own keyboard, or cleared): follow, unless this device is the one typing.
      if (!busy) for (const input of textInputs) if (input.value !== value) input.value = value;
    }
  }

  // ---- drawing the state ----

  function setText(el, text) {
    const next = text == null ? '' : String(text);
    if (el.textContent !== next) el.textContent = next;
  }

  /**
   * A list of choices, built again only when the choices change (a long episode list is not rebuilt for every state);
   * otherwise only the chosen one is marked. [build] makes one button.
   */
  function choices(box, items, chosen, build, pick, extra) {
    const list = Array.isArray(items) ? items : [];
    const signature = JSON.stringify([list, extra || null]);
    let scroll = false;
    if (box._signature !== signature) {
      box._signature = signature;
      box.textContent = '';
      list.forEach((item, index) => {
        const button = build(item, index);
        button.addEventListener('click', () => {
          buzz();
          pick(item, index);
        });
        box.append(button);
      });
      box._chosen = -2;
      scroll = true;
    }
    if (box._chosen !== chosen) {
      box._chosen = chosen;
      Array.prototype.forEach.call(box.children, (el, index) => {
        el.classList.toggle('on', index === chosen);
        if (index === chosen) el.setAttribute('aria-current', 'true');
        else el.removeAttribute('aria-current');
      });
      scroll = true;
    }
    // Keeps the chosen one in sight in a list that scrolls (the episodes).
    const on = box.children[chosen];
    if (scroll && on && box.scrollHeight > box.clientHeight) box.scrollTop = on.offsetTop - box.offsetTop - box.clientHeight / 2 + on.offsetHeight / 2;
    return list.length;
  }

  const speedLabel = (v) => (Number.isInteger(Number(v)) ? Number(v).toFixed(1) : String(v)) + '×';
  const EPISODE_NUMBER = /^\s*(?:第\s*)?0*(\d{1,4})\s*(?:集|话|話|期|回)?\s*$/;

  /** A select over a screen's tracks (字幕, 音轨), rebuilt only when they change. */
  function tracks(pickEl, select, list, chosenId, command) {
    pickEl.hidden = list.length === 0;
    const signature = JSON.stringify(list);
    if (select._signature !== signature) {
      select._signature = signature;
      select.textContent = '';
      for (const t of list) select.append(h('option', { value: String(t.id), text: String(t.name || t.id) }));
      select.onchange = () => {
        buzz();
        send(command, { id: select.value });
      };
    }
    if (document.activeElement !== select && chosenId != null) select.value = String(chosenId);
  }

  function render() {
    const s = state || {};
    const p = s.player && typeof s.player === 'object' ? s.player : null;
    const body = document.body;
    body.classList.toggle('playing', !!p && !p.paused);
    body.classList.toggle('muted', !!p && (!!p.muted || Number(p.volume) === 0));

    const mode = $('mode-button');
    mode.hidden = !s.canTv;
    setText(mode, s.form === 'tv' ? '电视模式：开' : '电视模式：关');
    mode.classList.toggle('on', s.form === 'tv');
    if (state && socket) {
      $('screen-status').textContent = s.title ? String(s.title) : '已连接';
      $('screen-status').className = 'ok';
    }

    renderText(s.text && typeof s.text === 'object' ? s.text : null);

    // 正在播放 above the phone's D-pad keeps its place and its size whether something plays or not.
    $('now').classList.toggle('idle', !p);
    $('play-empty').hidden = !!p;
    for (const id of ['now-card', 'lines-card', 'groups-card', 'episodes-card', 'info-card']) if (!p) $(id).hidden = true;
    if (!p) {
      setText($('now-title'), '屏幕上没有在播放');
      setText($('now-sub'), '开始播放后，这里显示进度');
      const bar = seekBars[0];
      bar.input.disabled = true;
      bar.input.value = '0';
      fill(bar.input);
      setText(bar.pos, '--:--');
      setText(bar.dur, '--:--');
      setText($('volume-value'), '--');
      return;
    }

    const live = p.kind === 'live';
    $('now-card').hidden = false;
    setText($('now-title'), p.title);
    setText($('now-sub'), p.error || p.subtitle);
    setText($('play-title'), p.title);
    setText($('play-sub'), p.subtitle);
    setText($('play-error'), p.error);
    $('play-error').hidden = !p.error;
    $('play-retry').hidden = !p.error;
    $('play-seek-row').hidden = live && !(Number(p.duration) > 0);

    if (!volumeHeld) {
      volume.value = String(Math.round(Number(p.volume) || 0));
      fill(volume);
      setText($('volume-value'), volume.value);
    }

    const speeds = Array.isArray(p.speeds) ? p.speeds : [];
    $('speed-row').hidden = speeds.length === 0;
    choices($('speeds'), speeds, speeds.indexOf(p.speed), (v) => h('button', { type: 'button', class: 'chip', text: speedLabel(v) }), (v) => send('speed', { value: v }));

    const danmaku = $('danmaku');
    danmaku.hidden = typeof p.danmaku !== 'boolean';
    setText(danmaku, p.danmaku ? '弹幕 开' : '弹幕 关');
    danmaku.classList.toggle('on', !!p.danmaku);
    const subtitles = Array.isArray(p.subtitles) ? p.subtitles.filter((t) => t && t.id != null) : [];
    tracks($('subtitle-pick'), $('subtitle-select'), subtitles, p.subtitleId, 'subtitle');
    const audios = Array.isArray(p.audios) && p.audios.length > 1 ? p.audios.filter((t) => t && t.id != null) : [];
    tracks($('audio-pick'), $('audio-select'), audios, p.audioId, 'audio');
    const fullscreen = $('fullscreen');
    fullscreen.hidden = !p.canFullscreen;
    setText(fullscreen, p.fullscreen ? '退出全屏' : '全屏');
    fullscreen.classList.toggle('on', !!p.fullscreen);

    renderLines(p);
    $('groups-card').hidden =
      choices($('groups'), live ? p.groups : [], p.group, (v) => h('button', { type: 'button', class: 'chip', text: String(v) }), (_, i) => send('group', { index: i })) === 0;
    renderEpisodes(p, live);
    renderInfo(p);
    tick();
  }

  /** 线路, each with what the line check found when the screen sends it (`lineStates`, aligned with `lines`). */
  function renderLines(p) {
    const lines = Array.isArray(p.lines) && p.lines.length > 1 ? p.lines : [];
    const states = Array.isArray(p.lineStates) ? p.lineStates : [];
    $('lines-card').hidden = lines.length === 0;
    setText($('lines-meta'), states.length ? '这一集的体检结果' : lines.length ? '共 ' + lines.length + ' 条' : '');
    choices(
      $('lines'),
      lines,
      p.line,
      (name, i) => {
        const st = states[i] && typeof states[i] === 'object' ? states[i] : {};
        const kind = String(st.state || '');
        // No check results from this screen at all: no marks, only the names.
        const mark = !states.length
          ? null
          : kind === 'ok' || kind === 'slow'
            ? icon('check', 'ok')
            : kind === 'dead'
              ? icon('cross', 'bad')
              : kind === 'probing'
                ? icon('wave')
                : icon('dash', 'unknown');
        const label = String(st.label || '');
        const playing = i === p.line;
        const right = h('span', { class: 'line-state' + (kind === 'dead' ? ' bad' : '') }, [playing ? '正在播' : '', label].filter(Boolean).join(' · '));
        if (kind === 'slow') right.append(h('span', { class: 'badge warn', text: '慢' }));
        return h('button', { type: 'button', class: 'line' }, mark, h('span', { class: 'line-name', text: String(name) || '线路 ' + (i + 1) }), right);
      },
      (_, i) => send('line', { index: i }),
      [states, p.line],
    );
  }

  function renderEpisodes(p, live) {
    const items = Array.isArray(p.episodes) ? p.episodes.map((v) => String(v)) : [];
    const box = $('episodes');
    const numbers = !live && items.length > 0 && items.every((v) => EPISODE_NUMBER.test(v));
    box.classList.toggle('names', !numbers);
    setText($('episodes-title'), live ? '频道' : '选集');
    setText($('episodes-meta'), items.length ? (live ? items.length + ' 个频道' : '共 ' + items.length + ' 集') : '');
    $('episodes-card').hidden =
      choices(
        box,
        items,
        p.episode,
        (v) => h('button', { type: 'button', class: 'ep', title: v, text: numbers ? EPISODE_NUMBER.exec(v)[1] : v }),
        (_, i) => send('episode', { index: i }),
        numbers,
      ) === 0;
  }

  const HEALTH = {
    smooth: ['很顺', 'good', 'good'],
    enough: ['够用', 'plain', 'fine'],
    thin: ['快见底了，可能会卡', 'warn', 'warn'],
    waiting: ['正在缓冲', 'warn', 'hourglass'],
  };

  /** 播放信息 (`player.info`), and in developer mode 片源从哪来 (`player.chain`). An older screen sends neither. */
  function renderInfo(p) {
    const info = p.info && typeof p.info === 'object' ? p.info : null;
    const chain = p.chain && typeof p.chain === 'object' && Array.isArray(p.chain.steps) ? p.chain : null;
    $('info-card').hidden = false;
    const body = $('info-body');
    const signature = JSON.stringify([info, p.paused]);
    if (body._signature !== signature) {
      body._signature = signature;
      body.textContent = '';
      if (!info) {
        body.append(h('p', { class: 'note', text: '这块屏幕上的映舟还不报播放信息。更新到新版本后，这里会显示画面、网速、解码和换过的线路。' }));
      } else {
        const ahead = Math.max(0, Math.round(Number(info.bufferSeconds) || 0));
        const known = HEALTH[info.health];
        const health = known || [String(info.health || '正在播放'), 'plain', 'fine'];
        body.append(
          h('div', { class: 'health ' + health[1] }, icon(health[2]), h('span', null, h('b', { text: health[0] }), h('small', { text: '已缓冲 ' + ahead + ' 秒' }))),
        );
        const facts = h('dl', { class: 'facts' });
        const fact = (name, value, cls) => {
          if (value == null || value === '') return;
          facts.append(h('dt', { text: name }), h('dd', { class: cls || null, text: value }));
        };
        const w = Number(info.width) || 0;
        const ht = Number(info.height) || 0;
        const fps = Number(info.fps) || 0;
        fact('画面', [w > 0 && ht > 0 ? quality(w, ht) + '（' + w + '×' + ht + '）' : '', fps > 0 ? Math.round(fps) + ' 帧' : ''].filter(Boolean).join(' · ') || '还没有画面');
        if (info.bytesPerSecond != null) {
          const bps = Number(info.bytesPerSecond) || 0;
          fact('网速', bps > 0 ? speed(bps) : ahead >= 10 ? '缓冲够了，暂时没在下载' : '没有在下载');
        }
        if (info.hwdec != null && info.hwdec !== '') fact('解码', info.hwdec === false || info.hwdec === 'no' ? '软件解码（处理器）' : '硬件解码（显卡）');
        // A frame or two are lost when a video starts; it is worth a line once it adds up to what the eye notices.
        const dropped = Number(info.droppedFrames) || 0;
        if (dropped >= 30) fact('掉帧', '丢了 ' + dropped + ' 帧，画面可能不流畅', 'warn');
        fact('来自', info.source ? String(info.source) : '');
        const count = Number(info.lineCount) || 0;
        const line = info.line ? String(info.line) + (count > 1 ? '（共 ' + count + ' 条）' : '') : '';
        fact('线路', [line, info.how ? String(info.how) : ''].filter(Boolean).join(' · '));
        const switched = Array.isArray(info.switched) ? info.switched.map((v) => String(v)).filter(Boolean) : [];
        if (switched.length) fact('换过', switched.join('\n'), 'warn');
        body.append(facts);
      }
    }
    $('chain').hidden = !chain;
    if (chain) {
      const steps = $('chain-steps');
      const sig = JSON.stringify(chain.steps);
      if (steps._signature !== sig) {
        steps._signature = sig;
        steps.textContent = '';
        for (const step of chain.steps) {
          if (!step || typeof step !== 'object') continue;
          const title = [step.title, step.detail].filter((v) => v != null && v !== '').map(String).join(' · ');
          const ms = Number(step.ms);
          const kind = step.pending ? ' pending' : step.ok === false ? ' bad' : '';
          const right = step.pending ? h('span', { text: '进行中' }) : ms > 0 || step.ms === 0 ? h('span', { text: ms + ' ms' }) : null;
          steps.append(h('div', { class: 'step' + kind }, h('i'), h('b', { text: title }), right));
        }
      }
      $('chain-copy')._text = typeof chain.text === 'string' ? chain.text : '';
    }
  }

  $('chain-copy').addEventListener('click', async () => {
    const text = $('chain-copy')._text;
    if (!text) return toast('这块屏幕没有发来可以复制的内容');
    toast((await copy(text)) ? '已复制，订阅地址和密钥已经去掉' : '这个浏览器不让网页复制，长按选中后手动复制');
  });

  // ---- 更多 (phone), and pushing a subscription from any page ----

  /**
   * Saves a subscription in the engine and, with [activate], makes it the one in use. The screen picks the new config
   * up from its engine. Resolves to {ok, message, sub, config}.
   */
  async function pushSubscription(url, name, activate) {
    const address = String(url || '').trim();
    if (!address) return { ok: false, message: '先粘贴一个订阅地址。' };
    const added = await api('POST', 'subscriptions', name ? { url: address, name } : { url: address });
    if ((added.status !== 201 && added.status !== 200) || !added.data || !added.data.id) {
      return { ok: false, message: explain(added, '这个地址没有存上。') };
    }
    if (!activate) return { ok: true, sub: added.data, message: '已保存「' + subscriptionName(added.data) + '」，没有切换。' };
    const active = await api('POST', 'subscriptions/' + encodeURIComponent(added.data.id) + '/activate');
    if (active.status !== 200 || !active.data) {
      return { ok: false, sub: added.data, message: '已保存，但没有加载出来：' + explain(active, '这个订阅打不开。') };
    }
    return { ok: true, sub: added.data, config: active.data, message: '已切换到「' + subscriptionName(added.data) + '」，' + (Number(active.data.sites) || 0) + ' 个站点。' };
  }

  async function pasteInto(input) {
    const text = await paste();
    if (text == null) {
      input.focus();
      toast('这个浏览器不让网页读剪贴板：长按输入框，选「粘贴」', 3600);
      return false;
    }
    input.value = text.trim();
    input.dispatchEvent(new Event('input'));
    return true;
  }

  $('more-paste').addEventListener('click', () => pasteInto($('more-url')));
  $('more-push').addEventListener('submit', async (e) => {
    e.preventDefault();
    const button = $('more-go');
    button.disabled = true;
    const result = await pushSubscription($('more-url').value, '', true);
    button.disabled = false;
    toast(result.message, 3600);
    if (result.ok) {
      $('more-url').value = '';
      showMore();
    }
  });

  async function showMore() {
    const [subs, config] = await Promise.all([api('GET', 'subscriptions'), api('GET', 'config')]);
    if (subs.status === 200 && Array.isArray(subs.data)) {
      const active = config.status === 200 && config.data ? subs.data.find((s) => s.id === config.data.subscriptionId) : null;
      setText($('more-sources'), subs.data.length ? subs.data.length + ' 个订阅' + (active ? ' · 正在用「' + subscriptionName(active) + '」' : '') : '还没有订阅，在上面粘贴一个');
    }
    const logs = $('more-logs');
    const res = await command('diag.summary', {}, 6000);
    const crashes = res.ok && res.data && Array.isArray(res.data.crashes) ? res.data.crashes.length : 0;
    logs.textContent = '';
    logs.classList.toggle('danger', crashes > 0);
    if (crashes > 0) append(logs, [icon('warn'), '有 ' + crashes + ' 条崩溃记录，可以下载']);
    else logs.textContent = '日志和崩溃记录，可以下载、反馈';
  }

  // ---- what the modules get ----

  const core = {
    api,
    explain,
    command,
    send,
    on,
    h,
    append,
    icon,
    toast,
    confirm,
    ask,
    dialog,
    download,
    copy,
    paste,
    pasteInto,
    go,
    pageHead,
    pushSubscription,
    forget: () => forget(true),
    thisDevice,
    fmt: { time, clock, when, ago, dateTag, bytes, speed, quality, platformLabel, subscriptionName, shortUrl, hostOf },
    state: () => state,
    screen: () => current,
    connected: () => !!socket && socket.readyState === 1,
    wide: () => WIDE.matches,
    page: () => page,
  };

  // Pinch and double-tap zoom would fight with the keys (iOS ignores user-scalable=no).
  document.addEventListener('gesturestart', (e) => e.preventDefault());
  document.addEventListener('dblclick', (e) => {
    if (e.target instanceof Element && e.target.closest('.remote-col, .transport')) e.preventDefault();
  });

  const code = takeCode();
  page = pageFromHash() || (store.get('tab') === 'play' ? 'play' : 'remote');
  start(code);
})();
