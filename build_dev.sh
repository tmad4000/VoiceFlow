#!/bin/bash
set -e

# Development build script for VoiceFlow
# Uses Apple Development signing identity for persistent TCC permissions

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
# 2. "Apple Development: jacob@ideapad.io (3A8J2544R7)" - Persistent permissions but needs investigation
#
# Using ad-hoc for now since developer signing causes launch failures
# TODO: Investigate why developer signing causes "Launchd job spawn failed" error
SIGNING_IDENTITY="-"

# Create App Bundle Structure only if it doesn't exist
# This preserves the bundle identity so permissions persist
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "Creating Dev App Bundle (first time only)..."
    mkdir -p "${MACOS_DIR}"
    mkdir -p "${RESOURCES_DIR}"

    # Create modified Info.plist for dev
    echo "Creating Dev Info.plist..."
    cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VoiceFlow-Dev</string>
    <key>CFBundleIdentifier</key>
    <string>com.jacobcole.voiceflow.dev</string>
    <key>CFBundleVersion</key>
    <string>1.0.0-dev</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0-dev</string>
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
fi

# Copy new binary
echo "Copying Binary..."
cp "${BINARY_PATH}" "${MACOS_DIR}/${DEV_APP_NAME}"

# Sign with entitlements
echo "Signing with: ${SIGNING_IDENTITY}"
codesign --force --sign "${SIGNING_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_BUNDLE}" 2>&1

# Verify signature
echo ""
echo "Signature verification:"
codesign -dv "${APP_BUNDLE}" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" || true

echo ""
echo "✅ Development build complete: ${APP_BUNDLE}"
echo ""
echo "Note: Using ad-hoc signing. Permissions may need to be re-granted after rebuild."
echo "To run: open ${APP_BUNDLE}"
