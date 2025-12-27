#!/bin/bash
set -e

# Build the project in debug mode
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

# Create App Bundle Structure
echo "Creating Dev App Bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy Binary
echo "Copying Binary..."
cp "${BINARY_PATH}" "${MACOS_DIR}/${DEV_APP_NAME}"

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

# Sign the App Bundle
echo "Signing Dev App Bundle..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo ""
echo "Build Complete: ${APP_BUNDLE}"
echo ""
echo "To run: open ${APP_BUNDLE}"
echo "Or:     ./${APP_BUNDLE}/Contents/MacOS/${DEV_APP_NAME}"
