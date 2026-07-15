// Shared client runtime: holds live settings, polls the backend, applies theme +
// uBlock cosmetic rules, and notifies pages when settings change (the cross-effect).
window.MT = (function () {
  let settings = window.__SETTINGS__ || {
    adBlock: true, sponsorBlock: true, deArrow: true,
    theaterMode: false, playbackSpeed: 1.0, theme: "dark",
  };
  let ublock = null;
  const listeners = [];

  function onChange(cb) { listeners.push(cb); }
  function emit() { listeners.forEach((cb) => { try { cb(settings); } catch (e) { console.error(e); } }); }

  function applyTheme() { document.documentElement.setAttribute("data-theme", settings.theme); }

  function applyUblock() {
    let style = document.getElementById("mt-ublock-style");
    if (settings.adBlock && ublock && ublock.selectors && ublock.selectors.length) {
      if (!style) { style = document.createElement("style"); style.id = "mt-ublock-style"; document.head.appendChild(style); }
      style.textContent = ublock.selectors.join(",\n") + " { display: none !important; }";
    } else if (style) {
      style.textContent = "";
    }
  }

  async function fetchUblock() {
    try {
      const r = await fetch("/api/ublock", { cache: "no-store" });
      ublock = await r.json();
      applyUblock();
    } catch (e) { console.warn("ublock fetch failed", e); }
  }

  async function poll() {
    try {
      const r = await fetch("/api/settings", { cache: "no-store" });
      const s = await r.json();
      if (JSON.stringify(s) !== JSON.stringify(settings)) {
        settings = s;
        applyTheme();
        applyUblock();
        emit();
      }
    } catch (e) { /* backend momentarily unreachable */ }
    setTimeout(poll, 2000);
  }

  function esc(s) { const d = document.createElement("div"); d.textContent = s == null ? "" : String(s); return d.innerHTML; }

  // Write shared settings (used by the web UI's own controls); applies the
  // server's response immediately so the change is instant, then propagates.
  async function update(patchObj) {
    try {
      const r = await fetch("/api/settings", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(patchObj),
      });
      const s = await r.json();
      settings = s;
      applyTheme();
      applyUblock();
      emit();
    } catch (e) { console.warn("settings update failed", e); }
  }

  function start() { applyTheme(); fetchUblock(); poll(); }

  return {
    get settings() { return settings; },
    get ublock() { return ublock; },
    onChange, start, esc, applyUblock, update,
  };
})();
