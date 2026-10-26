/* Kolom site — hero strip, copy buttons, demo deep links, reveal on scroll. */
(function () {
  'use strict';
  const A = window.KolomApps;
  const RM = window.matchMedia('(prefers-reduced-motion: reduce)');
  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));

  /* ---------- hero: a display onto a longer strip ---------- */
  const hv = $('.hv');
  if (hv) {
    const W = 1600, H = 900, MENU = 24, RAIL = 48, GAP = 16;
    const vh = H - MENU - GAP * 2, vw = W - RAIL - GAP * 2;
    const cols = [
      [560, [['code', 'reveal', 'Workspace.swift — kolom']]],
      [460, [['terminal', 'build', '~/kolom — zsh'], ['terminal', 'state', '~ — zsh']]],
      [760, [['browser', 'docs', 'Columns · Kolom docs']]],
      [520, [['notes', 'launch', 'Launch checklist'], ['calendar', '', 'October 2026']]],
      [640, [['music', '', 'Night Shift Tapes']]],
      [700, [['browser', 'local', 'localhost:3000']]],
      [480, [['chat', '', '# launch — Studio']]],
      [620, [['code', 'stairs', 'DisplayArrangement.swift']]],
      [560, [['mail', '', 'Inbox — 2 unread']]]
    ];
    const strip = $('.hv-strip', hv);
    const inner = document.createElement('div');
    inner.className = 'hv-inner';
    strip.appendChild(inner);
    const starts = [];
    let x = 0;
    cols.forEach(([w, tiles], ci) => {
      starts.push(x);
      const h = (vh - GAP * (tiles.length - 1)) / tiles.length;
      tiles.forEach(([app, variant, title], ti) => {
        const el = document.createElement('div');
        el.className = 'win app-' + app + (ci === 0 && ti === 0 ? ' is-key' : '');
        el.style.cssText = `width:${w}px;height:${h}px;transform:translate(${x}px,${ti * (h + GAP)}px);transition:none`;
        el.innerHTML = `<div class="win-tb"><i class="tl"></i><i class="tl"></i><i class="tl"></i><span class="win-t">${A.esc(title)}</span></div><div class="win-b">${A.content({ app, variant, title })}</div>`;
        el.dataset.col = ci;
        inner.appendChild(el);
      });
      x += w + GAP;
    });
    const rail = $('.hv-rail', hv);
    rail.innerHTML = cols.map(([, tiles], ci) => `<i data-col="${ci}"${ci === 0 ? ' class="on"' : ''}>${A.ICONS[tiles[0][0]]}</i>`).join('');
    const world = $('.hv-world', hv);
    const wall = document.createElement('div');
    wall.className = 'hv-wall';
    hv.insertBefore(wall, world);
    const fit = () => { strip.style.transform = `scale(${world.clientWidth / W})`; };
    fit();
    new ResizeObserver(fit).observe(world);

    let focus = 0, offset = 0, raf = 0;
    const offsetFor = (ci) => {
      const start = starts[ci], end = start + cols[ci][0];
      let o = offset;
      if (start < o) o = start; else if (end > o + vw) o = end - vw;
      return o;
    };
    const glide = (to) => {
      const from = offset, t0 = performance.now(), dur = Math.min(1100, Math.max(520, Math.abs(to - from) / 2.4));
      cancelAnimationFrame(raf);
      const step = (now) => {
        const p = Math.min(1, (now - t0) / dur);
        const e = 1 - Math.pow(1 - p, 3.4);
        offset = from + (to - from) * e;
        inner.style.transform = `translate3d(${-offset}px,0,0)`;
        if (p < 1) raf = requestAnimationFrame(step);
      };
      raf = requestAnimationFrame(step);
    };
    const keys = $$('.hv-caption .kc', hv);
    const capT = $('.hv-cap-t', hv);
    const setFocus = (ci) => {
      focus = ci;
      $$('i', rail).forEach((i) => i.classList.toggle('on', +i.dataset.col === ci));
      // Only the first window of the focused column is key.
      let seen = false;
      $$('.win', inner).forEach((w) => { const k = +w.dataset.col === ci && !seen; if (k) seen = true; w.classList.toggle('is-key', k); });
    };
    let visible = true;
    new IntersectionObserver((es) => { visible = es[0].isIntersecting; }).observe(hv);
    if (!RM.matches) {
      setInterval(() => {
        if (!visible || document.hidden) return;
        const next = focus + 1 >= cols.length ? 0 : focus + 1;
        if (next === 0) {
          keys[1].textContent = '1';
          if (capT) capT.textContent = 'Jump anywhere with ⌥1–9. Focus follows.';
        } else {
          keys[1].textContent = '→';
          if (capT) capT.textContent = 'The strip keeps going past the edge of your screen.';
        }
        keys.forEach((k) => { k.classList.remove('hit'); void k.offsetWidth; k.classList.add('hit'); });
        setFocus(next);
        glide(next === 0 ? 0 : offsetFor(next));
      }, 2600);
    }
  }

  /* ---------- copy buttons ---------- */
  $$('[data-copy]').forEach((b) => {
    b.addEventListener('click', async () => {
      const text = document.getElementById(b.dataset.copy).textContent.replace(/^\$\s*/, '').trim();
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; } catch (e) {
        const t = document.createElement('textarea'); t.value = text; document.body.appendChild(t); t.select();
        try { ok = document.execCommand('copy'); } catch (x) { ok = false; }
        t.remove();
      }
      const s = b.querySelector('span');
      s.textContent = ok ? 'Copied' : 'Select and copy';
      b.classList.toggle('done', ok);
      setTimeout(() => { s.textContent = 'Copy'; b.classList.remove('done'); }, 1800);
    });
  });

  /* ---------- "watch it" links into the demo ---------- */
  $$('[data-chapter]').forEach((b) => {
    b.addEventListener('click', () => {
      const d = document.getElementById('demo');
      if (d) d.scrollIntoView({ behavior: RM.matches ? 'auto' : 'smooth', block: 'start' });
      if (window.KolomDemo) window.KolomDemo.play(+b.dataset.chapter);
    });
  });

  /* ---------- reveal on scroll ---------- */
  if (!RM.matches && 'IntersectionObserver' in window) {
    const targets = $$('.sec-head, .multi-in > *, .ag-in > *, .safe-row > div, .credit-list, .install .copy-card, .honest');
    targets.forEach((t) => t.classList.add('rv'));
    const io = new IntersectionObserver((es) => {
      es.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } });
    }, { threshold: 0.12, rootMargin: '0px 0px -40px 0px' });
    targets.forEach((t) => io.observe(t));
  }
})();
