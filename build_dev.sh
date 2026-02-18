#!/bin/bash
set -e

# Development build script for VoiceFlow
# Uses Apple Development signing identity for persistent TCC permissions

# Build identity (always advances, even for rapid rebuilds in the same second)
VERSION_SOURCE_FILE="Sources/Version.swift"
SHORT_VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "${VERSION_SOURCE_FILE}" | head -n 1)
if [ -z "${SHORT_VERSION}" ]; then
  SHORT_VERSION="0.2.0"
fi
COUNTER_FILE=".build/dev_build_counter"
mkdir -p .build
CURRENT_TS=$(date +%Y%m%d%H%M%S)
LAST_TS=0
if [ -f "${COUNTER_FILE}" ]; then
  LAST_TS=$(cat "${COUNTER_FILE}" 2>/dev/null || echo 0)
fi
if [ "${CURRENT_TS}" -le "${LAST_TS}" ]; then
  BUILD_NUMBER=$((LAST_TS + 1))
else
  BUILD_NUMBER="${CURRENT_TS}"
fi
echo "${BUILD_NUMBER}" > "${COUNTER_FILE}"

echo "Building VoiceFlow (debug)..."
swift build --arch arm64

# Define paths
APP_NAME="VoiceFlow"
DEV_APP_NAME="VoiceFlow-Dev"
APP_BUNDLE="${DEV_APP_NAME}.app"
BINARY_PATH=".build/arm64-apple-macosx/debug/${APP_NAME}"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS="VoiceFlow-Dev.entitlements"

# Signing identity options:
# 1. Ad-hoc ("-") - Works but permissions reset on each rebuild
# 2. "Apple Development: Jacob Cole (4XF5KJRWL2)" - Persistent permissions
#
# Using Apple Development to keep TCC permissions stable across rebuilds.
SIGNING_IDENTITY="Apple Development: Jacob Cole (4XF5KJRWL2)"

# Create App Bundle Structure
echo "Creating App Bundle..."
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy Binary
echo "Copying Binary..."
cp "${BINARY_PATH}" "${MACOS_DIR}/${DEV_APP_NAME}"

# Create Dev Info.plist (with dev bundle ID for separate TCC permissions from release)
echo "Creating Dev Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VoiceFlow-Dev</string>
    <key>CFBundleIdentifier</key>
    <string>com.jacobcole.voiceflow.dev</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key>
    <string>${SHORT_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>VoiceFlow-Dev</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceFlow needs access to your microphone for speech recognition and voice commands.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>VoiceFlow uses speech recognition for real-time transcription.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>VoiceFlow needs permission to send keyboard events to other applications.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Convert Info.plist to binary format
plutil -convert binary1 "${CONTENTS_DIR}/Info.plist"

# Sign with entitlements for proper TCC recognition
echo "Signing with: ${SIGNING_IDENTITY}"
codesign --force --sign "${SIGNING_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_BUNDLE}" 2>&1

# Verify signature
echo ""
echo "Signature verification:"
codesign -dv "${APP_BUNDLE}" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" || true
echo ""
echo "Entitlements:"
codesign -d --entitlements - "${APP_BUNDLE}" 2>&1 | head -20 || true

echo ""
echo "✅ Development build complete: ${APP_BUNDLE}"
echo "Version: ${SHORT_VERSION} (dev.${BUILD_NUMBER})"
echo ""
echo "Note: Using Apple Development signing. TCC permissions should persist across rebuilds."
echo "To run: open ${APP_BUNDLE}"
