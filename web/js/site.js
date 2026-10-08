// Picture-Line: small page helpers (the desktop peek demo).
(() => {
  'use strict';
  document.documentElement.classList.remove('no-js');

  const mac = document.querySelector('.mac'), hold = document.querySelector('.hold');
  if (!mac || !hold) return;
  const peek = mac.querySelector('.mac-line').cloneNode(true);
  peek.classList.add('mac-peek');
  peek.setAttribute('aria-hidden', 'true');
  mac.appendChild(peek);
  const set = on => { mac.classList.toggle('peek', on); hold.setAttribute('aria-pressed', String(on)); };

  hold.addEventListener('pointerdown', e => {
    e.preventDefault();
    try { hold.setPointerCapture(e.pointerId); } catch (_) {}
    set(true);
  });
  ['pointerup', 'pointercancel', 'lostpointercapture'].forEach(ev => hold.addEventListener(ev, () => set(false)));
  hold.addEventListener('contextmenu', e => e.preventDefault());
  hold.addEventListener('keydown', e => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); set(true); } });
  hold.addEventListener('keyup', e => { if (e.key === ' ' || e.key === 'Enter') set(false); });
  hold.addEventListener('blur', () => set(false));

  // The real shortcut works too: hold Control and Option anywhere on the page.
  addEventListener('keydown', e => { if (e.ctrlKey && e.altKey) set(true); });
  addEventListener('keyup', e => { if (e.key === 'Control' || e.key === 'Alt') set(false); });
  addEventListener('blur', () => set(false));
})();
