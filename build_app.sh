#!/bin/bash
set -e

# Build the project
echo "Building VoiceFlow..."
swift build -c release --arch arm64

# Define paths
APP_NAME="VoiceFlow"
RELEASE_NAME="VoiceFlow Release"
APP_BUNDLE="${RELEASE_NAME}.app"
BINARY_PATH=".build/arm64-apple-macosx/release/${APP_NAME}"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Create App Bundle Structure
echo "Creating App Bundle..."
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy Binary
echo "Copying Binary..."
cp "${BINARY_PATH}" "${MACOS_DIR}/${RELEASE_NAME}"

# Create Release Info.plist
echo "Creating Release Info.plist..."
cat > "${CONTENTS_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VoiceFlow Release</string>
    <key>CFBundleIdentifier</key>
    <string>com.jacobcole.voiceflow.release</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>VoiceFlow Release</string>
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

# Clean up any existing signature
echo "Removing existing signature..."
codesign --remove-signature "${APP_BUNDLE}" 2>/dev/null || true

# Sign the App Bundle
echo "Signing App Bundle..."
# Self-sign with ad-hoc signature
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "Verifying Signature..."
codesign -dv --verbose=4 "${APP_BUNDLE}"

echo "Build and Sign Complete: ${APP_BUNDLE}"

# Copy API key from dev defaults to release defaults
DEV_API_KEY=$(defaults read com.jacobcole.voiceflow assemblyai_api_key 2>/dev/null || true)
if [ -n "$DEV_API_KEY" ]; then
    defaults write com.jacobcole.voiceflow.release assemblyai_api_key "$DEV_API_KEY"
    echo "API key copied to release defaults"
fi

# Reset accessibility permissions for fresh start
echo "Resetting Accessibility permissions..."
tccutil reset Accessibility com.jacobcole.voiceflow.release 2>/dev/null || true

# Install to Applications folder
echo "Installing to /Applications..."
cp -R "${APP_BUNDLE}" /Applications/
echo "Installed to /Applications/${APP_BUNDLE}"

echo "NOTE: You will need to grant Accessibility permissions when prompted."
