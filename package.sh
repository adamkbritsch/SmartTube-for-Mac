#!/bin/bash
# Package MiniTube's SwiftUI front-end + Vapor backend into a real, double-clickable
# YouTube.app (icon, Dock presence, self-launching backend) and install to /Applications.
set -euo pipefail

# Repo root = the directory this script lives in (portable; no hardcoded path).
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$REPO/YouTube.app"
# Bundle id is overridable so forks don't collide; default is generic.
BUNDLE_ID="${MT_BUNDLE_ID:-com.minitube.youtube}"

# ── Vendored extensions: fetched at build (kept out of the repo) ──────────────
# uBlock Origin (GPLv3) and SponsorBlock (LGPL-3.0) are downloaded from their
# official releases on first build, not committed. uBO gets one MiniTube patch:
# mt-shim.js loaded first in background.html (stubs chrome.privacy etc. so the
# dashboard works under WKWebExtension). See patches/ + THIRD-PARTY.md.
UBO_VER="1.72.2"
SB_VER="6.1.7"
EXT="$REPO/extensions"

fetch_ubo() {
  [ -f "$EXT/ubo/manifest.json" ] && return 0
  echo "==> fetching uBlock Origin $UBO_VER (GPLv3)"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/ubo.zip" \
    "https://github.com/gorhill/uBlock/releases/download/$UBO_VER/uBlock0_$UBO_VER.chromium.zip"
  unzip -q "$tmp/ubo.zip" -d "$tmp"
  rm -rf "$EXT/ubo"; mkdir -p "$EXT/ubo"
  cp -R "$tmp/uBlock0.chromium/." "$EXT/ubo/"
  # MiniTube patch: load mt-shim.js as the FIRST background script.
  cp "$REPO/patches/mt-shim.js" "$EXT/ubo/mt-shim.js"
  perl -0pi -e 's#(<script src="lib/lz4/)#<script src="mt-shim.js"></script>\n<script src="lib/lz4/#' \
    "$EXT/ubo/background.html"
  rm -rf "$tmp"
}

fetch_sb() {
  [ -f "$EXT/sponsorblock/manifest.json" ] && return 0
  echo "==> fetching SponsorBlock $SB_VER (LGPL-3.0)"
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/sb.zip" \
    "https://github.com/ajayyy/SponsorBlock/releases/download/$SB_VER/ChromeExtension.zip"
  rm -rf "$EXT/sponsorblock"; mkdir -p "$EXT/sponsorblock"
  unzip -q "$tmp/sb.zip" -d "$EXT/sponsorblock"
  rm -rf "$tmp"
}

fetch_ubo
fetch_sb

echo "==> building front-end (release)"
swift build -c release --package-path "$REPO/macos"
echo "==> building backend (release)"
swift build -c release --package-path "$REPO/backend"

APP_BIN="$REPO/macos/.build/release/MiniTube"
SRV_BIN="$REPO/backend/.build/release/App"
[ -x "$APP_BIN" ] || { echo "missing app binary: $APP_BIN"; exit 1; }
[ -x "$SRV_BIN" ] || { echo "missing backend binary: $SRV_BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Server"
cp "$APP_BIN" "$APP/Contents/MacOS/YouTube"
cp "$SRV_BIN" "$APP/Contents/Resources/Server/App"   # backend auto-spawned by the app
cp "$REPO/YouTube.icns" "$APP/Contents/Resources/YouTube.icns"
cp "$REPO/smarttube-logo.png" "$APP/Contents/Resources/smarttube-logo.png"   # in-app header wordmark
cp -R "$EXT/ubo" "$APP/Contents/Resources/uBO"                   # real uBlock Origin (scriptlets/cosmetics)
cp -R "$EXT/sponsorblock" "$APP/Contents/Resources/SponsorBlock" # real SponsorBlock
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>YouTube</string>
  <key>CFBundleDisplayName</key><string>YouTube</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>YouTube</string>
  <key>CFBundleIconFile</key><string>YouTube</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "==> installing to /Applications"
# Never swap the bundle out from under a running instance (corrupts the live image
# and leaves an old process serving a deleted bundle).
if pgrep -f "/Applications/YouTube.app/Contents/MacOS/YouTube" >/dev/null 2>&1; then
  echo "==> quitting running YouTube.app first"
  osascript -e 'tell application "YouTube" to quit' 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "/Applications/YouTube.app/Contents/MacOS/YouTube" >/dev/null 2>&1 || break
    sleep 0.5
  done
  pkill -9 -f "/Applications/YouTube.app/Contents/MacOS/YouTube" 2>/dev/null || true
fi
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -u "/Applications/YouTube.app" 2>/dev/null || true   # drop the OLD registration first (avoids stale icon cache)
rm -rf "/Applications/YouTube.app"
cp -R "$APP" "/Applications/YouTube.app"
touch "/Applications/YouTube.app"
"$LSREG" -f "/Applications/YouTube.app" 2>/dev/null || true

echo "==> done → /Applications/YouTube.app"
