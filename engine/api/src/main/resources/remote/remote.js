// 映舟遥控: the web remote (docs/protocol.md, "遥控"). One page, no dependencies, no build step.
//
// The page is served by the engine without a token. It pairs itself (POST /api/v1/pair with the code the screen
// shows, or the one in the address's #code=), keeps the token in localStorage, lists the screens and opens a
// WebSocket to one: the screen's state comes in, key presses and commands go out. Everything a screen reports
// (titles, episode names) comes from third-party sites, so it only ever reaches the page through textContent.
(() => {
  'use strict';

  const PROTOCOL = 'yingzhou.remote.v1';
  const TOKEN_PROTOCOL = 'yingzhou.token.';
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

  // ---- views ----

  let view = 'boot';
  function show(name) {
    view = name;
    for (const v of ['boot', 'pair', 'screens', 'remote']) $('view-' + v).hidden = v !== name;
  }

  let toastTimer = 0;
  function toast(text) {
    const el = $('toast');
    el.textContent = text;
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (el.hidden = true), 2400);
  }

  function buzz() {
    try {
      if (navigator.vibrate) navigator.vibrate(8);
    } catch (_) {
      // No haptics here (iOS).
    }
  }

  function deviceName() {
    const ua = navigator.userAgent || '';
    let name = '浏览器';
    if (/iPhone/.test(ua)) name = 'iPhone';
    else if (/iPad/.test(ua)) name = 'iPad';
    else if (/HarmonyOS/i.test(ua)) name = '鸿蒙手机';
    else if (/Android/.test(ua)) name = /Mobile/.test(ua) ? '安卓手机' : '安卓平板';
    return '遥控 · ' + name;
  }

  // ---- starting: is a token needed, is there one, which screen ----

  let current = null; // the screen being driven: {id, name, …}
  let manual = false; // the user asked for the list of screens
  let startSeq = 0;

  /** The pairing code of a QR code (`#code=123456`), taken out of the address so it is not used twice. */
  function takeCode() {
    const m = /(?:^|[#&])code=(\d{6})(?:&|$)/.exec(location.hash);
    if (/(?:^|[#&])tab=play(?:&|$)/.test(location.hash)) store.set('tab', 'play');
    if (location.hash) {
      try {
        history.replaceState(null, '', location.pathname + location.search);
      } catch (_) {
        // Stays in the address; a used code is refused anyway.
      }
    }
    return m ? m[1] : '';
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
    let res = await api('GET', 'remote/screens');
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
    const res = await api('POST', 'pair', { code, name: deviceName() });
    if (res.status === 200 && res.data && res.data.token) {
      store.set('token', res.data.token);
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

  const formNames = { tv: '电视模式', desktop: '桌面', phone: '手机', tablet: '平板' };

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
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'screen-card';
      const dot = document.createElement('span');
      dot.className = 'dot';
      const text = document.createElement('span');
      const name = document.createElement('b');
      name.textContent = screen.name || '映舟';
      const sub = document.createElement('small');
      sub.textContent = [formNames[screen.form] || '', screen.title || ''].filter(Boolean).join(' · ');
      text.append(name, sub);
      card.append(dot, text);
      card.addEventListener('click', () => {
        manual = false;
        connect(screen);
      });
      box.append(card);
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

  $('screens-forget').addEventListener('click', () => {
    store.set('token', '');
    store.set('screen', '');
    manual = false;
    start('');
  });

  // ---- the connection to a screen ----

  let socket = null;
  let state = null; // the screen's last state
  let stateAt = 0; // when it came, on performance.now()
  let lastHeard = 0;
  let retries = 0;
  let reconnecting = false;
  let commandSeq = 0;

  function setStatus(text, kind) {
    const el = $('screen-status');
    el.textContent = text;
    el.className = kind || '';
  }

  function connect(screen) {
    stopScreensPoll();
    current = screen;
    store.set('screen', screen.id);
    state = null;
    show('remote');
    $('screen-name').textContent = screen.name || '映舟';
    setStatus('正在连接…', '');
    render();
    retries = 0;
    openSocket();
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
    render();
    setStatus('连接断开，正在重连…', 'bad');
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
            $('screen-name').textContent = found.name || '映舟';
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
          $('screen-name').textContent = current.name || '映舟';
        }
        break;
      case 'state':
        state = msg.state && typeof msg.state === 'object' ? msg.state : null;
        stateAt = performance.now();
        render();
        break;
      case 'result':
        if (msg.ok === false && msg.message) toast(String(msg.message));
        break;
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

  $('screen-button').addEventListener('click', async () => {
    manual = true;
    closeSocket();
    const res = await api('GET', 'remote/screens');
    if (res.status === 200 && Array.isArray(res.data)) showScreens(res.data);
    else start('');
  });

  // ---- sliders ----

  function time(ms) {
    const total = Math.max(0, Math.floor(ms / 1000));
    const h = Math.floor(total / 3600);
    const m = String(Math.floor((total % 3600) / 60)).padStart(2, '0');
    const s = String(total % 60).padStart(2, '0');
    return h > 0 ? h + ':' + m + ':' + s : m + ':' + s;
  }

  function fill(input) {
    const max = Number(input.max) || 1;
    input.style.setProperty('--fill', Math.max(0, Math.min(100, (Number(input.value) / max) * 100)) + '%');
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
    { input: $('play-seek'), pos: $('play-pos'), dur: $('play-dur') },
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
    for (const bar of seekBars) {
      const seconds = Math.max(1, Math.floor(duration / 1000));
      if (bar.input.max !== String(seconds)) bar.input.max = String(seconds);
      bar.input.disabled = !(duration > 0) || p.seekable === false;
      bar.dur.textContent = duration > 0 ? time(duration) : '直播';
      if (dragging !== bar.input) {
        bar.input.value = String(Math.floor(at / 1000));
        bar.pos.textContent = time(at);
        fill(bar.input);
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

  // ---- what is typed for the screen's text field ----

  const textBar = $('text-bar');
  const textInput = $('text-input');
  let composing = false;
  let typedAt = 0;
  let textTimer = 0;

  function sendText() {
    typedAt = Date.now();
    if (textTimer) return;
    textTimer = setTimeout(() => {
      textTimer = 0;
      send('text', { value: textInput.value });
    }, 60);
  }
  textInput.addEventListener('compositionstart', () => (composing = true));
  textInput.addEventListener('compositionend', () => {
    composing = false;
    sendText();
  });
  textInput.addEventListener('input', () => {
    // While an input method is composing (pinyin), the field on the screen waits for the finished text.
    if (!composing) sendText();
  });
  textBar.addEventListener('submit', (e) => {
    e.preventDefault();
    clearTimeout(textTimer);
    textTimer = 0;
    send('text', { value: textInput.value });
    send('submit', {});
    textInput.blur();
  });

  function renderText(text) {
    if (!text) {
      if (!textBar.hidden) {
        textBar.hidden = true;
        textInput.blur();
      }
      return;
    }
    const value = typeof text.value === 'string' ? text.value : '';
    if (textBar.hidden) {
      textBar.hidden = false;
      textInput.type = text.secret ? 'password' : 'text';
      textInput.placeholder = (text.hint ? String(text.hint) + '：' : '') + '在这里输入，屏幕上同步';
      textInput.value = value;
    } else if (!composing && Date.now() - typedAt > 1200 && textInput.value !== value) {
      // Changed on the screen (its own keyboard, or cleared): follow, unless this phone is the one typing.
      textInput.value = value;
    }
  }

  // ---- drawing the state ----

  function setText(el, text) {
    const next = text == null ? '' : String(text);
    if (el.textContent !== next) el.textContent = next;
  }

  /**
   * A row of choices. Built again only when the choices change (a long episode list is not rebuilt for every state);
   * otherwise only the chosen one is marked.
   */
  function choices(box, card, items, chosen, label, pick) {
    const list = Array.isArray(items) ? items : [];
    if (card) card.hidden = list.length === 0;
    const signature = JSON.stringify(list);
    let scroll = false;
    if (box._signature !== signature) {
      box._signature = signature;
      box.textContent = '';
      list.forEach((item, index) => {
        const chip = document.createElement('button');
        chip.type = 'button';
        chip.className = 'chip';
        chip.textContent = label(item, index);
        chip.addEventListener('click', () => {
          buzz();
          pick(item, index);
        });
        box.append(chip);
      });
      box._chosen = -2;
      scroll = true;
    }
    if (box._chosen !== chosen) {
      box._chosen = chosen;
      Array.prototype.forEach.call(box.children, (chip, index) => chip.classList.toggle('on', index === chosen));
      scroll = true;
    }
    // Keeps the chosen one in sight in a list that scrolls (the episodes).
    const on = box.children[chosen];
    if (scroll && on && box.scrollHeight > box.clientHeight) box.scrollTop = on.offsetTop - box.offsetTop - box.clientHeight / 2 + on.offsetHeight / 2;
  }

  function render() {
    const s = state || {};
    const p = s.player && typeof s.player === 'object' ? s.player : null;
    const body = document.body;
    body.classList.toggle('playing', !!p && !p.paused);
    body.classList.toggle('muted', !!p && (!!p.muted || Number(p.volume) === 0));
    body.classList.toggle('no-player', !p);

    const mode = $('mode-button');
    mode.hidden = !s.canTv;
    setText(mode, s.form === 'tv' ? '电视模式：开' : '电视模式：关');
    mode.classList.toggle('on', s.form === 'tv');
    if (state && socket) setStatus(s.title ? String(s.title) : '已连接', 'ok');

    renderText(s.text && typeof s.text === 'object' ? s.text : null);

    $('now').hidden = !p;
    $('play-empty').hidden = !!p;
    $('play-body').hidden = !p;
    if (!p) return;

    const live = p.kind === 'live';
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
    }

    const speeds = Array.isArray(p.speeds) ? p.speeds : [];
    choices($('speeds'), $('speed-card'), speeds, speeds.indexOf(p.speed), (v) => v + 'x', (v) => send('speed', { value: v }));
    choices($('groups'), $('groups-card'), p.groups, p.group, (v) => String(v), (_, i) => send('group', { index: i }));
    const lines = Array.isArray(p.lines) && p.lines.length > 1 ? p.lines : [];
    choices($('lines'), $('lines-card'), lines, p.line, (v, i) => String(v) || '线路 ' + (i + 1), (_, i) => send('line', { index: i }));
    setText($('episodes-title'), live ? '频道' : '选集');
    choices($('episodes'), $('episodes-card'), p.episodes, p.episode, (v) => String(v), (_, i) => send('episode', { index: i }));
    const subtitles = Array.isArray(p.subtitles) ? p.subtitles : [];
    choices($('subtitles'), $('subtitles-card'), subtitles, subtitles.findIndex((t) => t && t.id === p.subtitleId), (t) => String((t && t.name) || ''), (t) => send('subtitle', { id: t.id }));
    const audios = Array.isArray(p.audios) && p.audios.length > 1 ? p.audios : [];
    choices($('audios'), $('audios-card'), audios, audios.findIndex((t) => t && t.id === p.audioId), (t) => String((t && t.name) || ''), (t) => send('audio', { id: t.id }));

    const danmaku = $('danmaku');
    danmaku.hidden = typeof p.danmaku !== 'boolean';
    setText(danmaku, p.danmaku ? '弹幕：开' : '弹幕：关');
    danmaku.classList.toggle('on', !!p.danmaku);
    const fullscreen = $('fullscreen');
    fullscreen.hidden = !p.canFullscreen;
    setText(fullscreen, p.fullscreen ? '退出全屏' : '全屏');
    fullscreen.classList.toggle('on', !!p.fullscreen);
    tick();
  }

  // ---- the two tabs ----

  function selectTab(name) {
    store.set('tab', name);
    $('tab-remote').hidden = name !== 'remote';
    $('tab-play').hidden = name !== 'play';
    for (const button of document.querySelectorAll('.tab-button')) button.classList.toggle('on', button.dataset.tab === name);
    if (name === 'play') render();
  }
  for (const button of document.querySelectorAll('.tab-button')) {
    button.addEventListener('click', () => {
      buzz();
      selectTab(button.dataset.tab);
    });
  }

  // Pinch and double-tap zoom would fight with the keys (iOS ignores user-scalable=no).
  document.addEventListener('gesturestart', (e) => e.preventDefault());
  document.addEventListener('dblclick', (e) => e.preventDefault());

  const code = takeCode();
  selectTab(store.get('tab') === 'play' ? 'play' : 'remote');
  start(code);
})();
