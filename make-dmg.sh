#!/bin/bash
# Build SmartTube.dmg — a drag-to-Applications disk image. Self-contained: only needs the
# built SmartTube.app (run ./package.sh first) and hdiutil (built in). The Finder-layout step
# is best-effort; if automation is unavailable the DMG is still fully functional (app +
# Applications symlink, just default icon positions).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$REPO/SmartTube.app"
VOL="SmartTube"
DMG="$REPO/SmartTube.dmg"
BG="$REPO/assets/dmg-background.png"

[ -d "$APP" ] || { echo "SmartTube.app not found — run ./package.sh first"; exit 1; }

STAGE="$(mktemp -d)"; RW="$(mktemp -u).dmg"
trap 'rm -rf "$STAGE" "$RW"' EXIT

cp -R "$APP" "$STAGE/SmartTube.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"; [ -f "$BG" ] && cp "$BG" "$STAGE/.background/bg.png"

rm -f "$DMG"
# Read-write image sized to the payload (+ headroom) so we can lay it out.
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -o '/Volumes/[^ ]*' | tail -1)"

osascript <<OSA 2>/dev/null || echo "  (Finder layout skipped — DMG still works)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 500}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 100
    try
      set background picture of opts to file ".background:bg.png"
    end try
    set position of item "SmartTube.app" of container window to {140, 205}
    set position of item "Applications" of container window to {400, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA

sync
hdiutil detach "$MOUNT" >/dev/null 2>&1 || diskutil unmount force "$MOUNT" >/dev/null 2>&1 || true
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
echo "built: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
