#!/usr/bin/env bash
set -euo pipefail

# Integration checks use a real built ProxyMb.app, never the installed app.
if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 /path/to/built/ProxyMb.app" >&2
  exit 2
fi
APP_PATH="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/proxymb-package-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

expect_failure() {
  if "$@" > "$TEST_DIR/expected-failure.log" 2>&1; then
    echo "Error: invalid package unexpectedly passed: $*" >&2
    exit 1
  fi
}

# Paths containing spaces, exact version, signature seal, ZIP round trip, and
# actual isolated app startup must all succeed.
bash "$SCRIPT_DIR/package_app.sh" "$APP_PATH" "$TEST_DIR/release files/ProxyMb-macos.zip" "$VERSION"
/usr/bin/ditto -x -k "$TEST_DIR/release files/ProxyMb-macos.zip" "$TEST_DIR/extracted"
SIGNED_APP="$TEST_DIR/extracted/ProxyMb.app"
ORIGINAL_HASH=$(/usr/bin/shasum -a 256 "$TEST_DIR/release files/ProxyMb-macos.zip")
expect_failure bash "$SCRIPT_DIR/verify_app.sh" "$SIGNED_APP" "wrong-version"
expect_failure bash "$SCRIPT_DIR/verify_app.sh" "$TEST_DIR/missing.app" "$VERSION"
expect_failure bash "$SCRIPT_DIR/package_app.sh" "$APP_PATH" "$TEST_DIR/release files/ProxyMb-macos.zip" "wrong-version"
[[ "$ORIGINAL_HASH" == "$(/usr/bin/shasum -a 256 "$TEST_DIR/release files/ProxyMb-macos.zip")" ]]

# A resource mutation after signing must be rejected, not silently repaired.
/usr/bin/ditto "$SIGNED_APP" "$TEST_DIR/tampered/ProxyMb.app"
printf 'tampered\n' >> "$TEST_DIR/tampered/ProxyMb.app/Contents/Resources/Assets.car"
expect_failure bash "$SCRIPT_DIR/verify_app.sh" "$TEST_DIR/tampered/ProxyMb.app" "$VERSION"

# A valid signature alone does not prove startup works. Use real system
# executables as negative fixtures: nonzero exit and zero exit without readiness.
for executable in /usr/bin/false /usr/bin/true; do
  FIXTURE="$TEST_DIR/$(basename "$executable")/ProxyMb.app"
  /usr/bin/ditto "$SIGNED_APP" "$FIXTURE"
  /bin/cp "$executable" "$FIXTURE/Contents/MacOS/ProxyMb"
  /usr/bin/codesign --force --sign - --timestamp=none "$FIXTURE"
  /usr/bin/codesign --verify --deep --strict "$FIXTURE"
  expect_failure bash "$SCRIPT_DIR/verify_app.sh" "$FIXTURE" "$VERSION"
done
echo "Package regression checks passed"
