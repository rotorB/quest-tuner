#!/usr/bin/env bash
# Builds Quest Tuner and wraps the binary into build/Quest Tuner.app.
# Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Quest Tuner.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/QuestTuner "$APP/Contents/MacOS/QuestTuner"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>QuestTuner</string>
    <key>CFBundleIdentifier</key><string>local.questtuner</string>
    <key>CFBundleName</key><string>Quest Tuner</string>
    <key>CFBundleDisplayName</key><string>Quest Tuner</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/Quest Tuner.app"
  osascript -e 'quit app "Quest Tuner"' >/dev/null 2>&1 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed: $DEST"
fi
