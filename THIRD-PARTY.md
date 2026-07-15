# Third-party components

MiniTube's own code is MIT-licensed (see `LICENSE`). It relies on the
components below, which keep their own licenses. The browser extensions are
**not committed to this repository** — `package.sh` downloads them from their
official release pages at build time and copies them into the app bundle.

## Bundled at build time (via `package.sh`)

| Component | Version | License | Source |
|---|---|---|---|
| **uBlock Origin** | 1.72.2 (Chromium MV2 build) | GPL-3.0 | https://github.com/gorhill/uBlock |
| **SponsorBlock** | 6.1.7 (Chrome build) | LGPL-3.0 | https://github.com/ajayyy/SponsorBlock |

- uBlock Origin ships its full source in the extension package (`LICENSE.txt`
  is included in the downloaded build), satisfying GPL-3.0's source-availability
  requirement. See https://github.com/gorhill/uBlock/blob/master/LICENSE.txt
- SponsorBlock is LGPL-3.0: https://github.com/ajayyy/SponsorBlock/blob/master/LICENSE
- **MiniTube patch to uBlock Origin:** `patches/mt-shim.js` is added as the
  first background script (it stubs a few `chrome.*` APIs so uBO's dashboard
  works inside `WKWebExtension`). This patch is applied by `package.sh` after
  the pristine release is downloaded; the patch source is MIT (this repo).

## Runtime services (network, not bundled)

- **SponsorBlock / DeArrow API** — `sponsor.ajay.app` (community sponsor
  segments + crowd-sourced titles/thumbnails).
- **EasyList** — the ad-block cosmetic filter list, re-downloaded periodically.
- **YouTube** — the real `youtube.com` watch page (WKWebView) and YouTube's
  internal InnerTube API, called with your own logged-in session. MiniTube is
  not affiliated with, authorized by, or endorsed by YouTube or Google.
