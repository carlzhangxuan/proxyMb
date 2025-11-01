#!/usr/bin/env bash
set -euo pipefail

# Build and package ProxyMb (macOS) as an unsigned Release
# - Output app: build/Build/Products/Release/ProxyMb.app
# - Zipped app: dist/ProxyMb-macos.zip

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SCHEME="ProxyMb"
PROJECT="ProxyMb.xcodeproj"
CONFIG="Release"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
PRODUCTS_DIR="$ROOT_DIR/build/Build/Products/$CONFIG"
APP_NAME="ProxyMb.app"
APP_PATH="$PRODUCTS_DIR/$APP_NAME"
DIST_DIR="$ROOT_DIR/dist"
ZIP_PATH="$DIST_DIR/ProxyMb-macos.zip"

mkdir -p "$DIST_DIR"

/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGNING_IDENTITY="" \
  build | sed -e 's/^/[xcodebuild] /'

if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Built app not found at $APP_PATH" >&2
  exit 1
fi

rm -f "$ZIP_PATH"
(
  cd "$PRODUCTS_DIR"
  /usr/bin/zip -ry "$ZIP_PATH" "$APP_NAME" >/dev/null
)

echo "Packaged: $ZIP_PATH"
