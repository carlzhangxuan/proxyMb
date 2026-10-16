#!/usr/bin/env bash
set -euo pipefail

# Ad-hoc signing seals the complete bundle; it is not Developer ID signing or
# notarization and does not bypass Gatekeeper for downloaded applications.
if [[ $# -ne 3 ]]; then
  echo "Usage: $0 /path/to/ProxyMb.app output.zip expected-version" >&2
  exit 2
fi
APP_PATH="$1"
ZIP_PATH="$2"
EXPECTED_VERSION="$3"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -d "$APP_PATH" || "$(basename "$APP_PATH")" != "ProxyMb.app" ||
      "$ZIP_PATH" != *.zip || -z "$EXPECTED_VERSION" ]]; then
  echo "Error: ProxyMb.app, an output .zip path, and an expected version are required" >&2
  exit 1
fi

STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/proxymb-package.XXXXXX")
cleanup() {
  # STAGING_DIR is exclusively owned by this invocation of mktemp.
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

# Never re-sign or modify the caller's app. Sign only the completed staging copy.
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/ProxyMb.app"
/usr/bin/codesign --force --sign - --timestamp=none "$STAGING_DIR/ProxyMb.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/ProxyMb.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$STAGING_DIR/ProxyMb.app" "$STAGING_DIR/ProxyMb-macos.zip"
/usr/bin/ditto -x -k "$STAGING_DIR/ProxyMb-macos.zip" "$STAGING_DIR/extracted"
bash "$SCRIPT_DIR/verify_app.sh" "$STAGING_DIR/extracted/ProxyMb.app" "$EXPECTED_VERSION"

# Publish the ZIP only after verifying its extracted contents. Failed checks
# leave any previously built archive untouched.
mkdir -p "$(dirname "$ZIP_PATH")"
mv -f "$STAGING_DIR/ProxyMb-macos.zip" "$ZIP_PATH"
echo "Packaged (ad-hoc signed, not notarized): $ZIP_PATH"
