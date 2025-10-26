#!/usr/bin/env bash
set -euo pipefail

# DMG creation script for ProxyMb
APP_NAME="ProxyMb"
VERSION="${1:-1.0.0}"
APP_PATH="build/Build/Products/Release/${APP_NAME}.app"
DMG_DIR="dmg_staging"
DMG_NAME="${APP_NAME}-${VERSION}"
FINAL_DMG="dist/${DMG_NAME}.dmg"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Creating DMG for ${APP_NAME} v${VERSION}...${NC}"

# Check if app exists
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: App not found at $APP_PATH"
  echo "Please build the app first with: bash scripts/build_and_package.sh"
  exit 1
fi

# Clean up previous builds
rm -rf "$DMG_DIR" "dist/${APP_NAME}"*.dmg
mkdir -p dist "$DMG_DIR"

echo -e "${BLUE}Copying app to staging directory...${NC}"
cp -R "$APP_PATH" "$DMG_DIR/"

# Create Applications symlink for drag-and-drop install
echo -e "${BLUE}Creating Applications symlink...${NC}"
ln -s /Applications "$DMG_DIR/Applications"

# Optional: Add a background image or README
# You can customize this section later
if [[ -f "resources/dmg_background.png" ]]; then
  mkdir -p "$DMG_DIR/.background"
  cp "resources/dmg_background.png" "$DMG_DIR/.background/"
fi

# Create temporary DMG
TEMP_DMG="dist/${DMG_NAME}-temp.dmg"
echo -e "${BLUE}Creating temporary DMG...${NC}"

hdiutil create -volname "$DMG_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov -format UDRW \
  "$TEMP_DMG"

# Mount the temporary DMG
echo -e "${BLUE}Mounting DMG for customization...${NC}"
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")
# Capture device node (e.g., /dev/disk4) and mount point (e.g., /Volumes/${DMG_NAME})
DEVICE=$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')
MOUNT_POINT=$(echo "$ATTACH_OUTPUT" | awk '/\/Volumes\// {print $NF; exit}')

# Give the volume time to mount
sleep 2

# Set custom icon positions and window size using AppleScript
echo -e "${BLUE}Customizing DMG layout...${NC}"
if ! osascript <<EOF
try
  tell application "Finder"
    tell disk "$DMG_NAME"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {100, 100, 600, 400}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 72
      set position of item "${APP_NAME}.app" of container window to {150, 150}
      set position of item "Applications" of container window to {350, 150}
      update without registering applications
      delay 2
      close
    end tell
  end tell
end try
EOF
then
  echo "Warning: DMG layout customization failed; continuing without custom layout." >&2
fi

# Sync and unmount
sync
echo -e "${BLUE}Unmounting DMG...${NC}"
# Prefer detaching by device; fall back to mount point if needed
if ! hdiutil detach "$DEVICE" -quiet; then
  hdiutil detach "$MOUNT_POINT" -force -quiet || true
fi

# Convert to compressed read-only DMG
echo -e "${BLUE}Compressing final DMG...${NC}"
hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_DMG"

# Clean up
rm -rf "$DMG_DIR" "$TEMP_DMG"

# Get file size
DMG_SIZE=$(du -h "$FINAL_DMG" | cut -f1)

echo -e "${GREEN}✓ DMG created successfully!${NC}"
echo -e "${GREEN}  File: $FINAL_DMG${NC}"
echo -e "${GREEN}  Size: $DMG_SIZE${NC}"
echo ""
echo "To distribute:"
echo "  1. Test: open $FINAL_DMG"
echo "  2. Drag ${APP_NAME}.app to Applications to install"
