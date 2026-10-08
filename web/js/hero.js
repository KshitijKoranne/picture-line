// Picture-Line: the live strings on the home page (the dusk hero and the night festival section).
// Each string is a Verlet rope with both ends nailed and photos hanging from it as pendulums.
// A string sizes itself from its section, not its canvas (Safari), and only animates while something moves.
(() => {
  'use strict';
  document.documentElement.classList.remove('no-js');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const N = 40, DT = 1 / 60, G = 1400, HANG = 6, PAD = 16;
  const LIGHTS = ['#ff6152', '#ffcc4d', '#6be673', '#619eff', '#ff7acc'];
  const HOLI = ['#ff2e8c', '#ffd91a', '#26cc59', '#3380ff', '#ff801a'];
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const smooth = x => x * x * (3 - 2 * x);

  // shared sprites
  const sprite = n => { const i = new Image(); i.decoding = 'async'; i.src = `/img/deco/${n}.png`; return i; };
  const SPR = { diya: sprite('diya'), cane: sprite('cane'), bauble: sprite('bauble'), flake: sprite('flake') };
  const ready = i => i.complete && i.naturalWidth > 0;
  const glowCache = {};
  function glowSprite(col) {
    if (glowCache[col]) return glowCache[col];
    const c = document.createElement('canvas'); c.width = c.height = 64;
    const g = c.getContext('2d'), gr = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    gr.addColorStop(0, col); gr.addColorStop(1, col + '00');
    g.fillStyle = gr; g.fillRect(0, 0, 64, 64);
    return (glowCache[col] = c);
  }
  const images = new Map(); // one decoded image per photo URL, shared by both strings
  function photoImage(src, cb) {
    let e = images.get(src);
    if (!e) {
      e = { img: new Image(), cbs: [] }; images.set(src, e);
      e.img.decoding = 'async';
      e.img.onload = () => { e.ok = true; e.cbs.forEach(f => f(e.img)); e.cbs = []; };
      e.img.src = src;
    }
    e.ok ? cb(e.img) : e.cbs.push(cb);
  }
  let fontsReady = !document.fonts;
  const strings = [];

  function makeString(sec, cv, opts) {
    const ctx = cv.getContext('2d');
    const list = document.querySelector(`.photo-list[data-for="${cv.id}"]`);
    const items = [...list.querySelectorAll('li')].map((li, k) => ({
      k, src: li.dataset.src, cap: li.dataset.cap, note: li.dataset.note, alt: li.dataset.alt || '', rank: +li.dataset.rank,
      img: null, btn: li.querySelector('button'),
    }));
    let W = 0, H = 0, dpr = 1, cw = 100, ch = 121, lastSize = '';
    let pts = [], old = [], seg = 10, pinA = { x: 0, y: 0 }, pinB = { x: 0, y: 0 };
    let photos = [], parts = [], snow = new Float32Array(N), deco = [];
    const mouse = { x: -1e4, y: -1e4 }, lastMouse = { x: -1e4, y: -1e4 };
    let inside = false, grabbed = -1, grabOff = { x: 0, y: 0 }, pressed = null, dragging = null;
    let downAt = { x: 0, y: 0 }, moved = 0, holdTimer = 0, lastTap = { p: null, t: 0 };
    let t = 0, lastMove = -99, lastNear = 0, light = reduce ? opts.light : 0, lightT = opts.light, fest = opts.fest || null, nextPuff = 0, motion = 0;
    let running = false, onScreen = true, last = 0, acc = 0, first = true;
    const state = new Map();

    function glow(x, y, col, r, a) {
      if (a < 0.01) return;
      ctx.globalAlpha = Math.min(1, a);
      ctx.drawImage(glowSprite(col), x - r, y - r, r * 2, r * 2);
      ctx.globalAlpha = 1;
    }

    // photo cards, drawn once with the shadow baked in
    function card(p, back) {
      const w = cw, h = ch, m = w * 0.055, iw = w - 2 * m;
      const c = document.createElement('canvas');
      c.width = Math.ceil((w + PAD * 2) * dpr); c.height = Math.ceil((h + PAD * 2) * dpr);
      const g = c.getContext('2d');
      g.scale(dpr, dpr); g.translate(PAD, PAD);
      g.shadowColor = 'rgba(0,0,0,.32)'; g.shadowBlur = 9; g.shadowOffsetY = 4;
      g.fillStyle = back ? '#f5f1e8' : '#fffdf8'; g.fillRect(0, 0, w, h);
      g.shadowColor = 'transparent';
      g.fillStyle = '#262e63'; g.textAlign = 'center'; g.textBaseline = 'middle';
      const hand = s => `${s}px Kalam, "Bradley Hand", cursive`;
      if (!back) {
        if (p.it.img) {
          const im = p.it.img, s = Math.min(im.naturalWidth, im.naturalHeight);
          g.drawImage(im, (im.naturalWidth - s) / 2, (im.naturalHeight - s) / 2, s, s, m, m, iw, iw);
        }
        g.strokeStyle = 'rgba(0,0,0,.09)'; g.lineWidth = 0.5; g.strokeRect(m, m, iw, iw);
        g.font = hand(Math.round(w * 0.13)); g.fillText(p.it.cap, w / 2, m + iw + (h - m - iw) * 0.52, iw);
      } else {
        g.font = hand(Math.round(w * 0.11));
        const lines = []; let line = '';
        for (const wd of p.it.note.split(' ')) { const l2 = line ? line + ' ' + wd : wd; if (g.measureText(l2).width > iw * 0.92 && line) { lines.push(line); line = wd; } else line = l2; }
        lines.push(line);
        const lh = w * 0.15, y0 = h * 0.44 - (lines.length - 1) * lh / 2;
        g.save(); g.translate(w / 2, 0); g.rotate(-0.04);
        lines.forEach((l, k) => g.fillText(l, 0, y0 + k * lh, iw));
        g.restore();
      }
      return c;
    }
    const buildCard = p => { if (p.it.img && fontsReady) { p.front = card(p, false); p.back = card(p, true); } };

    // layout: the section decides the size, the string hangs in the band opts.band() returns
    function layout(force) {
      W = sec.clientWidth; H = sec.clientHeight;
      if (!W || !H) return;
      const key = W + 'x' + Math.round(H / 40);
      if (!force && key === lastSize) return;
      lastSize = key;
      dpr = Math.min(2, window.devicePixelRatio || 1);
      cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
      const [y0, bottom] = opts.band(W, H);
      const count = Math.min(items.length, W < 430 ? 3 : W < 660 ? 4 : W < 980 ? 5 : 7);
      const room = bottom - y0;
      cw = Math.round(clamp(Math.min(W / (count + 2.4) * 0.82, (room - 30) / 1.21 / 1.35), 72, 118));
      ch = Math.round(cw * 1.21);
      const ax = Math.max(12, W * 0.025);
      pinA = { x: ax, y: y0 }; pinB = { x: W - ax, y: y0 + (opts.tilt || 0) };
      const L0 = pinB.x - pinA.x;
      let d = clamp(room - ch - HANG - 14, 18, W * 0.09);
      const hangRope = () => {
        seg = (L0 + 8 * d * d / (3 * L0)) / (N - 1);
        pts = []; old = [];
        for (let i = 0; i < N; i++) {
          const u = i / (N - 1), p = { x: pinA.x + L0 * u, y: pinA.y + (pinB.y - pinA.y) * u + 4 * d * u * (1 - u) };
          pts.push(p); old.push({ x: p.x, y: p.y });
        }
      };
      hangRope();
      const shown = items.filter(it => it.rank <= count);
      photos = shown.map((it, j) => {
        const s = state.get(it) || { it, angle: 0, spin: 0, lvx: 0, lvy: 0, flip: 0, flipT: 0, dev: reduce ? 1 : 0, devAt: 0 };
        state.set(it, s);
        s.at = Math.round(3 + (N - 7) * (j + 0.5) / count);
        return s;
      });
      deco = [];
      for (let j = 0; j <= photos.length; j++) {
        const a = j ? photos[j - 1].at : 0, b = j < photos.length ? photos[j].at : N - 1;
        if (b - a >= 4) deco.push({ at: Math.floor((a + b) / 2), angle: 0, spin: 0, lvx: 0, lvy: 0, k: deco.length });
      }
      items.forEach(it => { if (it.btn) it.btn.hidden = !shown.includes(it); });
      photos.forEach(buildCard);
      const keep = inside; inside = false;
      for (let pass = 0; pass < 4; pass++) { // the photos pull the rope down: shorten it until the lowest card clears the copy
        for (let k = 0; k < 300; k++) step(true);
        const over = Math.max(...photos.map(p => pts[p.at].y + HANG + ch)) - bottom;
        if (over <= 0 || d <= 12) break;
        d = Math.max(12, d - over * 1.3); hangRope();
      }
      inside = keep;
      for (const p of photos) { p.spin = 0; p.lvx = p.lvy = 0; p.angle = reduce || !first ? 0 : (Math.random() - 0.5) * 0.5; }
      for (const q of deco) { q.spin = 0; q.angle = 0; q.lvx = q.lvy = 0; }
      first = false;
      draw();
    }

    // physics
    function hit(p, m) {
      const o = pts[p.at], dx = m.x - o.x, dy = m.y - o.y, c = Math.cos(p.angle), s = Math.sin(p.angle);
      const lx = dx * c + dy * s, ly = -dx * s + dy * c;
      return Math.abs(lx) < cw / 2 && ly > HANG - 4 && ly < HANG + ch;
    }
    const topPhoto = m => { for (let k = photos.length - 1; k >= 0; k--) if (hit(photos[k], m)) return photos[k]; return null; };
    function nearestIndex(x) {
      let best = 2, bd = 1e9;
      for (let i = 2; i < N - 2; i++) { const d = Math.abs(pts[i].x - x); if (d < bd) { bd = d; best = i; } }
      return best;
    }
    function nearRope(m, r) {
      for (let i = 1; i < N - 1; i++) if ((pts[i].x - m.x) ** 2 + (pts[i].y - m.y) ** 2 < r * r) return i;
      return -1;
    }
    function swing(p, len, settling, hover, mvx) { // a pendulum driven by the acceleration of its point on the rope
      const i = p.at, vx = (pts[i].x - old[i].x) * 60, vy = (pts[i].y - old[i].y) * 60;
      const ax = clamp((vx - p.lvx) * 60, -5000, 5000), ay = clamp((vy - p.lvy) * 60, -5000, 5000);
      p.lvx = vx; p.lvy = vy;
      const s = Math.sin(p.angle), c = Math.cos(p.angle);
      p.spin += -((G - ay) * s - ax * c) / len * DT;
      if (!settling && hover) p.spin -= mvx * 0.012;
      p.spin *= 0.986;
      p.angle = clamp(p.angle + p.spin * DT, -1.4, 1.4);
    }

    function step(settling) {
      t += DT;
      const mvx = mouse.x - lastMouse.x, mvy = mouse.y - lastMouse.y;
      lastMouse.x = mouse.x; lastMouse.y = mouse.y;
      const hover = inside && Math.abs(mvx) + Math.abs(mvy) < 250;
      light += clamp(lightT - light, -0.012, 0.012);
      if (dragging) {
        const i = nearestIndex(mouse.x + grabOff.x);
        if (!photos.some(q => q !== dragging && Math.abs(q.at - i) < 3)) dragging.at = i;
        grabbed = dragging.at;
      }
      const wt = new Float32Array(N);
      for (const p of photos) wt[p.at] += cw * ch / (140 * 175);
      for (let i = 1; i < N - 1; i++) {
        if (i === grabbed) continue;
        const p = pts[i], o = old[i];
        const vx = (p.x - o.x) * 0.985, vy = (p.y - o.y) * 0.985;
        o.x = p.x; o.y = p.y;
        p.x += vx; p.y += vy + (G + wt[i] * 900 + snow[i] * 30) * DT * DT;
        if (grabbed < 0 && hover && (p.x - mouse.x) ** 2 + (p.y - mouse.y) ** 2 < 1600) { p.x += mvx * 0.22; p.y += mvy * 0.22; }
      }
      if (grabbed > 0) {
        const p = pts[grabbed];
        old[grabbed] = { x: p.x, y: p.y };
        p.x = clamp(mouse.x + grabOff.x, 0, W); p.y = clamp(mouse.y + grabOff.y, 10, H - ch - 20);
      }
      pts[0] = { x: pinA.x, y: pinA.y }; pts[N - 1] = { x: pinB.x, y: pinB.y };
      for (let it = 0; it < 20; it++) {
        for (let i = 0; i < N - 1; i++) {
          const fa = i === 0 || i === grabbed, fb = i + 1 === N - 1 || i + 1 === grabbed;
          if (fa && fb) continue;
          const a = pts[i], b = pts[i + 1], dx = b.x - a.x, dy = b.y - a.y, l = Math.hypot(dx, dy) || 0.001;
          const k = (l - seg) / l * (fa || fb ? 1 : 0.5), cx = dx * k, cy = dy * k;
          if (!fa) { a.x += cx; a.y += cy; }
          if (!fb) { b.x -= cx; b.y -= cy; }
        }
      }
      motion = 0;
      for (let i = 1; i < N - 1; i++) motion = Math.max(motion, Math.abs(pts[i].x - old[i].x) + Math.abs(pts[i].y - old[i].y));
      for (const p of photos) {
        swing(p, HANG + ch / 2, settling, !dragging && hover && hit(p, mouse), mvx);
        p.flip = Math.abs(p.flipT - p.flip) < 1 / 24 ? p.flipT : p.flip + Math.sign(p.flipT - p.flip) / 24;
        if (p.dev < 1 && p.it.img && t > p.devAt) p.dev = Math.min(1, p.dev + DT / 4);
      }
      if (fest === 'diwali' || fest === 'christmas') for (const q of deco) swing(q, cw * 0.3, settling, false, 0);
      if (!settling) particles();
    }

    function particles() {
      const awake = t - lastNear < 15;
      if (fest === 'christmas' && awake && parts.length < 90 && Math.random() < 0.3)
        parts.push({ k: 's', x: Math.random() * W, y: -12, vx: (Math.random() - 0.5) * 14, vy: 20 + Math.random() * 18, r: 4 + Math.random() * 6, rot: Math.random() * 6, vr: (Math.random() - 0.5) * 1.6, age: 0, life: 40, seed: Math.random() * 99 });
      if (fest === 'holi' && awake && t > nextPuff) { nextPuff = t + 0.9 + Math.random(); puff(pts[2 + Math.floor(Math.random() * (N - 4))]); }
      for (let i = 0; i < N; i++) { // snow settles on the string and falls off when shaken
        if (snow[i] > 0.4 && Math.abs(pts[i].x - old[i].x) + Math.abs(pts[i].y - old[i].y) > 1.6) {
          snow[i] *= 0.65;
          parts.push({ k: 's', x: pts[i].x, y: pts[i].y + 2, vx: (Math.random() - 0.5) * 20, vy: 30 + Math.random() * 30, r: 3 + Math.random() * 3, rot: 0, vr: 2, age: 0, life: 20, seed: Math.random() * 99 });
        }
        snow[i] = Math.max(0, snow[i] - (fest === 'christmas' ? 0.0004 : 0.012));
      }
      parts = parts.filter(q => {
        q.age += DT;
        if (q.k === 'p') { q.x += q.vx * DT; q.y += q.vy * DT; q.r += 16 * DT; return q.age < q.life; }
        q.x += (q.vx + Math.sin(t * 1.3 + q.seed) * 10) * DT; q.y += q.vy * DT; q.rot += q.vr * DT;
        for (let i = 0; i < N - 1; i++) {
          const a = pts[i], b = pts[i + 1];
          if (q.x < Math.min(a.x, b.x) || q.x > Math.max(a.x, b.x)) continue;
          const y = a.y + (b.y - a.y) * (q.x - a.x) / ((b.x - a.x) || 1);
          if (Math.abs(q.y - y) < 2.5 && Math.random() < 0.5) { snow[i] = Math.min(6, snow[i] + 0.35); return false; }
        }
        return q.age < q.life && q.y < H + 20;
      });
    }
    function puff(at) {
      const col = HOLI[Math.floor(Math.random() * HOLI.length)];
      for (let k = 0; k < 7; k++) {
        const a = Math.random() * Math.PI * 2, s = 12 + Math.random() * 30;
        parts.push({ k: 'p', x: at.x, y: at.y, vx: Math.cos(a) * s, vy: Math.sin(a) * s - 6, r: 5 + Math.random() * 6, age: 0, life: 2.4 + Math.random(), col });
      }
    }

    // drawing
    function ropePath(dy) {
      ctx.beginPath(); ctx.moveTo(pts[0].x, pts[0].y + dy);
      for (let i = 1; i < N - 1; i++) {
        const a = pts[i], b = pts[i + 1];
        ctx.quadraticCurveTo(a.x, a.y + dy, (a.x + b.x) / 2, (a.y + b.y) / 2 + dy);
      }
      ctx.lineTo(pts[N - 1].x, pts[N - 1].y + dy);
    }
    function nail(p) {
      ctx.fillStyle = 'rgba(0,0,0,.28)'; ctx.beginPath(); ctx.arc(p.x + 1, p.y + 2, 5, 0, 7); ctx.fill();
      const g = ctx.createRadialGradient(p.x - 1.5, p.y - 1.8, 0, p.x, p.y, 5.5);
      g.addColorStop(0, '#eef0f2'); g.addColorStop(1, '#7f8287');
      ctx.fillStyle = g; ctx.beginPath(); ctx.arc(p.x, p.y, 4.5, 0, 7); ctx.fill();
    }
    function rr(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect ? ctx.roundRect(x, y, w, h, r) : ctx.rect(x, y, w, h); }
    function clip(s) {
      ctx.save(); ctx.scale(s, s);
      ctx.fillStyle = 'rgba(0,0,0,.22)'; rr(-3.9, -7.4, 9, 25, 2.5); ctx.fill();
      ctx.fillStyle = '#d9b07a'; rr(-4.5, -9, 9, 25, 2.5); ctx.fill();
      ctx.strokeStyle = '#8c6945'; ctx.lineWidth = 0.8; ctx.stroke();
      ctx.lineWidth = 0.6; ctx.beginPath(); ctx.moveTo(0, -8); ctx.lineTo(0, 15); ctx.stroke();
      ctx.fillStyle = '#bdbfc3'; ctx.fillRect(-5.5, 1, 11, 2.4);
      ctx.fillStyle = 'rgba(255,255,255,.28)'; ctx.fillRect(-3.5, -8, 1.4, 22);
      ctx.restore();
    }
    // a clay diya on three threads, with a flame that breathes
    function diya(q) {
      const o = pts[q.at], im = SPR.diya;
      if (!ready(im)) return;
      const w = cw * 0.5, h = w * im.naturalHeight / im.naturalWidth, drop = cw * 0.2;
      const f = reduce ? 1 : 1 + 0.12 * Math.sin(t * 11 + q.k * 2.3) + 0.07 * Math.sin(t * 23 + q.k);
      ctx.save(); ctx.translate(o.x, o.y); ctx.rotate(q.angle);
      ctx.strokeStyle = 'rgba(240,190,90,.75)'; ctx.lineWidth = 0.8; ctx.beginPath();
      for (const fx of [-0.42, 0.0, 0.42]) { ctx.moveTo(0, 0); ctx.lineTo(fx * w, drop + h * 0.28); }
      ctx.stroke();
      const x0 = -w / 2, y0 = drop;
      glow(x0 + w * 0.78, y0 + h * 0.18, '#ff9e26', w * 1.1 * f, 0.5 + light * 0.25);
      ctx.drawImage(im, x0, y0, w, h);
      glow(x0 + w * 0.8, y0 + h * 0.14, '#fff2c0', w * 0.22 * f, 0.55);
      ctx.restore();
    }
    function star(q) {
      const o = pts[q.at], s = cw / 110, len = 16 * s;
      ctx.save(); ctx.translate(o.x, o.y); ctx.rotate(q.angle);
      ctx.strokeStyle = 'rgba(220,190,110,.85)'; ctx.lineWidth = 0.7;
      ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(0, len); ctx.stroke();
      const cy = len + 9 * s;
      glow(0, cy, '#ffe08a', 26 * s, 0.25 + light * 0.4);
      ctx.beginPath();
      for (let k = 0; k < 10; k++) { const a = -Math.PI / 2 + k * Math.PI / 5, r = (k % 2 ? 3.8 : 9.5) * s; ctx.lineTo(Math.cos(a) * r, cy + Math.sin(a) * r); }
      ctx.closePath(); ctx.fillStyle = '#f2cd5c'; ctx.fill(); ctx.strokeStyle = '#b38a2c'; ctx.lineWidth = 0.8; ctx.stroke();
      ctx.restore();
    }
    function bauble(q) {
      const o = pts[q.at], im = SPR.bauble;
      if (!ready(im)) return;
      const w = cw * 0.34, h = w * im.naturalHeight / im.naturalWidth;
      ctx.save(); ctx.translate(o.x, o.y); ctx.rotate(q.angle);
      ctx.drawImage(im, -w / 2, -1, w, h);
      ctx.restore();
    }
    function cane(q) { // the hook rests over the string
      const o = pts[q.at], im = SPR.cane;
      if (!ready(im)) return;
      const h = cw * 0.62, w = h * im.naturalWidth / im.naturalHeight;
      ctx.save(); ctx.translate(o.x, o.y); ctx.rotate(q.angle * 0.7 + 0.12);
      ctx.drawImage(im, -w * 0.53, -h * 0.07, w, h);
      ctx.restore();
    }
    function drawDeco() {
      if (fest === 'diwali') deco.forEach(diya);
      if (fest === 'christmas') deco.forEach(q => [star, bauble, cane][q.k % 3](q));
    }

    function drawPhoto(p) {
      const o = pts[p.at], s = clamp(cw / 140, 0.62, 1);
      ctx.save(); ctx.translate(o.x, o.y); ctx.rotate(p.angle);
      const fx = Math.cos(p.flip * Math.PI), lift = 1 + 0.06 * Math.sin(p.flip * Math.PI);
      ctx.save(); ctx.scale(Math.max(0.02, Math.abs(fx)) * lift, lift);
      const img = p.flip < 0.5 ? p.front : p.back;
      if (img) ctx.drawImage(img, -cw / 2 - PAD, HANG - PAD, cw + PAD * 2, ch + PAD * 2);
      else { ctx.fillStyle = '#fffdf8'; ctx.fillRect(-cw / 2, HANG, cw, ch); }
      if (p.flip < 0.5) {
        const m = cw * 0.055, iw = cw - 2 * m;
        if (p.dev < 1) { ctx.fillStyle = `rgba(234,235,226,${(1 - smooth(p.dev)).toFixed(3)})`; ctx.fillRect(-cw / 2 + m, HANG + m, iw, iw); }
        if (fest === 'holi') {
          const r = cw * 0.3;
          glow(-cw / 2 + m + ((p.it.k * 37) % 70) / 100 * iw, HANG + m + iw * 0.2, HOLI[p.it.k % 5], r, 0.32);
          glow(cw / 2 - m - ((p.it.k * 53) % 50) / 100 * iw, HANG + ch * 0.86, HOLI[(p.it.k + 2) % 5], r * 0.8, 0.3);
        }
      }
      ctx.restore();
      clip(s);
      ctx.restore();
    }

    function draw() {
      if (!W) return;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      ctx.clearRect(0, 0, W, H);
      ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      ropePath(3); ctx.strokeStyle = opts.dark ? 'rgba(0,0,0,.35)' : 'rgba(40,20,30,.16)'; ctx.lineWidth = 2; ctx.stroke();
      ropePath(0); ctx.strokeStyle = opts.dark ? '#c19a74' : '#7d5a3f'; ctx.lineWidth = 2; ctx.stroke();
      nail(pts[0]); nail(pts[N - 1]);
      ctx.fillStyle = '#fbfcff';
      for (let i = 1; i < N - 1; i++) if (snow[i] > 0.15) {
        const r = 1.2 + snow[i] * 0.75; ctx.beginPath(); ctx.ellipse(pts[i].x, pts[i].y - r * 0.55, r * 1.6, r, 0, 0, 7); ctx.fill();
      }
      drawDeco();
      for (const p of photos) if (p !== dragging) drawPhoto(p);
      if (dragging) drawPhoto(dragging);
      if (light > 0.01) {
        const tw = !reduce && t - lastNear < 15;
        for (let i = 2; i < N - 2; i += 3) {
          const a = pts[i], col = LIGHTS[(i / 3 | 0) % LIGHTS.length], f = tw ? 0.82 + 0.18 * Math.sin(t * 2.2 + i * 1.7) : 1;
          glow(a.x, a.y + 7, col, 22 * f, 0.55 * light * f);
          ctx.globalAlpha = 0.35 + 0.65 * light;
          ctx.fillStyle = '#3c3c3c'; ctx.fillRect(a.x - 1.5, a.y, 3, 3);
          ctx.fillStyle = col; ctx.beginPath(); ctx.ellipse(a.x, a.y + 7, 2.6, 4, 0, 0, 7); ctx.fill();
          ctx.fillStyle = 'rgba(255,255,255,.7)'; ctx.beginPath(); ctx.arc(a.x - 0.7, a.y + 5.5, 0.9, 0, 7); ctx.fill();
          ctx.globalAlpha = 1;
        }
      }
      const flake = ready(SPR.flake) && SPR.flake;
      for (const q of parts) {
        if (q.k === 'p') { glow(q.x, q.y, q.col, q.r, 0.5 * (1 - q.age / q.life)); continue; }
        if (flake) {
          ctx.save(); ctx.translate(q.x, q.y); ctx.rotate(q.rot); ctx.globalAlpha = 0.9;
          ctx.drawImage(flake, -q.r, -q.r, q.r * 2, q.r * 2); ctx.restore(); ctx.globalAlpha = 1;
        } else { ctx.fillStyle = 'rgba(255,255,255,.9)'; ctx.beginPath(); ctx.arc(q.x, q.y, q.r / 3, 0, 7); ctx.fill(); }
      }
    }

    // the loop runs only while something is happening
    function busy() {
      if (grabbed > 0 || pressed || t - lastMove < 1.2 || motion > 0.015 || parts.length) return true;
      if (Math.abs(light - lightT) > 0.001) return true;
      if (photos.some(p => Math.abs(p.spin) > 0.015 || Math.abs(p.flip - p.flipT) > 0.001 || (p.dev < 1 && p.it.img))) return true;
      if (deco.some(q => Math.abs(q.spin) > 0.015)) return true;
      for (let i = 0; i < N; i++) if (snow[i] > 0.15 && fest !== 'christmas') return true;
      return t - lastNear < 15 && (!!fest || light > 0.01);
    }
    function frame(now) {
      acc += Math.min(0.1, (now - last) / 1000); last = now;
      let n = 0;
      while (acc >= DT && n < 6) { step(false); acc -= DT; n++; }
      if (n === 6) acc = 0;
      draw();
      if (onScreen && !document.hidden && busy()) requestAnimationFrame(frame);
      else running = false;
    }
    function wake() {
      if (reduce) { photos.forEach(p => { p.flip = p.flipT; }); light = lightT; draw(); return; }
      if (running || !onScreen || document.hidden || !W) return;
      running = true; last = performance.now(); acc = 0;
      requestAnimationFrame(frame);
    }
    const poke = () => { lastNear = t; wake(); };

    // pointer
    function setMouse(e) { const r = sec.getBoundingClientRect(); mouse.x = e.clientX - r.left; mouse.y = e.clientY - r.top; }
    const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
    function release() { clearTimeout(holdTimer); pressed = null; dragging = null; grabbed = -1; }
    sec.addEventListener('pointermove', e => {
      setMouse(e); inside = true;
      if (pressed || grabbed > 0) moved = Math.max(moved, dist(mouse, downAt));
      if (pressed && !dragging && moved > 6) {
        dragging = pressed; clearTimeout(holdTimer);
        grabOff = { x: pts[pressed.at].x - mouse.x, y: pts[pressed.at].y - mouse.y };
      }
      if (mouse.y < pinA.y + ch * 2.4 || pressed || grabbed > 0) {
        lastMove = lastNear = t;
        if (reduce && dragging) { const i = nearestIndex(mouse.x + grabOff.x); if (!photos.some(q => q !== dragging && Math.abs(q.at - i) < 3)) dragging.at = i; }
        wake();
      }
    });
    sec.addEventListener('pointerleave', e => { if (e.pointerType === 'mouse') { inside = false; mouse.x = mouse.y = lastMouse.x = lastMouse.y = -1e4; } });
    sec.addEventListener('pointerdown', e => {
      if (e.button > 0 || e.target.closest('a,button,summary')) return;
      setMouse(e); inside = true; lastMouse.x = mouse.x; lastMouse.y = mouse.y;
      downAt = { x: mouse.x, y: mouse.y }; moved = 0;
      const p = topPhoto(mouse);
      if (p) {
        pressed = p; e.preventDefault();
        try { sec.setPointerCapture(e.pointerId); } catch (_) {}
        holdTimer = setTimeout(() => { if (pressed === p && moved <= 6) { release(); openBox(p.it); } }, 480);
      } else {
        const i = nearRope(mouse, e.pointerType === 'mouse' ? 14 : 22);
        if (i > 0 && !reduce) {
          grabbed = i; grabOff = { x: pts[i].x - mouse.x, y: pts[i].y - mouse.y }; e.preventDefault();
          try { sec.setPointerCapture(e.pointerId); } catch (_) {}
        }
      }
      lastMove = lastNear = t; wake();
    });
    sec.addEventListener('pointerup', () => {
      const p = pressed, tap = p && !dragging;
      release();
      if (tap) {
        const now = performance.now();
        if (lastTap.p === p && now - lastTap.t < 380) { p.flipT = p.flipT ? 0 : 1; lastTap = { p: null, t: 0 }; }
        else { lastTap = { p, t: now }; p.spin += downAt.x < pts[p.at].x ? -2.2 : 2.2; }
      }
      lastMove = lastNear = t; wake();
    });
    sec.addEventListener('pointercancel', () => { release(); wake(); });
    sec.addEventListener('dblclick', e => { if (topPhoto(mouse)) e.preventDefault(); });
    items.forEach(it => {
      if (!it.btn) return;
      it.btn.addEventListener('click', () => openBox(it));
      it.btn.addEventListener('focus', () => { const p = state.get(it); if (p && !reduce) { p.spin += 2; poke(); } });
    });

    // photos and start
    items.forEach((it, j) => photoImage(it.src, im => {
      it.img = im;
      const p = state.get(it);
      if (p) { p.devAt = t + 0.25 + 0.35 * j; buildCard(p); }
      reduce ? draw() : poke();
    }));
    Object.values(SPR).forEach(i => i.addEventListener('load', () => draw()));
    if ('ResizeObserver' in window) new ResizeObserver(() => { layout(false); wake(); }).observe(sec);
    if ('IntersectionObserver' in window) new IntersectionObserver(es => { onScreen = es[0].isIntersecting; if (onScreen) poke(); }).observe(sec);
    layout(true);

    return {
      fonts() { photos.forEach(buildCard); draw(); poke(); },
      wake: poke,
      setFest(f) {
        fest = f || null;
        if (fest !== 'christmas') parts = parts.filter(q => q.k !== 's');
        if (reduce) for (let i = 2; i < N - 2; i++) snow[i] = fest === 'christmas' && i % 2 ? 0.4 + Math.random() * 1.4 : 0;
        nextPuff = t; lastMove = t; draw(); poke();
      },
    };
  }

  // lightbox
  const dlg = document.getElementById('lightbox');
  function openBox(it) {
    if (!dlg || !dlg.showModal) return;
    const img = dlg.querySelector('img');
    img.src = it.src; img.alt = it.alt;
    dlg.querySelector('figcaption').textContent = it.cap;
    dlg.querySelector('.note').textContent = 'On the back: ' + it.note;
    dlg.showModal();
  }
  if (dlg) {
    dlg.addEventListener('click', e => { if (e.target === dlg) dlg.close(); });
    dlg.querySelector('.close').addEventListener('click', () => dlg.close());
  }

  // the two strings
  const hero = document.querySelector('.hero'), heroCv = document.getElementById('hero-string');
  if (hero && heroCv && heroCv.getContext) {
    const copy = hero.querySelector('.hero-copy');
    strings.push(makeString(hero, heroCv, {
      light: 1, dark: false, tilt: 10,
      band: (W, H) => [W < 640 ? 84 : 96, Math.max(260, (copy ? copy.offsetTop : H * 0.5) - 8)],
    }));
  }
  const night = document.getElementById('festivals'), nightCv = document.getElementById('night-string');
  if (night && nightCv && nightCv.getContext) {
    const copy = night.querySelector('.night-copy');
    const s = makeString(night, nightCv, {
      light: 1, dark: true, fest: 'diwali', tilt: -8,
      band: (W, H) => [44, Math.max(240, (copy ? copy.offsetTop : H * 0.5) - 10)],
    });
    strings.push(s);
    const chips = night.querySelectorAll('[data-fest]');
    chips.forEach(b => b.addEventListener('click', () => {
      chips.forEach(x => x.setAttribute('aria-pressed', String(x === b)));
      s.setFest(b.dataset.fest);
    }));
  }
  if (document.fonts && document.fonts.load) {
    const done = () => { fontsReady = true; strings.forEach(s => s.fonts()); };
    document.fonts.load('20px Kalam').then(done, done);
  }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) strings.forEach(s => s.wake()); });

  // phone: the download dock steps aside while a download button is already on screen
  const dock = document.querySelector('.dock');
  if (dock && 'IntersectionObserver' in window) {
    const seen = new Set();
    const io = new IntersectionObserver(es => {
      es.forEach(e => e.isIntersecting ? seen.add(e.target) : seen.delete(e.target));
      dock.classList.toggle('away', seen.size > 0);
    });
    document.querySelectorAll('.hero .ctas, .price .plans, .last').forEach(el => io.observe(el));
  }
})();
