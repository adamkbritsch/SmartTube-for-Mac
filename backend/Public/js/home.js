// Home feed: render the catalog, apply the DeArrow toggle live, and drop a fake ad
// unit that uBlock (Ad Block) hides.
(function () {
  const grid = document.getElementById("grid");
  let videos = [];

  function card(v) {
    const s = MT.settings;
    const useDA = s.deArrow && !!v.deArrowTitle;
    const title = useDA ? v.deArrowTitle : v.originalTitle;
    const thumb = (s.deArrow && v.deArrowThumbnail) ? v.deArrowThumbnail : v.originalThumbnail;
    const a = document.createElement("a");
    a.className = "card" + (useDA ? " dearrowed" : "");
    a.href = "/watch?v=" + encodeURIComponent(v.id);
    a.innerHTML =
      '<div class="thumb-wrap">' +
        '<img loading="lazy" src="' + MT.esc(thumb) + '" alt="" ' +
          'onerror="this.onerror=null;this.src=\'' + MT.esc(v.originalThumbnail) + '\'">' +
        '<span class="da-badge">DeArrow</span>' +
      '</div>' +
      '<div class="meta">' +
        '<div class="ch-avatar"></div>' +
        '<div>' +
          '<p class="title">' + MT.esc(title) + '</p>' +
          '<div class="sub">' + MT.esc(v.channel) + '</div>' +
          '<div class="sub">1.2M views &middot; 3 days ago</div>' +
        '</div>' +
      '</div>';
    return a;
  }

  function adCard() {
    const d = document.createElement("div");
    d.className = "mt-ad-card adsbygoogle";
    d.innerHTML = '<span class="tag">Ad</span>' +
      '<span class="txt">Sponsored placement &mdash; hidden automatically when uBlock (Ad&nbsp;Block) is on.</span>';
    return d;
  }

  function render() {
    grid.innerHTML = "";
    videos.forEach((v, i) => {
      if (i === 3) grid.appendChild(adCard());
      grid.appendChild(card(v));
    });
    MT.applyUblock();
  }

  async function load() {
    try {
      const r = await fetch("/api/videos", { cache: "no-store" });
      videos = await r.json();
      render();
    } catch (e) {
      grid.innerHTML = '<p style="color:var(--muted)">Backend unreachable at /api/videos.</p>';
    }
  }

  MT.onChange(render);
  MT.start();
  load();
})();
