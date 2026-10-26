/* Kolom site — the guided demo: one simulated Mac screen, six scripted chapters.
   Everything is deterministic. Each chapter starts from the same state, the ghost
   cursor plays the same gesture, and the "live" numbers come from a fixed series.
   Geometry is in logical points; the scene is scaled to fit its frame. */
(function () {
  'use strict';
  const A = window.KolomApps;
  const dm = document.getElementById('dm');
  if (!dm || !A) return;
  const fit = dm.querySelector('.dm-fit');
  const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
  let RM = mq.matches;
  if (mq.addEventListener) mq.addEventListener('change', (e) => { RM = e.matches; });

  const MB = 26, RAIL = 60, GAP = 14, TOP = 12, BOT = 12, PANEL = 420;
  let W = 1440, H = 900, s = 1, k = 1;
  const SH = () => H - MB - TOP - BOT;
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const easeOut = (p) => 1 - Math.pow(1 - p, 3.2);
  const easeIO = (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const sc = (v) => Math.round(v * W / 1440);

  /* ---------- the windows ---------- */
  const CAT = [
    ['browser', 'browser', 'docs', 'Columns & stacks · Kolom docs', 560, 'Browser'],
    ['code', 'code', 'reveal', 'Workspace.swift — kolom', 680, 'Code'],
    ['terminal', 'terminal', 'build', '~/kolom — zsh', 500, 'Terminal'],
    ['notes', 'notes', 'launch', 'Launch checklist', 500, 'Notes'],
    ['calendar', 'calendar', '', 'October 2026', 520, 'Calendar'],
    ['music', 'music', '', 'Night Shift Tapes', 600, 'Music'],
    ['chat', 'chat', '', '# launch — Studio', 540, 'Chat'],
    ['mail', 'mail', '', 'Inbox — 2 unread', 600, 'Mail']
  ];
  // Where each window sat before Kolom managed it (a 1440×900 screen), back to front.
  const ORIG = {
    mail: [330, 150, 720, 520], chat: [770, 236, 520, 560], calendar: [990, 64, 400, 430], notes: [880, 340, 470, 470],
    music: [96, 336, 560, 450], terminal: [262, 478, 660, 370], code: [480, 116, 840, 600], browser: [150, 60, 800, 590]
  };
  const ZORD = ['mail', 'chat', 'calendar', 'notes', 'music', 'terminal', 'code', 'browser'];

  /* ---------- scene markup ---------- */
  const glyph = '<svg viewBox="0 0 19 13" aria-hidden="true"><rect x=".7" y=".7" width="17.6" height="11.6" rx="2.4" fill="none" stroke="currentColor" stroke-width="1.4"/><rect class="c" x="3.5" y="3.2" width="3" height="6.6" rx=".8" fill="currentColor"/><rect class="c" x="8" y="3.2" width="3" height="6.6" rx=".8" fill="currentColor"/><rect class="c" x="12.5" y="3.2" width="3" height="6.6" rx=".8" fill="currentColor"/></svg>';
  const kolomIcon = '<svg viewBox="0 0 40 40" aria-hidden="true"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="#10120e"/><rect x="8" y="10" width="7" height="20" rx="2" fill="#eeede6"/><rect x="17" y="10" width="7" height="9" rx="2" fill="#eeede6"/><rect x="17" y="21" width="7" height="9" rx="2" fill="#eeede6"/><rect x="26" y="10" width="7" height="20" rx="2" fill="#d4ff4a"/></svg>';
  const sparkle = '<svg viewBox="0 0 30 30" aria-hidden="true"><defs><linearGradient id="dm-sp" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#d4ff4a"/><stop offset="1" stop-color="#7cc4ff"/></linearGradient></defs><path d="M13.5 2.5l2.9 7.6 7.6 2.9-7.6 2.9-2.9 7.6-2.9-7.6L3 13l7.6-2.9Z" fill="url(#dm-sp)"/><path d="M23.5 19l1.2 3.1 3.1 1.2-3.1 1.2-1.2 3.1-1.2-3.1-3.1-1.2 3.1-1.2Z" fill="url(#dm-sp)"/></svg>';
  const lock = '<svg viewBox="0 0 14 14" aria-hidden="true"><rect x="2.5" y="6" width="9" height="6.5" rx="1.6" fill="currentColor"/><path d="M4.5 6V4.6a2.5 2.5 0 0 1 5 0V6" fill="none" stroke="currentColor" stroke-width="1.4"/></svg>';
  const icoOk = '<svg viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="8" fill="#d4ff4a"/><path d="m5.4 9.2 2.4 2.4 4.8-5" fill="none" stroke="#10120e" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const icoNo = '<svg viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="8" fill="#ffb08f"/><path d="M9 4.8v5.2M9 12.6v.4" stroke="#10120e" stroke-width="1.9" stroke-linecap="round"/></svg>';
  const spark = (c) => `<svg class="spark ${c}" viewBox="0 0 100 40" preserveAspectRatio="none"><polygon/><polyline/></svg>`;

  const scene = document.createElement('div');
  scene.className = 'scene no-anim';
  scene.dataset.look = 'wallpaper';
  scene.innerHTML = `
    <div class="d-wall"></div>
    <div class="d-icons" aria-hidden="true"><div><i>${A.ICONS.folder}</i><span>Projects</span></div><div><i>${A.ICONS.image}</i><span>Launch.png</span></div></div>
    <div class="d-view"><div class="d-strip"><div class="d-slot"><span>Stack here</span></div><div class="d-gridbox"><span></span></div></div></div>
    <aside class="d-perf" aria-label="Performance">
      <div class="pf-h"><div><small>PERFORMANCE</small><b>This Mac</b></div><span class="pf-live"><i></i>Live</span></div>
      <div class="pf-tiles"><div><small>CPU</small><b data-p="cpu"></b>${spark('c')}</div><div><small>Memory</small><b data-p="mem"></b>${spark('m')}</div><div><small>Network</small><b data-p="net"></b>${spark('n')}</div></div>
      <table class="pf-t"><thead><tr><th>App</th><th class="on">CPU ↓</th><th>GPU</th><th>Memory</th></tr></thead><tbody></tbody></table>
      <p class="pf-note">— means macOS doesn’t attribute it to an app. Kolom won’t guess.</p>
    </aside>
    <nav class="d-rail" aria-label="Kolom rail"><div class="r-list"></div><div class="r-bot"><button class="r-help" type="button" aria-label="Open the Kolom guide">?</button><button class="r-res" type="button" aria-label="Performance: CPU, memory and network"><span><em>CPU</em><b data-r="cpu">18%</b></span><span><em>MEM</em><b data-r="mem">61%</b></span><span><em>NET</em><b data-r="net">1.4M</b></span></button></div></nav>
    <div class="d-mb"><i class="mb-logo"></i><b class="mb-app">Browser</b><span class="mb-menus"></span><span class="mb-r"><button class="mb-kolom" type="button" aria-label="Kolom commands (Option-M)">${glyph}</button><i class="mb-batt"></i><span>Sun 26 Oct 9:41</span></span></div>
    <div class="d-menu" role="menu" aria-label="Kolom menu"><p><span>Kolom</span><span></span></p><button type="button" role="menuitem" data-m="pause"><span>Pause and restore windows</span></button><button type="button" role="menuitem" data-m="ask"><span>Ask Kolom…</span><kbd>⌥K</kbd></button><hr><button type="button" role="menuitem" data-m="prev"><span>Previous column</span><kbd>⌥←</kbd></button><button type="button" role="menuitem" data-m="next"><span>Next column</span><kbd>⌥→</kbd></button><button type="button" role="menuitem" data-m="desk"><span>Show the desktop</span><kbd>⌥D</kbd></button><hr><button type="button" role="menuitem" data-m="perf"><span>Performance</span></button><button type="button" role="menuitem" data-m="guide"><span>Open the guide</span></button></div>
    <div class="d-guide" role="dialog" aria-label="Kolom guide"><b>Welcome to Kolom</b><small>The built-in guide. It lives behind the ? in the rail.</small><ul><li><kbd>2 fingers</kbd><span>Swipe sideways to scroll the strip</span></li><li><kbd>⌥1 – ⌥9</kbd><span>Jump to a window</span></li><li><kbd>drag icon</kbd><span>Drop it on another icon to stack</span></li><li><kbd>⌥K</kbd><span>Ask Kolom for a layout</span></li></ul></div>
    <div class="d-ask" role="dialog" aria-label="Ask Kolom"><div class="ask-bar">${sparkle}<input class="ask-in" type="text" placeholder="Ask Kolom" aria-label="Ask Kolom" autocomplete="off" autocapitalize="off" spellcheck="false"><span class="ask-badge">${lock}On this Mac</span></div><div class="ask-chips"><button type="button">3×2 terminals</button><button type="button">focus Music</button><button type="button">show the desktop</button></div><div class="ask-status"></div></div>
    <div class="d-toast" role="status"><i></i><span class="t-msg"></span><button type="button" hidden></button></div>
    <div class="d-fx" aria-hidden="true"><div class="fx-ring"></div><div class="fx-drop"></div><div class="fx-drag"></div><div class="fx-fingers"><i></i><i></i></div><div class="fx-keys"></div><div class="fx-cur"><svg viewBox="0 0 26 38"><path d="M2.5 2.5v28.2l6.9-6.6 4.6 10.6 4.9-2.1-4.5-10.4h9.6Z" fill="#111" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg></div></div>`;
  fit.appendChild(scene);

  const q = (sel) => scene.querySelector(sel);
  const strip = q('.d-strip'), slot = q('.d-slot'), gridBox = q('.d-gridbox');
  const railList = q('.r-list'), resBtn = q('.r-res'), helpBtn = q('.r-help');
  const mbApp = q('.mb-app'), mbMenus = q('.mb-menus'), mbKolom = q('.mb-kolom');
  const menu = q('.d-menu'), menuPause = q('[data-m="pause"]');
  const askIn = q('.ask-in'), askStatus = q('.ask-status');
  const toastEl = q('.d-toast'), toastMsg = q('.t-msg'), toastBtn = q('.d-toast button');
  const ringEl = q('.fx-ring'), dropLab = q('.fx-drop'), dragAv = q('.fx-drag'), fingers = q('.fx-fingers'), keysEl = q('.fx-keys'), curEl = q('.fx-cur');
  const perfBody = q('.pf-t tbody');

  /* ---------- state ---------- */
  const S = { cols: [], wins: {}, focus: 'browser', offset: 0, b: RAIL + GAP, paused: false, perf: false, ask: false, grid: null, preview: null, epoch: 0, touched: false };
  let gridSeq = 0;

  function addWin(id, app, variant, title, extra) {
    const w = Object.assign({ id, app, variant, title, name: A.APPS[app].name }, extra || {});
    const el = document.createElement('div');
    el.className = 'win fresh app-' + app + (w.grid ? ' in-grid' : '');
    el.dataset.id = id;
    el.innerHTML = `<div class="win-tb"><i class="tl"></i><i class="tl"></i><i class="tl"></i><span class="win-t">${A.esc(title)}</span></div><div class="win-b">${A.content(w)}</div>`;
    strip.appendChild(el);
    w.el = el;
    S.wins[id] = w;
    requestAnimationFrame(() => requestAnimationFrame(() => el.classList.remove('fresh')));
    return w;
  }

  const baseT = () => RAIL + GAP + (S.perf ? PANEL : 0);
  const vw = () => W - baseT() - GAP;
  const totalW = () => S.cols.reduce((a, c) => a + c.w, 0) + GAP * Math.max(0, S.cols.length - 1);
  const deskOff = () => totalW() + baseT() - RAIL + 2;
  const endOff = () => Math.max(0, totalW() - vw());
  const atDesk = () => S.cols.length > 0 && S.offset >= deskOff() - 2;
  const colOf = (id) => S.cols.findIndex((c) => c.ids.indexOf(id) >= 0);
  const order = () => S.cols.reduce((a, c) => a.concat(c.ids), []);
  function colX(ci) { let x = 0; for (let i = 0; i < ci; i++) x += S.cols[i].w + GAP; return x; }
  function revealOff(ci) {
    const x = colX(ci), e = x + S.cols[ci].w, v = vw();
    let o = Math.min(S.offset, endOff());
    if (x < o) o = x; else if (e > o + v) o = e - v;
    return clamp(o, 0, endOff());
  }
  function rectL(el) {
    const r = el.getBoundingClientRect(), f = scene.getBoundingClientRect();
    return { x: (r.left - f.left) / s, y: (r.top - f.top) / s, w: r.width / s, h: r.height / s };
  }
  function origOf(id) {
    const w = S.wins[id];
    const o = ORIG[id] || [200 + ((w.cell || 1) - 1) % 10 * 40, 80 + ((w.cell || 1) - 1) % 10 * 34, 560, 340];
    return [o[0] * W / 1440, o[1] * H / 900, o[2] * W / 1440, o[3] * H / 900];
  }

  /* ---------- tweens (strip offset and base) ---------- */
  const TW = {};
  function stopTween(key) { if (TW[key]) { cancelAnimationFrame(TW[key].raf); TW[key] = null; } }
  function tween(key, to, dur, ease, done) {
    stopTween(key);
    const from = S[key];
    if (RM || dur <= 0 || Math.abs(to - from) < 0.5) { S[key] = to; apply(); if (done) done(); return; }
    const t0 = performance.now(), st = { raf: 0 };
    TW[key] = st;
    const step = (now) => {
      const p = Math.min(1, (now - t0) / dur);
      S[key] = from + (to - from) * (ease || easeOut)(p);
      apply();
      if (p < 1) st.raf = requestAnimationFrame(step);
      else { TW[key] = null; if (done) done(); }
    };
    st.raf = requestAnimationFrame(step);
  }
  const glide = (to) => tween('offset', to, clamp(Math.abs(to - S.offset) / 2.6, 480, 1100), easeOut);

  let lastDesk = false;
  function apply() {
    strip.style.transform = `translate3d(${(S.b - S.offset - RAIL).toFixed(2)}px,0,0)`;
    const d = atDesk();
    if (d !== lastDesk) { lastDesk = d; scene.classList.toggle('at-desk', d); layout(); if (d) mark('desk'); }
  }

  /* ---------- layout ---------- */
  function place(w, x, y, ww, hh) {
    const st = w.el.style;
    st.transform = `translate3d(${x.toFixed(1)}px,${y.toFixed(1)}px,0)`;
    st.width = ww.toFixed(1) + 'px';
    st.height = hh.toFixed(1) + 'px';
  }
  function layout() {
    const sh = SH();
    let x = 0, slotOn = false;
    const sx = S.b - S.offset;  // the strip's screen x (the view starts at the rail edge)
    S.cols.forEach((c, ci) => {
      const pv = S.preview && S.preview.ci === ci;
      const n = c.ids.length + (pv ? 1 : 0);
      const h = (sh - GAP * (n - 1)) / n;
      c.ids.forEach((id, ti) => {
        const w = S.wins[id];
        if (S.paused) { const o = origOf(id); place(w, o[0] - sx, o[1] - MB - TOP, o[2], o[3]); }
        else place(w, x, ti * (h + GAP), c.w, h);
      });
      if (pv) {
        slotOn = true;
        slot.style.transform = `translate3d(${x}px,${c.ids.length * (h + GAP)}px,0)`;
        slot.style.width = c.w + 'px';
        slot.style.height = h + 'px';
      }
      x += c.w + GAP;
    });
    slot.classList.toggle('on', slotOn);
    const desk = atDesk();
    Object.keys(S.wins).forEach((id) => S.wins[id].el.classList.toggle('is-key', id === S.focus && !desk));
    renderRail();
    renderMenubar();
    if (S.perf) renderPerf();
    renderExtras();
  }

  /* ---------- rail ---------- */
  const railBtns = {};
  function railBtn(id) {
    let b = railBtns[id];
    if (!b) {
      b = document.createElement('button');
      b.type = 'button';
      b.className = 'r-ic';
      b.dataset.id = id;
      b.innerHTML = `<i>${A.ICONS[S.wins[id].app]}</i><small></small>`;
      railBtns[id] = b;
    }
    return b;
  }
  let railSig = '';
  function renderRail() {
    const desk = atDesk();
    const sig = S.cols.map((c) => c.ids.join('+')).join('|') + '#' + (desk ? '' : S.focus);
    if (sig === railSig) return;
    railSig = sig;
    const ord = order();
    const flip = !RM && !scene.classList.contains('no-anim') && railList.childElementCount > 0;
    const before = {};
    if (flip) Object.keys(railBtns).forEach((id) => { if (railBtns[id].isConnected) before[id] = railBtns[id].getBoundingClientRect(); });
    const active = document.activeElement;
    const frag = document.createDocumentFragment();
    S.cols.forEach((c) => {
      const col = document.createElement('div');
      col.className = 'r-col' + (c.ids.length > 1 ? ' stack' : '');
      col.style.setProperty('--n', c.ids.length);
      const nums = [];
      c.ids.forEach((id, i) => {
        const b = railBtn(id), n = ord.indexOf(id) + 1;
        b.style.setProperty('--i', i);
        b.querySelector('small').textContent = n <= 9 ? '⌥' + n : '';
        b.classList.toggle('on', id === S.focus && !desk);
        b.setAttribute('aria-label', S.wins[id].name + (n <= 9 ? ` (Option-${n})` : ''));
        if (n <= 9) nums.push('⌥' + n);
        col.appendChild(b);
      });
      if (c.ids.length > 1) {
        const sp = document.createElement('span');
        sp.className = 'r-nums';
        sp.textContent = nums.join(' ');
        col.appendChild(sp);
      }
      frag.appendChild(col);
    });
    railList.replaceChildren(frag);
    Object.keys(railBtns).forEach((id) => { if (!S.wins[id]) delete railBtns[id]; });
    if (active && active.classList && active.classList.contains('r-ic') && active.isConnected) active.focus({ preventScroll: true });
    if (flip) {
      Object.keys(before).forEach((id) => {
        const b = railBtns[id];
        if (!b || !b.isConnected || !b.animate) return;
        const r = b.getBoundingClientRect();
        const dx = (before[id].left - r.left) / s, dy = (before[id].top - r.top) / s;
        if (Math.abs(dx) + Math.abs(dy) > 0.5) b.animate([{ transform: `translate(${dx}px,${dy}px)` }, { transform: 'none' }], { duration: 560, easing: 'cubic-bezier(.2,1.1,.3,1)' });
      });
    }
    posRing();
  }

  function renderMenubar() {
    const w = !atDesk() && S.focus && S.wins[S.focus];
    const name = w ? w.name : 'Finder';
    if (mbApp.textContent !== name) {
      mbApp.textContent = name;
      mbMenus.textContent = (w ? A.APPS[w.app].menus : ['File', 'Edit', 'View', 'Go', 'Window']).join('    ');
    }
    menuPause.firstChild.textContent = S.paused ? 'Enable window management' : 'Pause and restore windows';
  }

  /* ---------- numbers: a fixed series, so every visit looks the same ---------- */
  let tick = 0;
  const ser = (i, base, amp, ph) => base + amp * Math.sin(i * 0.71 + ph) + amp * 0.45 * Math.sin(i * 1.93 + ph * 2.3);
  const APPLOAD = { browser: [14.2, 3050], code: [9.8, 2240], terminal: [2.1, 180], notes: [0.3, 150], calendar: [0.2, 120], music: [3.4, 410], chat: [1.8, 640], mail: [0.6, 320] };
  function renderReadout() {
    const cpu = Math.round(ser(tick, 19 + (S.grid ? 4 : 0), 4, 0)), mem = Math.round(ser(tick, 61 + (S.grid ? 3 : 0), 1.4, 1)), net = ser(tick, 1.4, 0.5, 2);
    q('[data-r="cpu"]').textContent = cpu + '%';
    q('[data-r="mem"]').textContent = mem + '%';
    q('[data-r="net"]').textContent = net.toFixed(1) + 'M';
    return { cpu, mem, net };
  }
  function sparkPts(base, amp, ph) {
    const pts = [];
    for (let i = 0; i < 30; i++) pts.push([(i / 29) * 100, 38 - clamp(ser(tick - 29 + i, base, amp, ph), 0, 100) * 0.36]);
    return pts;
  }
  function drawSpark(svg, pts) {
    const line = pts.map((p) => p[0].toFixed(1) + ',' + p[1].toFixed(1)).join(' ');
    svg.querySelector('polyline').setAttribute('points', line);
    svg.querySelector('polygon').setAttribute('points', '0,40 ' + line + ' 100,40');
  }
  function renderPerf() {
    const r = renderReadout();
    q('[data-p="cpu"]').textContent = r.cpu + '%';
    q('[data-p="mem"]').textContent = r.mem + '%';
    q('[data-p="net"]').textContent = r.net.toFixed(1) + ' MB/s';
    drawSpark(q('.spark.c'), sparkPts(40, 14, 0));
    drawSpark(q('.spark.m'), sparkPts(62, 4, 1));
    drawSpark(q('.spark.n'), sparkPts(30, 16, 2));
    const by = {};
    Object.keys(S.wins).forEach((id) => { const w = S.wins[id]; (by[w.app] = by[w.app] || []).push(w); });
    const rows = Object.keys(by).map((app, i) => {
      const n = by[app].length, L = APPLOAD[app] || [1, 100];
      const cpu = Math.max(0.1, ser(tick + i * 3, L[0] + (n - 1) * 0.7, L[0] * 0.12, i));
      const mem = Math.round(L[1] + (n - 1) * 46 + ser(tick + i, 0, L[1] * 0.01, i));
      return { app, name: A.APPS[app].name, n, cpu, mem, icon: A.ICONS[app] };
    });
    rows.push({ app: 'kolom', name: 'Kolom', n: 1, cpu: ser(tick, 0.8, 0.15, 3), mem: 64, icon: kolomIcon });
    rows.sort((a, b) => b.cpu - a.cpu);
    perfBody.innerHTML = rows.slice(0, 8).map((r) => `<tr><td><i>${r.icon}</i>${r.name}${r.n > 1 ? ` <span class="na">×${r.n}</span>` : ''}</td><td><span class="bar"><s style="width:${clamp(r.cpu * 5, 4, 100).toFixed(0)}%"></s></span>${r.cpu.toFixed(1)}%</td><td class="na">—</td><td>${r.mem.toLocaleString('en-US')} MB</td></tr>`).join('');
  }

  /* ---------- actions ---------- */
  function flash(id) {
    const el = S.wins[id] && S.wins[id].el;
    if (!el || RM) return;
    el.classList.remove('flash');
    void el.offsetWidth;
    el.classList.add('flash');
  }
  function focusWin(id) {
    if (!S.wins[id] || S.paused) return;
    S.focus = id;
    glide(revealOff(colOf(id)));
    layout();
    flash(id);
  }
  function stepCol(d) {
    if (S.paused || !S.cols.length) return;
    if (atDesk()) { if (d > 0) return; focusWin(S.cols[S.cols.length - 1].ids[0]); return; }
    const ci = clamp(colOf(S.focus) + d, 0, S.cols.length - 1);
    focusWin(S.cols[ci].ids[0]);
  }
  function desktop() { if (!S.paused) glide(deskOff()); }
  function setPerf(on) {
    if (on && S.paused) return;
    S.perf = on;
    scene.classList.toggle('perf-on', on);
    resBtn.classList.toggle('on', on);
    tween('b', baseT(), 720, easeOut);
    layout();
    if (on) mark('perf');
  }
  function setLook(l) { scene.dataset.look = l; }
  function toggleMenu(force) {
    const on = force === undefined ? !scene.classList.contains('menu-on') : force;
    if (on) {
      closeAll();
      const r = rectL(mbKolom);
      menu.style.left = Math.min(r.x - 6, W - 300) + 'px';
      menu.style.right = 'auto';
    }
    scene.classList.toggle('menu-on', on);
    mbKolom.classList.toggle('on', on);
  }
  function toggleGuide(force) {
    const on = force === undefined ? !scene.classList.contains('guide-on') : force;
    if (on) closeAll();
    scene.classList.toggle('guide-on', on);
    helpBtn.classList.toggle('on', on);
  }
  function closeAll() {
    scene.classList.remove('menu-on', 'guide-on');
    mbKolom.classList.remove('on');
    helpBtn.classList.remove('on');
    if (S.ask) closeAsk();
  }

  let toastCb = null, toastT = 0;
  function toast(msg, btn, cb, warm, ttl) {
    clearTimeout(toastT);
    toastMsg.textContent = msg;
    toastBtn.hidden = !btn;
    toastBtn.textContent = btn || '';
    toastCb = cb || null;
    toastEl.classList.toggle('warm', !!warm);
    toastEl.classList.add('on');
    toastEl.style.scale = k > 1 ? String(Math.min(k, 1.8)) : '';
    if (ttl) toastT = setTimeout(hideToast, ttl);
  }
  function hideToast() { clearTimeout(toastT); toastEl.classList.remove('on'); toastCb = null; }

  function pause() {
    if (S.paused) return;
    closeAll();
    stopTween('offset');
    if (S.perf) { S.perf = false; scene.classList.remove('perf-on'); resBtn.classList.remove('on'); }
    stopTween('b'); S.b = baseT(); apply();
    S.paused = true;
    scene.classList.add('paused');
    Object.keys(S.wins).forEach((id) => {
      const z = ZORD.indexOf(id);
      const st = S.wins[id].el.style;
      st.zIndex = id === S.focus ? 60 : (z < 0 ? 20 + (S.wins[id].cell || 0) : z + 1);
      st.transitionDelay = (z < 0 ? 0 : (7 - z) * 45) + 'ms';
    });
    layout();
    toast('Paused. Every window is back where you had it.', 'Resume', resume, true);
    mark('pause');
  }
  function resume() {
    if (!S.paused) return;
    const ep = S.epoch;
    S.paused = false;
    scene.classList.remove('paused');
    Object.keys(S.wins).forEach((id) => { const z = ZORD.indexOf(id); S.wins[id].el.style.transitionDelay = (z < 0 ? 0 : z * 40) + 'ms'; });
    layout();
    hideToast();
    setTimeout(() => {
      if (ep !== S.epoch || S.paused) return;
      Object.keys(S.wins).forEach((id) => { const st = S.wins[id].el.style; st.zIndex = ''; st.transitionDelay = ''; });
    }, 1200);
    mark('resume');
  }

  /* ---------- Ask Kolom ---------- */
  function openAsk(user) {
    if (S.paused) return;
    scene.classList.remove('menu-on', 'guide-on');
    S.ask = true;
    scene.classList.add('ask-on');
    scene.classList.remove('ask-busy');
    askIn.value = '';
    setStatus('');
    if (user) setTimeout(() => askIn.focus({ preventScroll: true }), RM ? 0 : 80);
  }
  function closeAsk() {
    S.ask = false;
    scene.classList.remove('ask-on', 'ask-busy');
    if (document.activeElement === askIn) fit.focus({ preventScroll: true });
  }
  function setStatus(html, cls) { askStatus.className = 'ask-status' + (cls ? ' ' + cls : ''); askStatus.innerHTML = html; }

  const NAMES = [['browser', /\b(browser|safari|web|docs?)\b/], ['code', /\b(code|editor|xcode)\b/], ['terminal', /\b(terminal|shell|zsh)\b/], ['notes', /\bnotes?\b/], ['calendar', /\bcal(endar)?\b/], ['music', /\bmusic\b/], ['chat', /\b(chat|messages)\b/], ['mail', /\b(e?mail|inbox)\b/]];
  function interpret(text) {
    const t = text.toLowerCase().replace(/[×✕]/g, 'x');
    let m = t.match(/(\d+)\s*(?:x|by|\*)\s*(\d+)/), c = 0, r = 0, n = 0;
    if (m) { c = +m[1]; r = +m[2]; n = c * r; }
    else if ((m = t.match(/(\d+)\s*(?:terminals?|terms?|shells?|windows?)/))) { n = +m[1]; r = n <= 3 ? 1 : n <= 8 ? 2 : 3; c = Math.ceil(n / r); }
    if (m) {
      if (!n) return { say: 'A grid needs at least one window.' };
      if (n > 60) return { say: 'Grids top out at 60 windows.' };
      if (r > 6) return { say: 'Too tall for this screen. Try six rows or fewer.' };
      return { say: n === c * r ? `Terminal grid · ${c} × ${r}` : `${n} Terminal windows`, run: () => makeGrid(c, r, n) };
    }
    if (/\bundo\b/.test(t)) return S.grid ? { say: 'Removing the last grid', run: undoGrid } : { say: 'There’s no grid to undo yet.' };
    if (/desktop/.test(t)) return { say: 'Showing the desktop', run: desktop };
    if (/\bnext\b/.test(t)) return { say: 'Next column', run: () => stepCol(1) };
    if (/\b(prev|previous|back)\b/.test(t)) return { say: 'Previous column', run: () => stepCol(-1) };
    if (/\bpause\b/.test(t)) return { say: 'Pausing Kolom', run: pause };
    if (/perf|cpu|memory|activity/.test(t)) return { say: 'Opening Performance', run: () => setPerf(true) };
    if (/guide|help/.test(t)) return { say: 'Opening the guide', run: () => toggleGuide(true) };
    if (/\bdark\b/.test(t)) return { say: 'Dark theme', run: () => setLook('dark') };
    if (/\blight\b/.test(t)) return { say: 'Light theme', run: () => setLook('light') };
    if (/wallpaper/.test(t)) return { say: 'Wallpaper theme', run: () => setLook('wallpaper') };
    if (/(move|send|put|throw)/.test(t) && /(screen|display|monitor)/.test(t)) return { say: 'This demo has one screen. On your Mac, Kolom moves it to the display you name.' };
    for (const [app, re] of NAMES) {
      if (re.test(t)) {
        const id = order().find((x) => S.wins[x].app === app);
        if (id) return { say: `Focusing ${A.APPS[app].name}`, run: () => { focusWin(id); mark('focus'); } };
      }
    }
    return { say: 'Kolom didn’t catch that. Try “3×2 terminals”.' };
  }
  function submit(text) {
    text = (text || '').trim();
    if (!text) return Promise.resolve();
    const ep = S.epoch, r = interpret(text);
    scene.classList.add('ask-busy');
    setStatus('<span>Thinking on this Mac…</span>', 'think');
    return sleep(RM ? 0 : 900).then(() => {
      if (ep !== S.epoch) return null;
      if (!r.run) { setStatus(`${icoNo}<span class="bad">${A.esc(r.say)}</span>`); scene.classList.remove('ask-busy'); return null; }
      setStatus(`${icoOk}<span class="ok">${A.esc(r.say)}</span>`);
      return sleep(RM ? 0 : 520).then(() => { if (ep !== S.epoch) return; closeAsk(); r.run(); });
    });
  }
  function askRun(text) {
    if (S.paused) resume();
    if (!S.ask) openAsk(false);
    askIn.value = text;
    return submit(text);
  }

  function makeGrid(c, r, n) {
    if (S.paused) return;
    if (S.grid) undoGrid(true);
    const ep = S.epoch;
    const at = S.focus && !atDesk() && colOf(S.focus) >= 0 ? colOf(S.focus) + 1 : S.cols.length;
    const v = vw();
    const cw = Math.max(sc(260), (v - GAP * (c - 1)) / c);
    const ids = [], cols = [];
    let cell = 0;
    for (let i = 0; i < c; i++) {
      const col = { w: cw, ids: [], grid: true };
      for (let j = 0; j < r && cell < n; j++) {
        cell++;
        const id = 'g' + (++gridSeq);
        const w = addWin(id, 'terminal', '', `~/work — zsh — ${cell}`, { grid: true, cell });
        w.el.classList.add('spawn');
        w.el.style.setProperty('--i', cell - 1);
        ids.push(id);
        col.ids.push(id);
      }
      cols.push(col);
    }
    S.grid = { ids, prevFocus: S.focus, prevOff: S.offset, c, r };
    S.cols.splice(at, 0, ...cols);
    S.focus = ids[0];
    layout();
    const x0 = colX(at), x1 = colX(at + cols.length - 1) + cw;
    glide(clamp(x0 - Math.max(0, (v - (x1 - x0)) / 2), 0, endOff()));
    gridBox.style.transform = `translate3d(${x0 - 6}px,-6px,0)`;
    gridBox.style.width = (x1 - x0 + 12) + 'px';
    gridBox.style.height = (SH() + 12) + 'px';
    gridBox.querySelector('span').textContent = n === c * r ? `${c} × ${r}` : `${n} terminals`;
    gridBox.classList.add('on');
    setTimeout(() => { if (ep === S.epoch) gridBox.classList.remove('on'); }, 2600);
    setTimeout(() => ids.forEach((id) => S.wins[id] && S.wins[id].el.classList.remove('spawn')), 900 + n * 55);
    toast(`Made a ${n === c * r ? c + '×' + r : n + '-window'} Terminal grid`, 'Undo', () => undoGrid());
    mark('ask');
  }
  function undoGrid(silent) {
    if (!S.grid) return;
    const g = S.grid;
    S.grid = null;
    g.ids.forEach((id) => {
      const w = S.wins[id];
      if (!w) return;
      delete S.wins[id];
      w.el.classList.add('leaving');
      setTimeout(() => w.el.remove(), 420);
    });
    S.cols.forEach((c) => { c.ids = c.ids.filter((id) => S.wins[id]); });
    S.cols = S.cols.filter((c) => c.ids.length);
    S.focus = S.wins[g.prevFocus] ? g.prevFocus : order()[0];
    gridBox.classList.remove('on');
    if (silent) return;
    layout();
    glide(clamp(g.prevOff, 0, endOff()));
    hideToast();
    mark('undo');
  }

  /* ---------- drag a rail icon onto another to stack ---------- */
  let D = null;
  function dragBegin(id, p) {
    if (S.paused || !S.wins[id]) return false;
    closeAll();
    stopTween('offset');
    D = { id, src: colOf(id), tgt: -1, full: false };
    dragAv.innerHTML = A.ICONS[S.wins[id].app];
    dragAv.classList.remove('back');
    dragAv.classList.add('on');
    railBtn(id).classList.add('lifting');
    S.wins[id].el.classList.add('lifting');
    dragMove(p);
    return true;
  }
  function dragMove(p) {
    if (!D) return;
    dragAv.style.transform = `translate(${p.x - 26}px,${p.y - 26}px) scale(${(Math.max(1, k * 0.85) * 1.05).toFixed(3)})`;
    let hit = null;
    if (p.x < RAIL + 46) {
      S.cols.forEach((c) => c.ids.forEach((id) => {
        if (id === D.id) return;
        const r = rectL(railBtn(id));
        if (p.y >= r.y - 4 && p.y <= r.y + r.h + 4) hit = id;
      }));
    }
    let ci = hit ? colOf(hit) : -1;
    if (ci === D.src) ci = -1;
    if (ci !== D.tgt) setTarget(ci);
  }
  function setTarget(ci) {
    scene.querySelectorAll('.r-ic.drop, .r-ic.full').forEach((b) => b.classList.remove('drop', 'full'));
    D.tgt = ci;
    D.full = ci >= 0 && S.cols[ci].ids.length >= 3;
    if (ci < 0) {
      dropLab.classList.remove('on');
      if (S.preview) { S.preview = null; layout(); }
      return;
    }
    const col = S.cols[ci];
    col.ids.forEach((id) => railBtn(id).classList.add(D.full ? 'full' : 'drop'));
    const r = rectL(railBtn(col.ids[col.ids.length - 1]));
    dropLab.textContent = D.full ? 'Full — three per column' : `Stack with ${S.wins[col.ids[0]].name}`;
    dropLab.classList.toggle('full', D.full);
    dropLab.style.transform = `translate(0,${(r.y + r.h / 2 - 20).toFixed(1)}px) scale(${Math.min(k, 2.2).toFixed(3)})`;
    dropLab.classList.add('on');
    S.preview = D.full ? null : { ci };
    layout();
    if (!D.full) glide(revealOff(ci));
  }
  function dragEnd(commit, silent) {
    if (!D) return;
    const d = D;
    D = null;
    scene.querySelectorAll('.r-ic.drop, .r-ic.full, .r-ic.lifting').forEach((b) => b.classList.remove('drop', 'full', 'lifting'));
    Object.keys(S.wins).forEach((id) => S.wins[id].el.classList.remove('lifting'));
    dropLab.classList.remove('on');
    S.preview = null;
    if (commit && d.tgt >= 0 && !d.full) { dragAv.classList.remove('on'); moveInto(d.id, d.tgt); return; }
    if (!silent && railBtns[d.id]) {
      const r = rectL(railBtns[d.id]);
      dragAv.classList.add('back');
      dragAv.style.transform = `translate(${r.x + r.w / 2 - 26}px,${r.y + 20 - 26}px) scale(.7)`;
    }
    dragAv.classList.remove('on');
    if (!silent) layout();
  }
  function moveInto(id, ci) {
    const tgt = S.cols[ci], src = S.cols[colOf(id)];
    if (!tgt || !src || tgt === src || tgt.ids.length >= 3) return;
    src.ids.splice(src.ids.indexOf(id), 1);
    tgt.ids.push(id);
    if (!src.ids.length) S.cols.splice(S.cols.indexOf(src), 1);
    S.focus = id;
    layout();
    glide(revealOff(S.cols.indexOf(tgt)));
    flash(id);
    mark('stack', tgt.ids.length);
  }

  /* ---------- swipe / drag the strip ---------- */
  const band = (x) => 190 * (1 - Math.exp(-x / 280));
  function rub(o) { const dk = deskOff(); if (o < 0) return -band(-o); if (o > dk) return dk + band(o - dk); return o; }
  function settle(vel) {
    let t = S.offset + vel * 300;
    const dk = deskOff(), en = endOff();
    if (t > en + 1) t = t > en + (dk - en) * 0.3 ? dk : en;
    t = clamp(t, 0, dk);
    tween('offset', t, clamp(280 + Math.abs(t - S.offset) * 0.8, 360, 950), easeOut);
  }

  /* ---------- effects: ring, keys, ripple, fingers ---------- */
  let ringTarget = null;
  function ringOn(el) {
    ringTarget = el || null;
    ringEl.classList.toggle('on', !!el);
    posRing();
  }
  function posRing() {
    if (!ringTarget || !ringTarget.isConnected) return;
    const r = rectL(ringTarget), pad = 3;
    ringEl.style.transform = `translate(${(r.x - pad).toFixed(1)}px,${(r.y - pad).toFixed(1)}px)`;
    ringEl.style.width = (r.w + pad * 2) + 'px';
    ringEl.style.height = (r.h + pad * 2) + 'px';
    ringEl.style.setProperty('--bw', (2.5 * k).toFixed(2) + 'px');
  }
  let keysT = 0;
  function showKeys(list) {
    keysEl.innerHTML = list.map((x) => `<span>${A.esc(x)}</span>`).join('');
    keysEl.style.transform = `translateX(-50%) scale(${Math.min(k, 2).toFixed(3)})`;
    keysEl.classList.remove('on');
    void keysEl.offsetWidth;
    keysEl.classList.add('on');
    clearTimeout(keysT);
    keysT = setTimeout(() => keysEl.classList.remove('on'), 1100);
  }
  function ripple(x, y) {
    if (RM) return;
    const d = document.createElement('div');
    d.className = 'fx-rip';
    d.style.left = x + 'px';
    d.style.top = y + 'px';
    d.style.scale = String(k);
    q('.d-fx').appendChild(d);
    setTimeout(() => d.remove(), 650);
  }

  /* ---------- the ghost cursor ---------- */
  const STOP = { stop: true };
  const G = { tok: 0, running: false, x: 0, y: 0 };
  function ghostAt(x, y) {
    G.x = x; G.y = y;
    curEl.style.transform = `translate(${x.toFixed(1)}px,${y.toFixed(1)}px) scale(${k.toFixed(3)})`;
  }
  function fingersAt(x, y) { fingers.style.transform = `translate(${x.toFixed(1)}px,${y.toFixed(1)}px) scale(${k.toFixed(3)})`; }
  function anim(t, dur, fn, ease) {
    return new Promise((res, rej) => {
      if (t !== G.tok) { rej(STOP); return; }
      const t0 = performance.now();
      const f = (now) => {
        if (t !== G.tok) { rej(STOP); return; }
        const p = Math.min(1, (now - t0) / dur);
        fn((ease || easeIO)(p), p);
        if (p < 1) requestAnimationFrame(f); else res();
      };
      requestAnimationFrame(f);
    });
  }
  function ctx(t) {
    const chk = () => { if (t !== G.tok) throw STOP; };
    const g = {
      chk,
      wait: (ms) => new Promise((res, rej) => setTimeout(() => (t === G.tok ? res() : rej(STOP)), ms)),
      async move(x, y, dur) {
        const x0 = G.x, y0 = G.y, dist = Math.hypot(x - x0, y - y0), arc = Math.min(70, dist * 0.12);
        await anim(t, dur || clamp(dist * 0.85, 420, 1000), (e) => ghostAt(x0 + (x - x0) * e, y0 + (y - y0) * e - Math.sin(Math.PI * e) * arc));
      },
      async to(el, dx, dy, dur) { const r = rectL(el); await g.move(r.x + r.w / 2 + (dx || 0), r.y + r.h / 2 + (dy || 0), dur); },
      async click() { chk(); curEl.classList.add('down'); ripple(G.x, G.y); await g.wait(140); curEl.classList.remove('down'); },
      async keys(list, after) { chk(); showKeys(list); await g.wait(after || 300); },
      async type(text, per) { for (const ch of text) { chk(); askIn.value += ch; await g.wait(per || 80); } },
      async swipe(target, dur) {
        chk();
        stopTween('offset');
        const o0 = S.offset, mid = o0 + (target - o0) * 0.62, dir = Math.sign(target - o0), x0 = G.x, y0 = G.y;
        curEl.classList.remove('on');
        fingersAt(x0, y0);
        fingers.classList.add('on');
        await anim(t, dur, (e) => { S.offset = o0 + (mid - o0) * e; apply(); fingersAt(x0 - dir * 300 * e, y0); }, (p) => Math.pow(p, 1.6));
        fingers.classList.remove('on');
        tween('offset', target, dur * 1.3, easeOut);
        ghostAt(x0 - dir * 300, y0);
        await g.wait(dur * 1.3);
        curEl.classList.add('on');
      },
      async drag(id, onto) {
        await g.to(railBtn(id), 0, -4);
        curEl.classList.add('down');
        await g.wait(180);
        const x0 = G.x, y0 = G.y;
        dragBegin(id, { x: x0, y: y0 });
        const r = rectL(railBtn(onto)), tx = r.x + r.w / 2 + 6, ty = r.y + r.h / 2 - 4;
        await anim(t, 950, (e) => {
          const x = x0 + (tx - x0) * e + Math.sin(Math.PI * e) * 34, y = y0 + (ty - y0) * e;
          ghostAt(x, y);
          dragMove({ x, y });
        });
        await g.wait(800);
        curEl.classList.remove('down');
        dragEnd(true);
      }
    };
    return g;
  }
  function stopGhost() {
    G.tok++;
    G.running = false;
    curEl.classList.remove('on', 'down');
    fingers.classList.remove('on');
    showBtn.classList.remove('is-playing');
    if (D) dragEnd(false, true);
  }
  function runGhost(i) {
    const ch = CH[i];
    stopGhost();
    const t = G.tok;
    G.running = true;
    ringOn(null);
    showBtn.classList.add('is-playing');
    const finish = (ok) => {
      if (t === G.tok) { G.running = false; curEl.classList.remove('on', 'down'); fingers.classList.remove('on'); showBtn.classList.remove('is-playing'); }
      return ok;
    };
    if (RM) { ch.end(); return Promise.resolve(finish(true)); }
    curEl.classList.add('on');
    return ch.ghost(ctx(t)).then(() => finish(true), (e) => { if (e !== STOP) console.error(e); return finish(false); });
  }

  /* ---------- chapters ---------- */
  const CH = [
    {
      title: 'Click an icon. Kolom glides there.',
      hint: 'Click <b>Music</b> in the rail — or press <kbd>⌥6</kbd>.',
      done: 'Every window gets an icon. <kbd>⌥1</kbd>–<kbd>⌥9</kbd> jump straight there.',
      reset() { S.focus = 'browser'; S.offset = 0; },
      target: () => railBtn('music'),
      react: (ev) => ev === 'focus',
      end() { focusWin('music'); mark('focus'); },
      async ghost(g) {
        await g.wait(250);
        await g.to(railBtn('music'), 2, -6);
        await g.click(); focusWin('music'); mark('focus');
        await g.wait(1900);
        await g.keys(['⌥', '2'], 250); focusWin('code');
        await g.wait(1700);
      }
    },
    {
      title: 'Swipe. The whole strip slides.',
      hint: 'Swipe sideways with two fingers, or drag the screen. Keep going for the desktop — or press <kbd>⌥D</kbd>.',
      done: 'Past the last column: your desktop. Columns slide off the edge, cleanly.',
      reset() { S.focus = 'browser'; S.offset = 0; },
      target: null,
      react: (ev) => ev === 'desk',
      end() { desktop(); },
      async ghost(g) {
        await g.move(W * 0.68, H * 0.52, 700);
        await g.swipe(colX(3), 620);
        await g.wait(350);
        await g.move(W * 0.68, H * 0.52, 500);
        await g.swipe(deskOff(), 680);
        await g.wait(1300);
        await g.move(W * 0.36, H * 0.52, 600);
        await g.swipe(0, 760);
        await g.wait(700);
        await g.keys(['⌥', 'D'], 200); desktop();
        await g.wait(1900);
      }
    },
    {
      title: 'Drop one on another. They share a column.',
      hint: 'Drag the <b>Notes</b> icon onto <b>Terminal</b> in the rail.',
      done: 'Stacked. Up to three windows share a column — and its width.',
      reset() { S.focus = 'terminal'; S.offset = colX(2); },
      target: () => railBtn('notes'),
      react: (ev) => ev === 'stack',
      end() { moveInto('notes', colOf('terminal')); moveInto('calendar', colOf('terminal')); },
      async ghost(g) {
        await g.wait(200);
        await g.drag('notes', 'terminal');
        await g.wait(1300);
        await g.drag('calendar', 'terminal');
        await g.wait(2000);
      }
    },
    {
      title: 'What’s working hard? One click.',
      hint: 'Click <b>CPU · MEM · NET</b> at the bottom of the rail.',
      done: 'Every app, by CPU and memory, live. Click the readout again to close.',
      reset() { S.focus = 'browser'; S.offset = 0; },
      target: () => resBtn,
      react: (ev) => ev === 'perf',
      end() { setPerf(true); },
      async ghost(g) {
        await g.wait(250);
        await g.to(resBtn, 4, 0);
        await g.click(); setPerf(true);
        await g.wait(1000);
        await g.move(RAIL + PANEL * 0.62, H * 0.56, 900);
        await g.wait(2600);
      }
    },
    {
      title: 'Ask for a layout. Get it.',
      hint: 'Press <kbd>⌥K</kbd> and type — or pick a suggestion.',
      done: 'One sentence, a whole Terminal grid. <b>Undo</b> takes it away.',
      reset() { S.focus = 'code'; S.offset = colX(1); },
      target: null,
      react: (ev) => ev === 'ask',
      end() { makeGrid(3, 2, 6); },
      extras: [['3×2 terminals', () => askRun('3×2 terminals')], ['focus Music', () => askRun('focus Music')], ['show the desktop', () => askRun('show the desktop')], ['Undo', () => undoGrid(), () => !!S.grid]],
      async ghost(g) {
        await g.wait(350);
        await g.keys(['⌥', 'K'], 220); openAsk(false);
        await g.wait(650);
        await g.type('3×2 terminals', 85);
        await g.wait(420);
        await g.keys(['↩'], 60);
        await submit(askIn.value);
        await g.wait(3000);
      }
    },
    {
      title: 'Pause, and everything goes back.',
      hint: 'Click Kolom’s menu bar icon and choose <b>Pause and restore windows</b>.',
      mid: 'Every window is back where you had it. Now <b>Resume</b>.',
      done: 'Columns again. Quitting restores everything too — and if Kolom ever crashes, a watchdog does.',
      reset() { S.focus = 'browser'; S.offset = 0; },
      target: () => mbKolom,
      react: (ev) => ev === 'resume' ? true : ev === 'pause' ? 'mid' : false,
      end() { pause(); },
      extras: [['Pause', () => (S.paused ? resume() : pause()), null, () => (S.paused ? 'Resume' : 'Pause')]],
      async ghost(g) {
        await g.wait(250);
        await g.to(mbKolom, 0, 2);
        await g.click(); toggleMenu(true);
        await g.wait(500);
        await g.to(menuPause, -70, 0, 520);
        menuPause.classList.add('hot');
        await g.click();
        await g.wait(120);
        menuPause.classList.remove('hot'); toggleMenu(false); pause();
        await g.wait(2900);
        await g.to(toastBtn);
        toastBtn.classList.add('hot');
        await g.click();
        toastBtn.classList.remove('hot'); resume();
        await g.wait(2000);
      }
    }
  ];

  /* ---------- caption ---------- */
  const titleEl = dm.querySelector('.dm-title'), hintEl = dm.querySelector('.dm-hint'), hintTxt = hintEl.querySelector('span');
  const showBtn = dm.querySelector('.dm-show'), xsEl = dm.querySelector('.dm-xs'), aiEl = dm.querySelector('.dm-ai');
  const chBtns = Array.from(dm.querySelectorAll('.dm-ch'));
  let cur = 0;
  function setHint(html, done) { hintTxt.innerHTML = html; hintEl.classList.toggle('done', !!done); }
  function mark(ev) {
    const res = CH[cur].react(ev);
    if (!res) return;
    if (!G.running) S.touched = true;
    ringOn(null);
    if (res === 'mid') setHint(CH[cur].mid, false);
    else setHint(CH[cur].done, true);
  }
  let xsSig = '';
  function renderExtras() {
    const ex = CH[cur].extras || [];
    const sig = cur + ':' + ex.map((x) => (x[2] && !x[2]() ? '-' : '+') + (x[3] ? x[3]() : x[0])).join(',');
    if (sig === xsSig) return;
    xsSig = sig;
    xsEl.replaceChildren(...ex.map((x, i) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'dm-x' + (cur === 4 && i < 3 ? '' : ' lime');
      b.textContent = x[3] ? x[3]() : x[0];
      b.hidden = !!(x[2] && !x[2]());
      b.addEventListener('click', () => { S.touched = true; x[1](); });
      return b;
    }));
  }

  /* ---------- selecting chapters, idle ghost and the tour ---------- */
  let idleT = 0, engagedFlag = false, inView = false;
  const T = { tok: 0, on: false };
  function freshState() {
    S.epoch++;
    stopTween('offset'); stopTween('b');
    if (D) dragEnd(false, true);
    Object.keys(S.wins).forEach((id) => { if (!CAT.some((c) => c[0] === id)) { S.wins[id].el.remove(); delete S.wins[id]; } });
    strip.querySelectorAll('.win.leaving').forEach((e) => e.remove());
    CAT.forEach((c) => { if (!S.wins[c[0]]) addWin(c[0], c[1], c[2], c[3]); });
    Object.keys(S.wins).forEach((id) => {
      const el = S.wins[id].el;
      el.classList.remove('spawn', 'lifting', 'flash', 'leaving');
      el.style.zIndex = '';
      el.style.transitionDelay = '';
    });
    S.cols = CAT.map((c) => ({ w: sc(c[4]), ids: [c[0]] }));
    S.paused = false; S.perf = false; S.ask = false; S.grid = null; S.preview = null;
    scene.classList.remove('paused', 'perf-on', 'ask-on', 'menu-on', 'guide-on', 'ask-busy');
    resBtn.classList.remove('on'); helpBtn.classList.remove('on'); mbKolom.classList.remove('on');
    menuPause.classList.remove('hot'); toastBtn.classList.remove('hot');
    setLook('wallpaper');
    askIn.value = '';
    setStatus('');
    hideToast();
    gridBox.classList.remove('on');
    dropLab.classList.remove('on');
    dragAv.classList.remove('on', 'back');
    keysEl.classList.remove('on');
  }
  let naRaf = 0;
  function resetScene() {
    scene.classList.add('no-anim');
    freshState();
    CH[cur].reset();
    S.b = baseT();
    lastDesk = atDesk();
    scene.classList.toggle('at-desk', lastDesk);
    railSig = '';
    apply();
    layout();
    if (S.perf) renderPerf();
    void scene.offsetWidth;
    cancelAnimationFrame(naRaf);
    naRaf = requestAnimationFrame(() => { naRaf = requestAnimationFrame(() => scene.classList.remove('no-anim')); });
    ghostAt(W * 0.62, H * 0.7);
    S.touched = false;
    setHint(CH[cur].hint, false);
    ringOn(CH[cur].target ? CH[cur].target() : null);
  }
  function select(i, why) {
    cur = i;
    stopGhost();
    clearTimeout(idleT);
    chBtns.forEach((b, j) => b.setAttribute('aria-pressed', j === i ? 'true' : 'false'));
    titleEl.textContent = CH[i].title;
    aiEl.classList.toggle('on', i === 4);
    xsSig = '';
    resetScene();
    if (why === 'user') armIdle(1500);
  }
  function armIdle(ms) {
    clearTimeout(idleT);
    idleT = setTimeout(() => { if (!S.touched && !G.running && inView && !document.hidden) runGhost(cur); }, ms);
  }
  function progress(i, dur) {
    chBtns.forEach((b, j) => {
      const u = b.querySelector('u');
      b.classList.add('is-touring');
      u.style.transition = 'none';
      u.style.width = '0';
      if (j === i) { void u.offsetWidth; u.style.transition = `width ${dur}ms linear`; u.style.width = '100%'; }
    });
  }
  const DUR = [7600, 12400, 9800, 7400, 9600, 10800];
  function stopTour() { T.tok++; T.on = false; chBtns.forEach((b) => b.classList.remove('is-touring')); }
  async function tour() {
    if (RM || engagedFlag || T.on) return;
    const t = ++T.tok;
    T.on = true;
    for (;;) {
      select(cur, 'tour');
      progress(cur, DUR[cur]);
      await sleep(900);
      if (t !== T.tok) return;
      const ok = await runGhost(cur);
      if (t !== T.tok || !ok) return;
      await sleep(2200);
      if (t !== T.tok) return;
      cur = (cur + 1) % CH.length;
    }
  }
  function engage() { if (!engagedFlag) { engagedFlag = true; stopTour(); } }
  function onUser(e) {
    if (e.type === 'keydown' && (e.key === 'Tab' || e.key === 'Shift' || e.key === 'Meta')) return;
    engage();
    clearTimeout(idleT);
    if (G.running) { stopGhost(); resetScene(); }
  }
  dm.addEventListener('pointerdown', onUser, true);
  dm.addEventListener('keydown', onUser, true);

  chBtns.forEach((b, i) => b.addEventListener('click', () => select(i, 'user')));
  showBtn.addEventListener('click', () => { engage(); clearTimeout(idleT); resetScene(); runGhost(cur); });

  /* ---------- pointer input on the screen ---------- */
  let P = null;
  const L = (e) => { const f = scene.getBoundingClientRect(); return { x: (e.clientX - f.left) / s, y: (e.clientY - f.top) / s }; };
  scene.addEventListener('pointerdown', (e) => {
    if (e.button !== 0) return;
    const tg = e.target;
    if (!tg.closest('.d-menu, .mb-kolom')) { scene.classList.remove('menu-on'); mbKolom.classList.remove('on'); }
    if (!tg.closest('.d-guide, .r-help')) { scene.classList.remove('guide-on'); helpBtn.classList.remove('on'); }
    if (S.ask && !tg.closest('.d-ask')) closeAsk();
    if (tg !== askIn) fit.focus({ preventScroll: true });
    const p = L(e);
    const rb = tg.closest('.r-ic');
    if (rb) {
      e.preventDefault();
      P = { kind: 'icon', id: rb.dataset.id, x0: p.x, y0: p.y, moved: false };
      scene.setPointerCapture(e.pointerId);
      return;
    }
    if (tg.closest('button, input, .d-ask, .d-perf, .d-menu, .d-guide, .d-toast, .d-mb, .d-rail') || S.paused) return;
    const win = tg.closest('.win');
    P = { kind: 'strip', x0: p.x, y0: p.y, o0: S.offset, moved: false, win: win && win.dataset.id, samples: [[performance.now(), p.x]] };
    scene.setPointerCapture(e.pointerId);
  });
  scene.addEventListener('pointermove', (e) => {
    if (!P) return;
    const p = L(e), dx = p.x - P.x0, dy = p.y - P.y0;
    if (P.kind === 'icon') {
      if (!P.moved && Math.hypot(dx, dy) > 5) { P.moved = dragBegin(P.id, p); if (!P.moved) { P = null; return; } S.touched = true; ringOn(null); }
      if (P.moved) dragMove(p);
      return;
    }
    if (!P.moved) {
      if (Math.abs(dx) > 6 && Math.abs(dx) > Math.abs(dy)) { P.moved = true; stopTween('offset'); P.o0 = S.offset + dx; S.touched = true; }
      else return;
    }
    S.offset = rub(P.o0 - dx);
    apply();
    P.samples.push([performance.now(), p.x]);
    if (P.samples.length > 6) P.samples.shift();
  });
  const endPointer = (e, cancel) => {
    if (!P) return;
    const p0 = P;
    P = null;
    if (p0.kind === 'icon') {
      if (p0.moved) dragEnd(!cancel);
      else if (!cancel) { focusWin(p0.id); mark('focus'); }
      return;
    }
    if (p0.moved) {
      const a = p0.samples[0], b = p0.samples[p0.samples.length - 1];
      const dt = b[0] - a[0];
      const v = dt > 0 && performance.now() - b[0] < 90 ? -(b[1] - a[1]) / dt : 0;
      settle(cancel ? 0 : clamp(v, -6, 6));
    } else if (!cancel && p0.win && S.wins[p0.win]) { focusWin(p0.win); mark('focus'); }
  };
  scene.addEventListener('pointerup', (e) => endPointer(e, false));
  scene.addEventListener('pointercancel', (e) => endPointer(e, true));
  scene.addEventListener('lostpointercapture', (e) => { if (P) endPointer(e, true); });

  // Keyboard activation of rail icons (pointer clicks are handled above).
  scene.addEventListener('click', (e) => {
    const rb = e.target.closest('.r-ic');
    if (rb && e.detail === 0) { focusWin(rb.dataset.id); mark('focus'); }
  });
  resBtn.addEventListener('click', () => { S.touched = true; setPerf(!S.perf); });
  helpBtn.addEventListener('click', () => toggleGuide());
  mbKolom.addEventListener('click', () => toggleMenu());
  toastBtn.addEventListener('click', () => { const cb = toastCb; if (cb) cb(); });
  menu.addEventListener('click', (e) => {
    const b = e.target.closest('[data-m]');
    if (!b) return;
    const m = b.dataset.m;
    toggleMenu(false);
    if (m === 'pause') { if (S.paused) resume(); else pause(); }
    else if (m === 'ask') openAsk(true);
    else if (m === 'prev') { stepCol(-1); mark('focus'); }
    else if (m === 'next') { stepCol(1); mark('focus'); }
    else if (m === 'desk') desktop();
    else if (m === 'perf') setPerf(true);
    else if (m === 'guide') toggleGuide(true);
  });
  q('.ask-chips').addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b) { askIn.value = b.textContent; submit(b.textContent); }
  });

  // Two-finger swipe, or ⌥/⇧ + wheel with a mouse. Plain vertical scrolling stays with the page.
  let wheel = null, wheelT = 0;
  fit.addEventListener('wheel', (e) => {
    let dx = e.deltaX;
    const dy = e.deltaY, mod = e.altKey || e.shiftKey;
    if (mod && Math.abs(dy) > Math.abs(dx)) dx = dy;
    else if (Math.abs(dx) <= Math.abs(dy)) return;
    if (S.paused) return;
    e.preventDefault();
    onUser(e);
    S.touched = true;
    ringOn(null);
    if (e.deltaMode === 1) dx *= 16;
    if (!wheel) { stopTween('offset'); wheel = { raw: S.offset }; }
    wheel.raw += dx / s;
    S.offset = rub(wheel.raw);
    apply();
    clearTimeout(wheelT);
    wheelT = setTimeout(() => { wheel = null; settle(0); }, 150);
  }, { passive: false });

  fit.addEventListener('keydown', (e) => {
    if (e.target === askIn) {
      if (e.key === 'Enter') { e.preventDefault(); submit(askIn.value); }
      else if (e.key === 'Escape') { e.preventDefault(); closeAsk(); }
      return;
    }
    if (e.target.closest && e.target.closest('button') && (e.key === 'Enter' || e.key === ' ')) return;
    const c = e.code;
    let keys = null, done = true;
    if (e.altKey && e.ctrlKey && !e.metaKey && c === 'KeyK') { keys = ['⌃', '⌥', 'K']; toast('⌃⌥K opens Kolom’s move palette: before, after, above, below, or another display.', null, null, false, 3600); }
    else if (e.altKey && !e.ctrlKey && !e.metaKey) {
      if (c === 'ArrowLeft') { keys = ['⌥', '←']; stepCol(-1); mark('focus'); }
      else if (c === 'ArrowRight') { keys = ['⌥', '→']; stepCol(1); mark('focus'); }
      else if (/^Digit[1-9]$/.test(c)) { const n = +c.slice(5), id = order()[n - 1]; keys = ['⌥', String(n)]; if (id) { focusWin(id); mark('focus'); } }
      else if (c === 'KeyD') { keys = ['⌥', 'D']; desktop(); }
      else if (c === 'KeyK') { keys = ['⌥', 'K']; if (S.ask) closeAsk(); else openAsk(true); }
      else done = false;
    } else if (!e.ctrlKey && !e.metaKey && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) { stepCol(e.key === 'ArrowLeft' ? -1 : 1); mark('focus'); }
    else if (e.key === 'Escape') { closeAll(); if (S.perf) setPerf(false); }
    else done = false;
    if (done) { e.preventDefault(); S.touched = true; if (keys) showKeys(keys); }
  });

  /* ---------- fit to the frame ---------- */
  function fitScene() {
    const w = fit.clientWidth;
    if (!w) return;
    const compact = w < 620, nW = compact ? 1080 : 1440, nH = compact ? 720 : 900;
    const changed = nW !== W || !scene.style.width;
    if (changed) {
      W = nW; H = nH;
      scene.style.width = W + 'px';
      scene.style.height = H + 'px';
      fit.style.setProperty('--ar', String(W / H));
    }
    s = w / W;
    k = clamp(0.7 / s, 1, 3);
    scene.style.transform = `scale(${s})`;
    if (changed) { stopGhost(); resetScene(); }
    else { posRing(); ghostAt(G.x, G.y); }
  }
  fitScene();
  if ('ResizeObserver' in window) new ResizeObserver(fitScene).observe(fit);
  else window.addEventListener('resize', fitScene);

  /* ---------- in view: the tour and the live numbers ---------- */
  if ('IntersectionObserver' in window) {
    new IntersectionObserver((es) => {
      const vis = es[es.length - 1].isIntersecting;
      if (vis === inView) return;
      inView = vis;
      if (vis) { if (!engagedFlag) tour(); }
      else if (T.on || G.running) { stopTour(); stopGhost(); resetScene(); }
    }, { threshold: 0.6 }).observe(fit);
  } else inView = true;
  setInterval(() => {
    if (!inView || document.hidden) return;
    tick++;
    if (S.perf) renderPerf(); else renderReadout();
  }, 1300);

  window.KolomDemo = {
    play(i) { engage(); select(i, 'user'); armIdle(1900); },
    state: S,
    chapter: () => cur
  };
})();
