// Companion popup: reads + writes the shared MiniTube settings. Every change is a
// PATCH to the backend, which the web clone and the macOS app both read — so a flip
// here propagates to all clients.
const API = "http://127.0.0.1:8080";
const statusEl = document.getElementById("status");

async function getSettings() {
  const r = await fetch(API + "/api/settings", { cache: "no-store" });
  if (!r.ok) throw new Error("HTTP " + r.status);
  return r.json();
}

async function patch(obj) {
  const r = await fetch(API + "/api/settings", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(obj),
  });
  if (!r.ok) throw new Error("HTTP " + r.status);
  return r.json();
}

function apply(s) {
  document.querySelectorAll("input[type=checkbox][data-key]").forEach((cb) => {
    const k = cb.dataset.key;
    cb.checked = k === "theme" ? s.theme === "light" : !!s[k];
  });
  document.querySelectorAll("[data-speed]").forEach((b) => {
    b.classList.toggle("active", parseFloat(b.dataset.speed) === s.playbackSpeed);
  });
  document.querySelectorAll("[data-enhance]").forEach((b) => {
    b.classList.toggle("active", b.dataset.enhance === (s.enhance || "off"));
  });
  statusEl.textContent = "Connected · localhost:8080";
  statusEl.className = "status ok";
}

async function refresh() {
  try { apply(await getSettings()); }
  catch (e) {
    statusEl.textContent = "Backend offline — start the MiniTube server";
    statusEl.className = "status err";
  }
}

document.querySelectorAll("input[type=checkbox][data-key]").forEach((cb) => {
  cb.addEventListener("change", async () => {
    const k = cb.dataset.key;
    const body = k === "theme" ? { theme: cb.checked ? "light" : "dark" } : { [k]: cb.checked };
    try { apply(await patch(body)); } catch (e) { refresh(); }
  });
});

document.querySelectorAll("[data-speed]").forEach((b) => {
  b.addEventListener("click", async () => {
    try { apply(await patch({ playbackSpeed: parseFloat(b.dataset.speed) })); } catch (e) { refresh(); }
  });
});

document.querySelectorAll("[data-enhance]").forEach((b) => {
  b.addEventListener("click", async () => {
    try { apply(await patch({ enhance: b.dataset.enhance })); } catch (e) { refresh(); }
  });
});

refresh();
setInterval(refresh, 2000);   // reflect changes made elsewhere (web UI, macOS app)
