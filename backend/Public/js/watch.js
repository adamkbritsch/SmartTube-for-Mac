// Watch page: real IFrame playback + SponsorBlock auto-skip + DeArrow title +
// theater/speed controls, all reacting live to shared settings.
(function () {
  const vid = window.__VIDEO_ID__;
  const SPEEDS = [1, 1.25, 1.5, 1.75, 2];

  let detail = null;
  let player = null;
  let apiReady = false;
  let skipTimer = null;
  let adSkipped = false;

  const $ = (id) => document.getElementById(id);
  const elTitle = $("v-title"), elChannel = $("v-channel"), elDesc = $("desc"),
        elStatus = $("status"), elRecs = $("recs"), elPreroll = $("preroll"),
        elWatch = $("watch"), btnTheater = $("btn-theater"), btnSpeed = $("btn-speed");

  const CAT = {
    sponsor: "sponsor", selfpromo: "self-promo", interaction: "interaction reminder",
    intro: "intro", outro: "outro", preview: "recap", music_offtopic: "non-music",
  };

  // ── YouTube IFrame API ────────────────────────────────────────────────
  window.onYouTubeIframeAPIReady = function () { apiReady = true; createPlayer(); };

  function createPlayer() {
    if (player || !apiReady || !vid) return;
    player = new YT.Player("player", {
      videoId: vid,
      playerVars: { rel: 0, modestbranding: 1, playsinline: 1 },
      events: {
        onReady: (e) => { e.target.setPlaybackRate(MT.settings.playbackSpeed); startSkipLoop(); },
        onStateChange: (e) => { if (e.data === YT.PlayerState.PLAYING) startSkipLoop(); },
      },
    });
  }

  function startSkipLoop() {
    if (skipTimer) return;
    skipTimer = setInterval(() => {
      if (!player || !detail || !MT.settings.sponsorBlock) return;
      if (typeof player.getCurrentTime !== "function") return;
      const t = player.getCurrentTime();
      for (const seg of detail.sponsorSegments) {
        if (seg.actionType && seg.actionType !== "skip") continue;
        const start = seg.segment[0], end = seg.segment[1];
        if (t >= start && t < end - 0.3) {
          player.seekTo(end, true);
          toast("Skipped " + (CAT[seg.category] || seg.category));
          break;
        }
      }
    }, 300);
  }

  // ── Rendering ─────────────────────────────────────────────────────────
  function applyAll() {
    const s = MT.settings;
    // Title (DeArrow)
    const useDA = s.deArrow && detail && detail.deArrowTitle;
    elTitle.textContent = detail ? (useDA ? detail.deArrowTitle : detail.originalTitle) : "Loading…";
    elChannel.textContent = detail ? detail.channel : "";
    // Description + DeArrow note
    if (detail) {
      let html = "This is a MiniTube demo page playing the real video via the YouTube embed.";
      if (useDA) html += '<br><span class="da-note">DeArrow:</span> title replaced with the community version (original: "' + MT.esc(detail.originalTitle) + '").';
      elDesc.innerHTML = html;
    }
    // Theater
    elWatch.classList.toggle("theater", !!s.theaterMode);
    btnTheater.textContent = s.theaterMode ? "Default view" : "Theater";
    // Speed
    btnSpeed.textContent = "Speed " + s.playbackSpeed + "x";
    if (player && typeof player.setPlaybackRate === "function") player.setPlaybackRate(s.playbackSpeed);
    // Ad preroll (uBlock)
    if (s.adBlock) { elPreroll.style.display = "none"; }
    else if (!adSkipped) { elPreroll.style.display = "flex"; }
    // Status
    renderStatus();
  }

  function renderStatus() {
    const s = MT.settings;
    const segs = detail ? detail.sponsorSegments.length : 0;
    const daOn = s.deArrow && detail && detail.deArrowTitle;
    const on = (b) => b ? '<span class="on">on</span>' : '<span class="off">off</span>';
    elStatus.innerHTML =
      "SponsorBlock: " + on(s.sponsorBlock) + " (" + segs + " segments) &nbsp;|&nbsp; " +
      "DeArrow: " + on(!!daOn) + " &nbsp;|&nbsp; " +
      "Ad&nbsp;Block: " + on(s.adBlock) + " &nbsp;|&nbsp; " +
      "Theme: " + MT.esc(s.theme);
  }

  function toast(msg) {
    const t = document.createElement("div");
    t.className = "toast";
    t.textContent = msg;
    $("toasts").appendChild(t);
    setTimeout(() => t.remove(), 2600);
  }

  // ── Recommendations ───────────────────────────────────────────────────
  async function loadRecs() {
    try {
      const r = await fetch("/api/videos", { cache: "no-store" });
      const vids = (await r.json()).filter((v) => v.id !== vid);
      renderRecs(vids);
      MT.onChange(() => renderRecs(vids));
    } catch (e) { /* ignore */ }
  }
  function renderRecs(vids) {
    const s = MT.settings;
    elRecs.innerHTML = "";
    vids.forEach((v) => {
      const useDA = s.deArrow && v.deArrowTitle;
      const title = useDA ? v.deArrowTitle : v.originalTitle;
      const thumb = (s.deArrow && v.deArrowThumbnail) ? v.deArrowThumbnail : v.originalThumbnail;
      const a = document.createElement("a");
      a.className = "rec";
      a.href = "/watch?v=" + encodeURIComponent(v.id);
      a.innerHTML =
        '<img class="rthumb" loading="lazy" src="' + MT.esc(thumb) + '" ' +
          'onerror="this.onerror=null;this.src=\'' + MT.esc(v.originalThumbnail) + '\'" alt="">' +
        '<div><div class="rtitle">' + MT.esc(title) + '</div>' +
        '<div class="rsub">' + MT.esc(v.channel) + '</div>' +
        '<div class="rsub">1.2M views</div></div>';
      elRecs.appendChild(a);
    });
  }

  // ── Load detail ───────────────────────────────────────────────────────
  async function loadDetail() {
    try {
      const r = await fetch("/api/videos/" + encodeURIComponent(vid), { cache: "no-store" });
      detail = await r.json();
    } catch (e) { detail = null; }
    applyAll();
  }

  // ── Controls (write shared settings so they cross to other clients) ─────
  btnTheater.addEventListener("click", () => MT.update({ theaterMode: !MT.settings.theaterMode }));
  btnSpeed.addEventListener("click", () => {
    const i = SPEEDS.indexOf(MT.settings.playbackSpeed);
    MT.update({ playbackSpeed: SPEEDS[(i + 1) % SPEEDS.length] });
  });
  $("skip-ad").addEventListener("click", () => { adSkipped = true; elPreroll.style.display = "none"; });

  MT.onChange(applyAll);
  MT.start();
  loadDetail();
  loadRecs();
})();
