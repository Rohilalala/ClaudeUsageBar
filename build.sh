#!/usr/bin/env bash
set -euo pipefail

# Builds the ClaudeUsageBar menu bar app into build/ClaudeUsageBar.app.
# Idempotent: the build directory is recreated from scratch every run.

cd "$(dirname "$0")"

APP="build/ClaudeUsageBar.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

rm -rf build
mkdir -p "$MACOS_DIR" "$RES_DIR"

swiftc -O MenuBarApp/main.swift -o "$MACOS_DIR/ClaudeUsageBar"

# App icon (Finder, Get Info, the DMG, notifications). The menu bar itself shows
# text, not this icon.
bash assets/make-icns.sh "$RES_DIR/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.claudeusagebar.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc code signature. SMAppService (start-at-login) and UNUserNotificationCenter
# (usage notifications) both refuse to operate from an unsigned bundle; an ad-hoc
# signature is enough for local use.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
