/* Kolom site — self-made app icons and window contents for the simulated desk.
   Every icon and window here is drawn by hand for this page: no real product
   logos, screenshots or trademarks. Sizes are in logical display points. */
(function () {
  'use strict';

  const ICONS = {
    terminal: `<svg viewBox="0 0 40 40" aria-hidden="true"><defs><linearGradient id="i-t" x2="0" y2="1"><stop stop-color="#3a403c"/><stop offset="1" stop-color="#171b19"/></linearGradient></defs><rect x="1" y="1" width="38" height="38" rx="9.5" fill="url(#i-t)"/><rect x="1.5" y="1.5" width="37" height="37" rx="9" fill="none" stroke="#fff" stroke-opacity=".14"/><path d="m10.5 14 6.5 6-6.5 6" fill="none" stroke="#d6f56a" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/><path d="M20.5 27h9" stroke="#eef2ea" stroke-width="2.8" stroke-linecap="round"/></svg>`,
    browser: `<svg viewBox="0 0 40 40" aria-hidden="true"><defs><linearGradient id="i-b" x2="0" y2="1"><stop stop-color="#7fd3ff"/><stop offset="1" stop-color="#2f6fe0"/></linearGradient></defs><rect x="1" y="1" width="38" height="38" rx="9.5" fill="url(#i-b)"/><circle cx="20" cy="20" r="11.5" fill="none" stroke="#fff" stroke-width="2"/><ellipse cx="20" cy="20" rx="5" ry="11.5" fill="none" stroke="#fff" stroke-width="1.8"/><path d="M8.8 16.2h22.4M8.8 23.8h22.4" stroke="#fff" stroke-width="1.8"/></svg>`,
    code: `<svg viewBox="0 0 40 40" aria-hidden="true"><defs><linearGradient id="i-c" x2="1" y2="1"><stop stop-color="#2b3350"/><stop offset="1" stop-color="#121628"/></linearGradient><linearGradient id="i-c2" x2="1"><stop stop-color="#8be9ff"/><stop offset="1" stop-color="#b9a3ff"/></linearGradient></defs><rect x="1" y="1" width="38" height="38" rx="9.5" fill="url(#i-c)"/><path d="m15 13-7 7 7 7M25 13l7 7-7 7" fill="none" stroke="url(#i-c2)" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/><path d="m22 11-4 18" stroke="#ffc46b" stroke-width="2.4" stroke-linecap="round"/></svg>`,
    notes: `<svg viewBox="0 0 40 40" aria-hidden="true"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="#fffdf4"/><path d="M10.5 1h19A9.5 9.5 0 0 1 39 10.5V13H1v-2.5A9.5 9.5 0 0 1 10.5 1" fill="#ffd24a"/><path d="M7 20h26M7 26h26M7 32h17" stroke="#d9d6c8" stroke-width="1.4"/><rect x="1.5" y="1.5" width="37" height="37" rx="9" fill="none" stroke="#000" stroke-opacity=".08"/></svg>`,
    music: `<svg viewBox="0 0 40 40" aria-hidden="true"><defs><linearGradient id="i-m" x2="1" y2="1"><stop stop-color="#ff8a6b"/><stop offset="1" stop-color="#e2335a"/></linearGradient></defs><rect x="1" y="1" width="38" height="38" rx="9.5" fill="url(#i-m)"/><path d="M17 27.5V12.5l12-2.6v14.8" fill="none" stroke="#fff" stroke-width="2.4" stroke-linejoin="round"/><circle cx="14" cy="27.5" r="3.6" fill="#fff"/><circle cx="26" cy="24.7" r="3.6" fill="#fff"/></svg>`,
    chat: `<svg viewBox="0 0 40 40" aria-hidden="true"><defs><linearGradient id="i-h" x2="0" y2="1"><stop stop-color="#5ee0b0"/><stop offset="1" stop-color="#16a37a"/></linearGradient></defs><rect x="1" y="1" width="38" height="38" rx="9.5" fill="url(#i-h)"/><path d="M10 13.5a4 4 0 0 1 4-4h12a4 4 0 0 1 4 4v8a4 4 0 0 1-4 4h-7l-5.5 4.5V25.5A4 4 0 0 1 10 21.5Z" fill="#fff"/><circle cx="15.5" cy="17.5" r="1.6" fill="#16a37a"/><circle cx="20" cy="17.5" r="1.6" fill="#16a37a"/><circle cx="24.5" cy="17.5" r="1.6" fill="#16a37a"/></svg>`,
    mail: `<svg viewBox="0 0 40 40" aria-hidden="true"><defs><linearGradient id="i-e" x2="0" y2="1"><stop stop-color="#6fb3ff"/><stop offset="1" stop-color="#2160d6"/></linearGradient></defs><rect x="1" y="1" width="38" height="38" rx="9.5" fill="url(#i-e)"/><rect x="8" y="12" width="24" height="17" rx="2.6" fill="#fff"/><path d="m8.8 13.2 11.2 8.6 11.2-8.6" fill="none" stroke="#2160d6" stroke-width="1.8" stroke-linejoin="round"/></svg>`,
    canvas: `<svg viewBox="0 0 40 40" aria-hidden="true"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="#1b1b1f"/><circle cx="15" cy="15" r="6" fill="#ff7a45"/><rect x="20" y="9" width="11" height="11" rx="2.5" fill="#d4ff4a"/><path d="M10 31 17 21l7 10Z" fill="#7cc4ff"/><circle cx="27.5" cy="26.5" r="4.5" fill="none" stroke="#fff" stroke-width="2"/></svg>`,
    calendar: `<svg viewBox="0 0 40 40" aria-hidden="true"><rect x="1" y="1" width="38" height="38" rx="9.5" fill="#fff"/><path d="M10.5 1h19A9.5 9.5 0 0 1 39 10.5V12H1v-1.5A9.5 9.5 0 0 1 10.5 1" fill="#ff5a4e"/><text x="20" y="31" text-anchor="middle" font-family="-apple-system,Helvetica,Arial,sans-serif" font-size="17" font-weight="600" fill="#1b1d1a">26</text><rect x="1.5" y="1.5" width="37" height="37" rx="9" fill="none" stroke="#000" stroke-opacity=".08"/></svg>`,
    folder: `<svg viewBox="0 0 40 40" aria-hidden="true"><path d="M4 11a3 3 0 0 1 3-3h8l3 3h15a3 3 0 0 1 3 3v17a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3Z" fill="#6fb7ff"/><path d="M4 15h32v16a3 3 0 0 1-3 3H7a3 3 0 0 1-3-3Z" fill="#9fd0ff"/></svg>`,
    image: `<svg viewBox="0 0 40 40" aria-hidden="true"><rect x="6" y="4" width="28" height="32" rx="3" fill="#fff"/><rect x="9" y="8" width="22" height="16" rx="1.5" fill="#ffb58a"/><path d="m9 24 7-8 5 5 3-3 7 6Z" fill="#e2603a"/><path d="M10 29h20M10 32h12" stroke="#ccc" stroke-width="1.4"/></svg>`
  };

  const APPS = {
    terminal: { name: 'Terminal', menus: ['Shell', 'Edit', 'View', 'Window', 'Help'] },
    browser: { name: 'Browser', menus: ['File', 'Edit', 'View', 'History', 'Window'] },
    code: { name: 'Code', menus: ['File', 'Edit', 'Selection', 'View', 'Go', 'Run'] },
    notes: { name: 'Notes', menus: ['File', 'Edit', 'Format', 'View', 'Window'] },
    music: { name: 'Music', menus: ['File', 'Edit', 'Song', 'View', 'Controls'] },
    chat: { name: 'Chat', menus: ['File', 'Edit', 'View', 'Window', 'Help'] },
    mail: { name: 'Mail', menus: ['File', 'Edit', 'View', 'Mailbox', 'Message'] },
    canvas: { name: 'Canvas', menus: ['File', 'Edit', 'Object', 'Arrange', 'View'] },
    calendar: { name: 'Calendar', menus: ['File', 'Edit', 'View', 'Window', 'Help'] }
  };

  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  const TERM = {
    build: [
      ['p', '~/kolom', 'swift build -c release'],
      ['o', 'Building for production...'],
      ['o', '[38/42] Compiling KolomCore Workspace.swift'],
      ['o', '[41/42] Compiling Kolom Controller.swift'],
      ['g', '[42/42] Linking Kolom'],
      ['g', 'Build complete! (8.31s)'],
      ['p', '~/kolom', './scripts/test.sh'],
      ['o', 'geometry ........................ ok'],
      ['o', 'stacks .......................... ok'],
      ['o', 'grids ........................... ok'],
      ['o', 'display memory .................. ok'],
      ['o', 'recovery planning ............... ok'],
      ['g', 'All core checks passed'],
      ['p', '~/kolom', '']
    ],
    server: [
      ['p', '~/site', 'npm run dev'],
      ['o', '> site@2.4.0 dev'],
      ['o', '> vite --port 3000'],
      ['g', '  ready in 412 ms'],
      ['o', '  ➜  Local:   http://localhost:3000/'],
      ['o', '  ➜  Network: use --host to expose'],
      ['o', '12:04:31 [hmr] update /src/Hero.tsx'],
      ['o', '12:04:52 [hmr] update /src/Pricing.tsx'],
      ['o', '12:05:10 [hmr] update /src/styles.css'],
      ['p', '', '']
    ],
    state: [
      ['p', '~', 'kolomctl state | jq .displays[].name'],
      ['o', '"Built-in Display"'],
      ['o', '"Wide 34-inch"'],
      ['o', '"Display 27-inch"'],
      ['p', '~', 'kolomctl plan-grid --columns 6 --rows 3 --display 2'],
      ['o', '{ "cellWidth": 260, "cellHeight": 210.7,'],
      ['o', '  "fitsCurrentSizingLimits": true, ... }'],
      ['p', '~', '']
    ],
    logs: [
      ['p', '~/api', 'tail -f logs/worker.log'],
      ['o', 'INFO  queue=mail  jobs=12  p95=84ms'],
      ['o', 'INFO  queue=sync  jobs=3   p95=41ms'],
      ['w', 'WARN  retry upstream=calendar attempt=2'],
      ['o', 'INFO  queue=mail  jobs=9   p95=77ms'],
      ['g', 'OK    upstream=calendar recovered'],
      ['o', 'INFO  queue=index jobs=27  p95=120ms'],
      ['o', 'INFO  queue=mail  jobs=4   p95=69ms']
    ],
    htop: [
      ['p', '~', 'git log --oneline -6'],
      ['y', 'a41c9e2 Keep displays apart while managing'],
      ['y', '7be0d13 Route pointer across the real desk'],
      ['y', '3f2c771 Restore wallpaper from watchdog'],
      ['y', 'c09a8d5 Scope undo to its own grid'],
      ['y', '91e44b0 Rail: overlapping stack icons'],
      ['y', '5d2e6aa Desktop tail at 110% viewport'],
      ['p', '~', '']
    ]
  };

  function terminal(win) {
    const lines = TERM[win.variant] || TERM.build;
    const body = lines.map((l) => {
      if (l[0] === 'p') {
        return `<div class="t-l"><span class="t-dir">${esc(l[1] || '~')}</span> <span class="t-pr">❯</span> ${esc(l[2])}${l[2] === '' ? '<span class="t-cur"></span>' : ''}</div>`;
      }
      return `<div class="t-l t-${l[0]}">${esc(l[1])}</div>`;
    }).join('');
    return `<div class="app app-term">${body}</div>`;
  }

  function gridTerminal(win) {
    const n = win.cell || 1;
    const cmds = ['agent --resume', 'npm test -- --watch', 'cargo run', 'tail -f server.log', 'htop', 'git status', 'make dev', 'pytest -q'];
    const c = cmds[(n - 1) % cmds.length];
    return `<div class="app app-term"><div class="t-l t-o">Last login: Sun Oct 26 09:41 on ttys00${n}</div><div class="t-l"><span class="t-dir">~/work</span> <span class="t-pr">❯</span> ${esc(c)}</div><div class="t-l t-g">session ${n} ready</div><div class="t-l"><span class="t-dir">~/work</span> <span class="t-pr">❯</span> <span class="t-cur"></span></div></div>`;
  }

  function browser(win) {
    const v = win.variant || 'docs';
    const url = { docs: 'ckluis.github.io/kolom', issues: 'github.com/ckluis/kolom/issues', local: 'localhost:3000', article: 'field-notes.blog/strips', shop: 'store.example/desk-lamp' }[v];
    const tabs = { docs: ['Columns · Kolom docs', 'Display staircase'], issues: ['Issues · kolom', 'Pull requests'], local: ['localhost:3000', 'Design tokens'], article: ['On scrolling desktops', 'Reading list'], shop: ['Desk lamp, brass', 'Cart (2)'] }[v];
    let page = '';
    if (v === 'docs') {
      page = `<div class="b-docs"><aside><b>Getting started</b><i>Install</i><i class="on">Columns &amp; stacks</i><i>Displays</i><i>Keyboard</i><i>Agents</i><b>Reference</b><i>kolomctl</i><i>MCP tools</i></aside><article><small>Guide</small><h3>Columns &amp; stacks</h3><p>Every window gets a column. Up to three windows can share one, and they share its width.</p><div class="b-fig"><span></span><span></span><span class="tall"></span><span></span></div><p>Drag a column edge to resize it. Drag the divider between stacked windows to change their heights.</p><p class="dim">Next: Displays →</p></article></div>`;
    } else if (v === 'issues') {
      const rows = [['Scroll feel at the seam between two displays', 'staircase', 'g'], ['Remember widths after reconnect', 'displays', 'b'], ['Rail: show stacked icons for grids', 'rail', 'y'], ['Palette: fuzzy match app titles', 'palette', 'b'], ['Dashboard: sort children by memory', 'performance', 'g'], ['Agent: report partial grid failures', 'agents', 'y']];
      page = `<div class="b-issues"><div class="b-ih"><b>Issues</b><span>38 open</span><span class="dim">212 closed</span><em>New issue</em></div>${rows.map((r, i) => `<div class="b-ir"><i class="${i % 3 === 1 ? 'done' : ''}"></i><div><b>${esc(r[0])}</b><small>#${412 - i * 7} opened ${i + 1} days ago</small></div><u class="tag-${r[2]}">${r[1]}</u></div>`).join('')}</div>`;
    } else if (v === 'local') {
      page = `<div class="b-local"><nav><b>Northwind</b><span>Overview</span><span>Orders</span><span>Customers</span><em>Upgrade</em></nav><div class="b-kpis"><div><small>Revenue</small><b>$84.2k</b><u>+12.4%</u></div><div><small>Orders</small><b>1,284</b><u>+3.1%</u></div><div><small>Refunds</small><b>0.8%</b><u class="dn">−0.2%</u></div></div><div class="b-chart"><svg viewBox="0 0 300 90" preserveAspectRatio="none"><path d="M0 70 C30 60 45 66 70 50 S120 30 150 38 S210 18 240 22 S280 8 300 10 L300 90 L0 90Z" fill="#3b82f6" fill-opacity=".14"/><path d="M0 70 C30 60 45 66 70 50 S120 30 150 38 S210 18 240 22 S280 8 300 10" fill="none" stroke="#3b82f6" stroke-width="2.4"/></svg></div><div class="b-rows"><span></span><span></span><span></span></div></div>`;
    } else if (v === 'article') {
      page = `<div class="b-article"><small>FIELD NOTES · 6 MIN READ</small><h3>The desktop that scrolls sideways</h3><p class="lede">What happens when every window gets a permanent place — and the screen becomes a window onto a longer strip.</p><div class="b-hero"></div><p>The idea is old: paper on a long table, a reader’s scroll, a film strip. Tiling managers on Linux made it fast. On the Mac, it has mostly meant overlapping piles.</p><p>A strip changes the question from “where did that window go?” to “how far along is it?”</p></div>`;
    } else {
      page = `<div class="b-article"><small>LIGHTING</small><h3>Brass desk lamp</h3><div class="b-hero lamp"></div><p>Warm 2700K, dimmable. Ships in 2 days.</p></div>`;
    }
    return `<div class="app app-browser"><div class="b-bar"><div class="b-tabs">${tabs.map((t, i) => `<span class="${i === 0 ? 'on' : ''}">${esc(t)}</span>`).join('')}</div><div class="b-url"><i></i>${esc(url)}</div></div><div class="b-page">${page}</div></div>`;
  }

  function code(win) {
    const files = ['Sources', '  KolomCore', '    Workspace.swift', '    DisplayArrangement.swift', '    DisplayMemory.swift', '  Kolom', '    Controller.swift', '    PointerRouter.swift', '    Rail.swift', 'Tests'];
    const k = (s) => `<span class="k">${s}</span>`, f = (s) => `<span class="f">${s}</span>`, s = (x) => `<span class="s">${x}</span>`, c = (x) => `<span class="c">${x}</span>`, n = (x) => `<span class="n">${x}</span>`, t = (x) => `<span class="ty">${x}</span>`;
    const lines = win.variant === 'stairs' ? [
      c('/// Widest first along x, each top at the previous bottom.'),
      `${k('private func')} ${f('displayStaircase')}(_ frames: [${t('UInt32')}: ${t('CGRect')}]) {`,
      `  ${k('let')} ordered = frames.keys.${f('sorted')} { frames[$0]!.width > frames[$1]!.width }`,
      `  ${k('var')} x = ${n('0.0')}, y = ${n('0.0')}`,
      `  ${k('for')} (index, id) ${k('in')} ordered.${f('enumerated')}() {`,
      `    ${k('if')} index > ${n('0')} { y -= frames[id]!.height }`,
      `    result[id] = ${t('CGRect')}(x: x, y: y, size: frames[id]!.size)`,
      `    x += frames[id]!.width`,
      '  }',
      '}',
      '',
      c('// The desk stays authoritative for pointer crossings.'),
      `router.${f('update')}(technical: staircase, desk: desk)`
    ] : [
      `${k('public mutating func')} ${f('reveal')}(_ id: ${t('String')}, viewportWidth: ${t('Double')}) {`,
      `  ${k('guard let')} c = ${f('columnIndex')}(id) ${k('else')} { ${k('return')} }`,
      `  ${k('let')} start = columns.${f('prefix')}(c).${f('reduce')}(${n('0')}) { $0 + $1.width + gap }`,
      `  ${k('let')} end = start + columns[c].width`,
      `  ${k('if')} start < offset {`,
      '    offset = start',
      `  } ${k('else if')} end > offset + viewportWidth {`,
      '    offset = end - viewportWidth',
      '  }',
      `  ${f('clampOffset')}(viewportWidth: viewportWidth)`,
      '  focus = id',
      '}',
      '',
      c('// A stack holds up to three windows.'),
      `${k('if')} columns[dest].tiles.count >= ${n('3')} { ${k('return false')} }`
    ];
    return `<div class="app app-code"><aside>${files.map((x, i) => `<i class="${i === (win.variant === 'stairs' ? 3 : 2) ? 'on' : ''}">${esc(x).replace(/ /g, '&nbsp;')}</i>`).join('')}</aside><div class="cd"><div class="cd-tabs"><span class="on">${win.variant === 'stairs' ? 'DisplayArrangement.swift' : 'Workspace.swift'}</span><span>Controller.swift</span></div>${lines.map((l, i) => `<div class="cl"><em>${i + 41}</em>${l || '&nbsp;'}</div>`).join('')}</div></div>`;
  }

  function notes(win) {
    const v = win.variant || 'launch';
    const list = [['Launch checklist', 'Today'], ['Desk setup', 'Yesterday'], ['Reading list', 'Fri'], ['Ideas', 'Oct 18']];
    const body = v === 'launch'
      ? `<h3>Launch checklist</h3><p class="dim">Sunday, 26 October</p><ul><li class="x">Record the staircase demo</li><li class="x">Write INSTALL-WITH-AN-AGENT.md</li><li class="x">Test unplug / replug on the KVM</li><li>Post to the forum</li><li>Answer every issue on day one</li></ul>`
      : `<h3>Desk setup</h3><p class="dim">Three displays, one strip each</p><ul><li class="x">27-inch on the left</li><li class="x">34-inch wide in the middle</li><li>Laptop on the stand</li></ul><p>Keep displays apart while managing: on.</p>`;
    return `<div class="app app-notes"><aside>${list.map((l, i) => `<div class="${(v === 'launch' ? 0 : 1) === i ? 'on' : ''}"><b>${l[0]}</b><small>${l[1]}</small></div>`).join('')}</aside><article>${body}</article></div>`;
  }

  function music(win) {
    const tracks = [['Low Tide, High Desk', '3:41'], ['Column Seven', '4:12'], ['Parallax', '2:58'], ['Slow Scroll', '5:06'], ['Soft Edges', '3:33']];
    return `<div class="app app-music"><div class="mu-top"><div class="mu-art"></div><div class="mu-meta"><small>ALBUM</small><h3>Night Shift Tapes</h3><p>The Quiet Grid · 2026</p><div class="mu-btns"><span class="play">▶ Play</span><span>Shuffle</span></div></div></div><div class="mu-list">${tracks.map((t, i) => `<div class="${i === 1 ? 'on' : ''}"><em>${i + 1}</em><b>${t[0]}</b><small>${t[1]}</small></div>`).join('')}</div><div class="mu-bar"><i></i><span>Column Seven</span><u><s></s></u></div></div>`;
  }

  function chat(win) {
    const msgs = [['MK', '#7c9cff', 'Maya', 'Did the strip survive the KVM switch?'], ['JD', '#ff8a65', 'Jonas', 'Yes. Unplugged the 34, everything landed on the laptop.'], ['JD', '#ff8a65', 'Jonas', 'Plugged it back in, columns went straight home.'], ['MK', '#7c9cff', 'Maya', 'That’s the demo.'], ['AS', '#4fd1a5', 'Ari', 'Shipping the site tonight ✓']];
    return `<div class="app app-chat"><aside><b>Studio</b><i class="on"># launch</i><i># design</i><i># native</i><i># random</i><b>Direct</b><i>Maya</i><i>Jonas</i></aside><div class="ch"><div class="ch-h"># launch <small>5 members</small></div>${msgs.map((m) => `<div class="msg"><span style="background:${m[1]}">${m[0]}</span><div><b>${m[2]}</b><p>${esc(m[3])}</p></div></div>`).join('')}<div class="ch-in">Message #launch</div></div></div>`;
  }

  function mail(win) {
    const rows = [['Studio Lamp Co.', 'Your order has shipped', '9:12'], ['Maya K.', 'Re: display staircase video', '8:40'], ['Calendar', 'Design review moved to 3 pm', 'Sat'], ['Field Notes', 'This week: scrolling desktops', 'Fri']];
    return `<div class="app app-mail"><div class="ml-list">${rows.map((r, i) => `<div class="${i === 1 ? 'on' : ''}"><b>${r[0]}</b><small>${r[2]}</small><p>${r[1]}</p></div>`).join('')}</div><article><h3>Re: display staircase video</h3><p class="dim">Maya K. · to me</p><p>Watched it three times. The bit where the pointer still crosses like normal while the displays are technically corner to corner is the magic trick. Nobody will notice it is happening — which is the point.</p><p>Ship it.</p></article></div>`;
  }

  function canvasApp(win) {
    return `<div class="app app-canvas"><div class="cv-tools"><i></i><i></i><i></i><i></i></div><div class="cv-board"><div class="ab a1"><span></span><b></b><u></u></div><div class="ab a2"><span></span><b></b></div><div class="ab a3"><span></span></div></div><div class="cv-props"><small>FILL</small><div class="cv-sw"><i style="background:#d4ff4a"></i><i style="background:#ff7a45"></i><i style="background:#7cc4ff"></i></div><small>RADIUS</small><b>12</b></div></div>`;
  }

  function calendar(win) {
    const days = ['Mon 20', 'Tue 21', 'Wed 22', 'Thu 23', 'Fri 24'];
    const ev = [[0, 1, 2, 'Standup', 'b'], [1, 3, 3, 'Design review', 'o'], [2, 0, 2, 'Focus: staircase', 'g'], [3, 2, 2, 'KVM tests', 'b'], [4, 1, 3, 'Launch', 'o'], [0, 5, 2, 'Lunch', 'g']];
    return `<div class="app app-cal"><div class="cal-h"><b>October 2026</b><span>Week 43</span></div><div class="cal-g">${days.map((d) => `<div class="cal-d"><small>${d}</small></div>`).join('')}${ev.map((e) => `<div class="cal-e e-${e[4]}" style="--c:${e[0]};--r:${e[1]};--h:${e[2]}">${e[3]}</div>`).join('')}</div></div>`;
  }

  const RENDER = { terminal, browser, code, notes, music, chat, mail, canvas: canvasApp, calendar };

  function content(win) {
    if (win.grid) return gridTerminal(win);
    return (RENDER[win.app] || notes)(win);
  }

  window.KolomApps = { ICONS, APPS, content, esc };
})();
