#!/usr/bin/env bash
set -euo pipefail

# Verify the actual app bundle that will be distributed, then exercise startup
# without loading the user's configuration or changing tunnels/system proxies.
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /path/to/ProxyMb.app expected-version" >&2
  exit 2
fi
APP_PATH="$1"
EXPECTED_VERSION="$2"
if [[ ! -d "$APP_PATH" || ! -f "$APP_PATH/Contents/Info.plist" ||
      ! -x "$APP_PATH/Contents/MacOS/ProxyMb" || -z "$EXPECTED_VERSION" ]]; then
  echo "Error: app bundle, executable, and expected version are required" >&2
  exit 1
fi

ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Error: app version $ACTUAL_VERSION does not match $EXPECTED_VERSION" >&2
  exit 1
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/proxymb-verify.XXXXXX")
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -KILL "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  # CHECK_DIR is exclusively owned by this invocation of mktemp.
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT

LLVM_PROFILE_FILE="$CHECK_DIR/default.profraw" \
  "$APP_PATH/Contents/MacOS/ProxyMb" --smoke-test "$CHECK_DIR/runtime" > "$CHECK_DIR/startup.log" 2>&1 &
APP_PID=$!
for attempt in {1..30}; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$APP_PID" 2>/dev/null; then
  echo "Error: app startup did not complete within 30 seconds" >&2
  /bin/cat "$CHECK_DIR/startup.log" >&2
  exit 1
fi
if ! wait "$APP_PID"; then
  APP_PID=""
  echo "Error: packaged app failed to start" >&2
  /bin/cat "$CHECK_DIR/startup.log" >&2
  exit 1
fi
APP_PID=""
if ! /usr/bin/grep -Fxq 'ProxyMb startup check passed' "$CHECK_DIR/startup.log"; then
  echo "Error: app exited without completing its startup check" >&2
  /bin/cat "$CHECK_DIR/startup.log" >&2
  exit 1
fi
echo "Verified signature, version $EXPECTED_VERSION, and isolated startup: $APP_PATH"
