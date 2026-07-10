#!/usr/bin/env bash
set -euo pipefail

# Builds ClaudeUsageBar and packages it into build/ClaudeUsageBar.dmg. The image
# contains both halves of the tool plus install instructions:
#   ClaudeUsageBar.app   - drag to Applications
#   Applications         - symlink, for the drag target
#   Extension/           - the browser extension to load unpacked
#   INSTALL.txt          - step-by-step setup
# Run ./package.sh, then open build/ClaudeUsageBar.dmg.

cd "$(dirname "$0")"

./build.sh

APP="build/ClaudeUsageBar.app"
DMG="build/ClaudeUsageBar.dmg"
STAGING="build/dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp -R Extension "$STAGING/Extension"

cat > "$STAGING/INSTALL.txt" <<'TXT'
ClaudeUsageBar - Install
========================

ClaudeUsageBar shows your Claude.ai usage limits in the macOS menu bar. It has
two parts: the menu bar app and a browser extension. You need both.


1. Install the menu bar app
---------------------------
- Drag ClaudeUsageBar.app onto the Applications folder in this window.
- Open Applications and launch ClaudeUsageBar (right-click > Open the first
  time if macOS warns about an unidentified developer).
- Allow notifications when asked (used to warn you near your limit).
- It appears in the menu bar with no Dock icon, showing "Claude --" until the
  extension sends data.


2. Install the browser extension (Chrome, Edge, Brave, Arc)
-----------------------------------------------------------
IMPORTANT: first copy the Extension folder OUT of this disk image to a permanent
location, e.g. your home folder or Documents. An unpacked extension must stay on
disk - if you load it from this disk image it breaks as soon as the image is
ejected.

- Drag the "Extension" folder from this window to, say, your Documents folder.
- Open chrome://extensions in your browser.
- Turn on "Developer mode" (top right).
- Click "Load unpacked" and select the Extension folder you just copied.
- Open or reload a logged-in https://claude.ai tab.
- Optional: to also track ChatGPT Codex usage, keep a logged-in
  https://chatgpt.com tab open and enable the Codex title toggles in Settings.


That's it
---------
The menu bar starts updating within a minute. It reads your usage from your own
logged-in claude.ai (and optionally chatgpt.com) session and sends it only to
127.0.0.1 on your own machine. Keep one claude.ai tab open; the usage settings
page does NOT need to be open.

To start the app automatically at login: menu bar icon > Settings > Start at
login (works best once the app lives in /Applications).
TXT

# Window/background geometry. The background is resized to WIN_W x WIN_H points
# and the icons are positioned onto the slots drawn in it (measured as fractions
# of the image: A app, B Applications, C Extension, D INSTALL.txt).
BG_SRC="assets/dmg-background.png"
WIN_W=800
WIN_H=549
ICON_SIZE=96

if [ -f "$BG_SRC" ]; then
    mkdir -p "$STAGING/.background"
    sips -z "$WIN_H" "$WIN_W" "$BG_SRC" --out "$STAGING/.background/background.png" >/dev/null

    # Slot centres, in points (fraction * window size).
    ax=$((WIN_W * 23 / 100));  ay=$((WIN_H * 335 / 1000))
    bx=$((WIN_W * 78 / 100));  by=$((WIN_H * 335 / 1000))
    cx=$((WIN_W * 315 / 1000)); cy=$((WIN_H * 69 / 100))
    dx=$((WIN_W * 78 / 100));  dy=$((WIN_H * 69 / 100))
    win_left=200; win_top=150
    win_right=$((win_left + WIN_W)); win_bottom=$((win_top + WIN_H))

    # Build a read/write image, lay it out in Finder, then compress it.
    RW="build/rw.dmg"
    # Finder only persists the .DS_Store window layout for volumes mounted under
    # /Volumes, so let it mount at the default location (not a custom mountpoint).
    MOUNT="/Volumes/ClaudeUsageBar"
    rm -f "$RW"
    [ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
    hdiutil create -srcfolder "$STAGING" -volname "ClaudeUsageBar" \
        -fs HFS+ -format UDRW -ov "$RW" >/dev/null
    hdiutil attach "$RW" -readwrite -noverify -noautoopen >/dev/null

    # Finder layout. Requires permission to control Finder; if that is denied the
    # image still builds, just without the custom window arrangement.
    osascript <<OSA || echo "Note: Finder layout skipped (allow Automation control of Finder in System Settings > Privacy & Security > Automation, then re-run ./package.sh)."
tell application "Finder"
    tell disk "ClaudeUsageBar"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {${win_left}, ${win_top}, ${win_right}, ${win_bottom}}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to ${ICON_SIZE}
        set text size of opts to 12
        set background picture of opts to (POSIX file "${MOUNT}/.background/background.png" as alias)
        set position of item "ClaudeUsageBar.app" of container window to {${ax}, ${ay}}
        set position of item "Applications" of container window to {${bx}, ${by}}
        set position of item "Extension" of container window to {${cx}, ${cy}}
        set position of item "INSTALL.txt" of container window to {${dx}, ${dy}}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA

    sleep 2 # let Finder flush the .DS_Store to the volume
    sync
    hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null 2>&1
    rm -f "$DMG"
    hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
    rm -f "$RW"
else
    echo "Note: $BG_SRC not found, building a plain image."
    hdiutil create \
        -volname "ClaudeUsageBar" \
        -srcfolder "$STAGING" \
        -ov -format UDZO \
        "$DMG" >/dev/null
fi

rm -rf "$STAGING"

echo "Built $DMG"
