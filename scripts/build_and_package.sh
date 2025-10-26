#!/usr/bin/env bash
set -euo pipefail

# Build settings
SCHEME="ProxyMb"
PROJECT="ProxyMb.xcodeproj"
CONFIG="Release"
DERIVED="build"
DEST="platform=macOS"

# Clean previous
rm -rf "$DERIVED" dist
mkdir -p dist

# Build unsigned Release
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination "$DEST" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED/Build/Products/$CONFIG/ProxyMb.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App not found at $APP_PATH" >&2
  exit 1
fi

# Zip with ditto preserving resource forks
ZIP_PATH="dist/ProxyMb-macos.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Packaged: $ZIP_PATH"
