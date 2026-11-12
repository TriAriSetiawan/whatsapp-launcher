// Ekstensi: Sidebar bisa di-resize
// Tarik garis batas antara daftar chat dan percakapan untuk mengubah lebar sidebar.
// Klik dua kali garis tersebut untuk kembali ke lebar bawaan. Lebar disimpan per profil.
(function () {
  if (window.__waSidebarResize) return;
  window.__waSidebarResize = true;

  const KEY = 'wa-launcher.sidebar-width';
  const MIN = 260;          // lebar minimum sidebar
  const MIN_MAIN = 380;     // ruang minimum untuk panel percakapan

  const style = document.createElement('style');
  style.textContent = `
    div.two > div:has(> #side),
    [data-testid="drawer-left"] {
      flex: 0 0 var(--wa-side-w, 30%) !important;
      max-width: none !important;
    }
    #wa-side-resizer {
      position: fixed; top: 0; bottom: 0; width: 7px; margin-left: -3px;
      cursor: col-resize; z-index: 2147483647; display: none; touch-action: none;
    }
    #wa-side-resizer::after {
      content: ''; position: absolute; top: 0; bottom: 0; left: 3px; width: 1px;
      background: transparent; transition: background .15s;
    }
    #wa-side-resizer:hover::after, #wa-side-resizer.drag::after { background: #25d366; width: 2px; left: 2px; }
    html.wa-side-dragging, html.wa-side-dragging * { cursor: col-resize !important; user-select: none !important; }
  `;

  const handle = document.createElement('div');
  handle.id = 'wa-side-resizer';
  handle.title = 'Tarik untuk mengubah lebar • klik dua kali untuk reset';

  let saved = parseInt(localStorage.getItem(KEY) || '', 10) || 0;
  let dragging = false, startX = 0, startW = 0, left = 0, enabled = true;

  const pane = () => { const s = document.getElementById('side'); return s && s.parentElement; };
  const clamp = (w, left) => Math.round(Math.max(MIN, Math.min(w, window.innerWidth - left - MIN_MAIN)));

  function apply(w) {
    if (w) document.documentElement.style.setProperty('--wa-side-w', w + 'px');
    else document.documentElement.style.removeProperty('--wa-side-w');
  }

  function place() {
    const p = pane();
    if (!enabled || !p) { handle.style.display = 'none'; return; }
    const r = p.getBoundingClientRect();
    if (r.width === 0) { handle.style.display = 'none'; return; }
    handle.style.display = 'block';
    handle.style.left = r.right + 'px';
  }


  window.addEventListener('pointerdown', (e) => {
    if (e.target !== handle || e.button !== 0) return;
    const p = pane(); if (!p) return;
    const r = p.getBoundingClientRect();
    dragging = true; startX = e.clientX; startW = r.width; left = r.left;
    try { handle.setPointerCapture(e.pointerId); } catch (_) {}
    handle.classList.add('drag');
    document.documentElement.classList.add('wa-side-dragging');
    e.preventDefault(); e.stopPropagation();
  }, true);
  window.addEventListener('pointermove', (e) => {  // capture: tidak bisa dihalangi halaman
    if (!dragging) return;
    saved = clamp(startW + e.clientX - startX, left);
    apply(saved); place();
    e.stopPropagation(); e.preventDefault();
  }, true);
  const end = () => {
    if (!dragging) return;
    dragging = false;
    handle.classList.remove('drag');
    document.documentElement.classList.remove('wa-side-dragging');
    try { localStorage.setItem(KEY, String(saved)); } catch (_) {}
  };
  window.addEventListener('pointerup', end, true);
  window.addEventListener('pointercancel', end, true);
  window.addEventListener('blur', end);
  handle.addEventListener('dblclick', () => {
    saved = 0; apply(0);
    try { localStorage.removeItem(KEY); } catch (_) {}
    requestAnimationFrame(place);
  });

  function start() {
    document.head.appendChild(style);
    document.body.appendChild(handle);
    if (saved) apply(saved);
    // Ikuti perubahan ukuran sidebar / jendela.
    let observed = null;
    const ro = new ResizeObserver(place);
    setInterval(() => {
      if (!enabled) return;
      const p = pane();
      if (p !== observed) { if (observed) ro.unobserve(observed); if (p) ro.observe(p); observed = p; }
      if (saved && p) { const l = p.getBoundingClientRect().left, c = clamp(saved, l); if (c !== saved) apply(c); }
      place();
    }, 500);
    window.addEventListener('resize', place);
  }
  // Nyala/mati langsung dari Pengaturan tanpa memuat ulang halaman.
  function setEnabled(on) {
    enabled = on;
    if (on) {
      document.head.appendChild(style);
      if (saved) apply(saved);
      place();
    } else {
      end();
      style.remove();
      apply(0);            // kembali ke lebar bawaan WhatsApp (lebar tersimpan tidak dihapus)
      handle.style.display = 'none';
    }
  }
  if (window.__waExt) window.__waExt.onToggle(setEnabled);

  if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);
})();
