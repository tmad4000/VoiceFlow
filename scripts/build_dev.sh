#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$PROJECT_DIR/VoiceFlow-Dev.app"
BINARY_SRC="$PROJECT_DIR/.build/debug/VoiceFlow"
BINARY_DST="$APP_BUNDLE/Contents/MacOS/VoiceFlow-Dev"
SIGNING_ID="Apple Development: Jacob Cole (4XF5KJRWL2)"
PLIST="$APP_BUNDLE/Contents/Info.plist"

echo "[build-dev] Building..."
cd "$PROJECT_DIR"
swift build 2>&1

echo "[build-dev] Copying binary into VoiceFlow-Dev.app..."
cp "$BINARY_SRC" "$BINARY_DST"

# Update CFBundleVersion with epoch timestamp so each build is unique
BUILD_NUM=$(date +%s)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$PLIST" 2>/dev/null || true
echo "[build-dev] CFBundleVersion = $BUILD_NUM"

echo "[build-dev] Codesigning with stable identity..."
codesign --force --sign "$SIGNING_ID" "$APP_BUNDLE"

echo "[build-dev] Restarting VoiceFlow-Dev..."
pkill -f "VoiceFlow-Dev" 2>/dev/null || true
sleep 0.5
open "$APP_BUNDLE"

echo "[build-dev] Done! VoiceFlow-Dev.app is running with stable signing."
echo "[build-dev] Accessibility permissions will persist across rebuilds."
