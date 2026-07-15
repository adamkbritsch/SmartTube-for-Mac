// Player + custom YouTube-style controls (YouTube's own controls are hidden with
// controls:0 so this doesn't look like an embed). Captions default OFF. Fullscreen
// is bridged to the native app.
(function () {
  const vid = window.__VIDEO_ID__;
  const $ = (id) => document.getElementById(id);
  const box = $("player-box");
  let detail = null, player = null, apiReady = false;
  let skipTimer = null, hideTimer = null, progTimer = null;
  let ccOn = false, dragging = false, adSkipped = false;

  const CAT = { sponsor: "sponsor", selfpromo: "self-promo", interaction: "interaction",
    intro: "intro", outro: "outro", preview: "recap", music_offtopic: "non-music" };

  const S = (p) => '<svg viewBox="0 0 24 24">' + p + '</svg>';
  const ICON = {
    play: S('<path d="M8 5v14l11-7z"/>'),
    pause: S('<path d="M6 5h4v14H6zM14 5h4v14h-4z"/>'),
    next: S('<path d="M6 6l8.5 6L6 18V6zM16 6h2v12h-2z"/>'),
    volHigh: S('<path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4zM14 3.2v2.1a7 7 0 0 1 0 13.4v2.1a9 9 0 0 0 0-17.6z"/>'),
    volMute: S('<path d="M3 9v6h4l5 5V4L7 9H3zm18.5 3l-1.4-1.4L18 12.6 15.9 10.5 14.5 12l2.1 2.1-2.1 2.1 1.4 1.4L18 15.4l2.1 2.2 1.4-1.4L19.4 14z"/>'),
    cc: S('<path d="M19 4H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2zm-8 7H9.5v-.5h-2v3h2V13H11v1a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v1zm7 0h-1.5v-.5h-2v3h2V13H18v1a1 1 0 0 1-1 1h-3a1 1 0 0 1-1-1v-4a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v1z"/>'),
    gear: S('<path d="M19.4 13a7.8 7.8 0 0 0 0-2l2-1.6-2-3.4-2.4 1a7.6 7.6 0 0 0-1.7-1L14.9 2h-3.8l-.4 2.5a7.6 7.6 0 0 0-1.7 1l-2.4-1-2 3.4L4.6 11a7.8 7.8 0 0 0 0 2l-2 1.6 2 3.4 2.4-1a7.6 7.6 0 0 0 1.7 1l.4 2.5h3.8l.4-2.5a7.6 7.6 0 0 0 1.7-1l2.4 1 2-3.4-2-1.6zM12 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7z"/>'),
    mini: S('<path d="M21 3H3a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h18a2 2 0 0 0 2-2V5a2 2 0 0 0-2-2zm0 16H3V5h18v14zm-3-8h-6v4h6v-4z"/>'),
    theater: S('<path d="M19 6H5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zm0 10H5V8h14v8z"/>'),
    fs: S('<path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/>'),
    bigplay: '<svg viewBox="0 0 36 36"><circle cx="18" cy="18" r="18"/><path class="tri" d="M14 11l12 7-12 7z"/></svg>',
  };

  window.onYouTubeIframeAPIReady = function () { apiReady = true; createPlayer(); };

  function createPlayer() {
    if (player || !apiReady || !vid) return;
    player = new YT.Player("player", {
      videoId: vid,
      playerVars: { controls: 0, rel: 0, modestbranding: 1, playsinline: 1, autoplay: 1, fs: 0,
        iv_load_policy: 3, cc_load_policy: 0, disablekb: 1 },
      events: { onReady: onReady, onStateChange: onState, onApiChange: onApiChange },
    });
  }

  // Fires when modules (incl. captions) load — disable captions unless the user turned them on.
  function onApiChange() { if (!ccOn) disableCaptions(); }
  function disableCaptions() {
    try { player.setOption("captions", "track", {}); } catch (e) {}
    try { player.setOption("cc", "track", {}); } catch (e) {}
    try { player.unloadModule("captions"); } catch (e) {}
    try { player.unloadModule("cc"); } catch (e) {}
  }
  function enableCaptions() {
    try { player.loadModule("captions"); } catch (e) {}
    try { player.loadModule("cc"); } catch (e) {}
    let tl = [];
    try { tl = player.getOption("captions", "tracklist") || []; } catch (e) {}
    const track = tl.find((t) => t.languageCode === "en") || tl[0] || { languageCode: "en" };
    try { player.setOption("captions", "track", track); } catch (e) {}
    try { player.setOption("cc", "track", track); } catch (e) {}
  }

  const POS_KEY = "mt_pos_" + vid;
  let lastSave = 0;

  function onReady() {
    disableCaptions();                                        // captions OFF by default
    player.setPlaybackRate(MT.settings.playbackSpeed);
    player.playVideo();
    // Resume where the other player instance (fullscreen ↔ watch page) left off.
    const saved = parseFloat(localStorage.getItem(POS_KEY) || "0");
    if (saved > 1) { try { player.seekTo(saved, true); } catch (e) {} }
    setIcons();
    wire();
    applyAd();
    startSkipLoop();
    progTimer = setInterval(tick, 200);
    updatePlay();
    updateVolIcon();
    showControls();
  }

  function setIcons() {
    $("play").innerHTML = ICON.play; $("next").innerHTML = ICON.next; $("mute").innerHTML = ICON.volHigh;
    $("cc").innerHTML = ICON.cc; $("settings").innerHTML = ICON.gear; $("miniplayer").innerHTML = ICON.mini;
    $("theater").innerHTML = ICON.theater; $("fullscreen").innerHTML = ICON.fs; $("bigplay").innerHTML = ICON.bigplay;
  }

  function onState(e) { updatePlay(); if (e.data === YT.PlayerState.PLAYING) startSkipLoop(); scheduleHide(); }

  function playing() { const s = player.getPlayerState && player.getPlayerState(); return s === 1 || s === 3; }
  function updatePlay() { const p = playing(); $("play").innerHTML = p ? ICON.pause : ICON.play; $("bigplay").hidden = p; }
  function updateVolIcon() { const muted = player.isMuted && (player.isMuted() || player.getVolume() === 0); $("mute").innerHTML = muted ? ICON.volMute : ICON.volHigh; }

  function fmt(t) {
    t = Math.max(0, Math.floor(t || 0));
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60, p = (n) => String(n).padStart(2, "0");
    return h > 0 ? h + ":" + p(m) + ":" + p(s) : m + ":" + p(s);
  }

  function tick() {
    if (!player.getCurrentTime) return;
    const cur = player.getCurrentTime() || 0, dur = player.getDuration() || 0;
    if (!dragging && dur > 0) { const pct = cur / dur * 100; $("played").style.width = pct + "%"; $("scrub").style.left = pct + "%"; }
    $("buffered").style.width = ((player.getVideoLoadedFraction && player.getVideoLoadedFraction() || 0) * 100) + "%";
    $("time").innerHTML = fmt(cur) + "&nbsp;/&nbsp;" + fmt(dur);
    // Persist position (~1s) so toggling fullscreen resumes instead of restarting.
    if (cur > 0 && Date.now() - lastSave > 900) { lastSave = Date.now(); try { localStorage.setItem(POS_KEY, String(cur)); } catch (e) {} }
  }

  function trackRect() { return $("progress").querySelector(".ctl-track").getBoundingClientRect(); }
  function fracAt(x) { const r = trackRect(); return Math.min(1, Math.max(0, (x - r.left) / r.width)); }

  function wire() {
    $("play").onclick = togglePlay;
    $("click-layer").onclick = togglePlay;
    $("click-layer").ondblclick = () => bridge("fullscreen");
    $("next").onclick = () => player.seekTo(0, true);
    $("mute").onclick = () => { if (player.isMuted()) player.unMute(); else player.mute(); updateVolIcon(); };
    $("vol").oninput = (e) => { const v = +e.target.value; player.setVolume(v); if (v > 0) player.unMute(); else player.mute(); updateVolIcon(); };
    $("cc").onclick = toggleCC;
    $("settings").onclick = toggleMenu;
    $("fullscreen").onclick = () => bridge("fullscreen");
    $("theater").onclick = () => bridge("fullscreen");
    $("miniplayer").onclick = () => {};
    const prog = $("progress");
    prog.onmousedown = (e) => { dragging = true; seekAt(e.clientX); };
    document.addEventListener("mousemove", (e) => { if (dragging) seekAt(e.clientX); });
    document.addEventListener("mouseup", () => { dragging = false; });
    prog.onmousemove = (e) => {
      const f = fracAt(e.clientX); $("hoverbar").style.width = f * 100 + "%";
      const ht = $("hovertime"); ht.style.display = "block"; ht.style.left = (e.clientX - trackRect().left) + "px";
      ht.textContent = fmt(f * (player.getDuration() || 0));
    };
    prog.onmouseleave = () => { $("hovertime").style.display = "none"; $("hoverbar").style.width = "0"; };
    box.addEventListener("mousemove", showControls);
    box.addEventListener("mouseleave", () => { if (playing()) box.classList.add("hide-ui"); });
    $("skip-ad").onclick = () => { adSkipped = true; $("preroll").style.display = "none"; };
    MT.onChange(() => { applyAd(); if (player.setPlaybackRate) player.setPlaybackRate(MT.settings.playbackSpeed); });
  }

  function togglePlay() { if (playing()) player.pauseVideo(); else player.playVideo(); updatePlay(); showControls(); }
  function seekAt(x) { const f = fracAt(x); $("played").style.width = f * 100 + "%"; $("scrub").style.left = f * 100 + "%"; player.seekTo(f * (player.getDuration() || 0), true); }

  function toggleCC() {
    ccOn = !ccOn;
    if (ccOn) enableCaptions(); else disableCaptions();
    $("cc").classList.toggle("on", ccOn);
  }

  function toggleMenu() {
    const m = $("menu");
    if (!m.hidden) { m.hidden = true; return; }
    const speeds = [0.25, 0.5, 1, 1.25, 1.5, 1.75, 2], cur = player.getPlaybackRate();
    m.innerHTML = '<div class="row" style="font-weight:600;cursor:default">Playback speed</div>' +
      speeds.map((s) => '<div class="row opt ' + (s === cur ? "sel" : "") + '" data-speed="' + s + '"><span>' + (s === 1 ? "Normal" : s + "x") + "</span></div>").join("");
    m.querySelectorAll("[data-speed]").forEach((el) => el.onclick = () => {
      player.setPlaybackRate(+el.dataset.speed); MT.update({ playbackSpeed: +el.dataset.speed }); m.hidden = true;
    });
    m.hidden = false;
  }

  function bridge(action) { try { window.webkit.messageHandlers.minitube.postMessage({ action: action }); } catch (e) {} }

  function showControls() { box.classList.remove("hide-ui"); scheduleHide(); }
  function scheduleHide() {
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => { if (playing() && $("menu").hidden) box.classList.add("hide-ui"); }, 3000);
  }

  function applyAd() { const pr = $("preroll"); if (MT.settings.adBlock) pr.style.display = "none"; else if (!adSkipped) pr.style.display = "flex"; }
  function startSkipLoop() {
    if (skipTimer) return;
    skipTimer = setInterval(() => {
      if (!player || !detail || !MT.settings.sponsorBlock || typeof player.getCurrentTime !== "function") return;
      const t = player.getCurrentTime();
      for (const seg of detail.sponsorSegments) {
        if (seg.actionType && seg.actionType !== "skip") continue;
        if (t >= seg.segment[0] && t < seg.segment[1] - 0.3) { player.seekTo(seg.segment[1], true); toast("Skipped " + (CAT[seg.category] || seg.category)); break; }
      }
    }, 300);
  }
  function toast(msg) { const t = document.createElement("div"); t.className = "toast"; t.textContent = msg; $("toasts").appendChild(t); setTimeout(() => t.remove(), 2600); }

  async function loadDetail() { try { detail = await (await fetch("/api/videos/" + encodeURIComponent(vid), { cache: "no-store" })).json(); } catch (e) { detail = null; } }

  MT.start();
  loadDetail();
})();
