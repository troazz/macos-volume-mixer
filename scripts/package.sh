#!/usr/bin/env bash
# Build a shareable, universal (Intel + Apple Silicon), ad-hoc-signed release of
# Swara and zip it to dist/Swara.zip.
#
# Note: ad-hoc signed (no Apple Developer ID), so the recipient must clear the
# quarantine flag once — see the "Sharing" section of README.md.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

command -v xcodegen >/dev/null && xcodegen generate

xcodebuild -project Swara.xcodeproj -scheme Swara -configuration Release \
  -derivedDataPath "$BUILD_DIR" -destination 'platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  build

APP="$BUILD_DIR/Build/Products/Release/Swara.app"
mkdir -p dist
rm -f dist/Swara.zip
ditto -c -k --keepParent "$APP" dist/Swara.zip

echo "Packaged: dist/Swara.zip"
lipo -archs "$APP/Contents/MacOS/Swara"
