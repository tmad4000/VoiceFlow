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

# ... (omitted)

# Sign with entitlements (REMOVED ENTITLEMENTS FLAG)
echo "Signing with: ${SIGNING_IDENTITY}"
codesign --force --sign "${SIGNING_IDENTITY}" \
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
