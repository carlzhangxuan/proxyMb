#!/usr/bin/env bash
set -euo pipefail

# Generate macOS AppIcon set images from a source PNG (prefer 1024x1024)
# Usage:
#   scripts/generate_appicon.sh /path/to/source.png ProxyMb/Assets.xcassets/AppIcon.appiconset
# If the second argument is omitted, defaults to ProxyMb/Assets.xcassets/AppIcon.appiconset

SRC_IMAGE=${1:-}
APPICONSET_DIR=${2:-"ProxyMb/Assets.xcassets/AppIcon.appiconset"}

if [[ -z "${SRC_IMAGE}" ]]; then
  echo "Usage: $0 /path/to/source.png [path/to/AppIcon.appiconset]" >&2
  exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
  echo "Error: sips not found. This script requires macOS sips tool." >&2
  exit 1
fi

if [[ ! -f "${SRC_IMAGE}" ]]; then
  echo "Error: source image not found: ${SRC_IMAGE}" >&2
  exit 1
fi

mkdir -p "${APPICONSET_DIR}"

# Inspect source dimensions
read -r SRC_W SRC_H < <(sips -g pixelWidth -g pixelHeight "${SRC_IMAGE}" 2>/dev/null | awk '/pixelWidth|pixelHeight/ {print $2}' | xargs)
if [[ -z "${SRC_W:-}" || -z "${SRC_H:-}" ]]; then
  echo "Warning: Could not determine source image dimensions with sips; assuming square and continuing." >&2
  SRC_W=0; SRC_H=0
else
  if (( SRC_W < 512 || SRC_H < 512 )); then
    echo "Error: Source image should be at least 512x512. Got ${SRC_W}x${SRC_H}." >&2
    exit 1
  fi
  if (( SRC_W < 1024 || SRC_H < 1024 )); then
    echo "Warning: Source image is smaller than 1024x1024 (${SRC_W}x${SRC_H}). The largest icons will be upscaled and may look less crisp." >&2
  fi
fi

IS_SQUARE=false
if [[ "${SRC_W}" -eq "${SRC_H}" && "${SRC_W}" -ne 0 ]]; then
  IS_SQUARE=true
fi

# Define sizes (size_label, pixel)
declare -a SIZES=(
  "16x16 16 1x"
  "16x16 32 2x"
  "32x32 32 1x"
  "32x32 64 2x"
  "128x128 128 1x"
  "128x128 256 2x"
  "256x256 256 1x"
  "256x256 512 2x"
  "512x512 512 1x"
  "512x512 1024 2x"
)

# Generate images
JSON_IMAGES=""
for entry in "${SIZES[@]}"; do
  read -r SIZE_LABEL PIX SCALE <<<"${entry}"
  BASENAME="icon_${SIZE_LABEL}@${SCALE}.png"
  OUT_PATH="${APPICONSET_DIR}/${BASENAME}"
  if [[ "${IS_SQUARE}" == true ]]; then
    # Exact resize to target square dimension (upscale allowed)
    sips -s format png -z "${PIX}" "${PIX}" "${SRC_IMAGE}" --out "${OUT_PATH}" >/dev/null
  else
    echo "Note: Non-square source detected; using -Z to preserve aspect into ${PIX}px bounding box for ${BASENAME}." >&2
    sips -s format png -Z "${PIX}" "${SRC_IMAGE}" --out "${OUT_PATH}" >/dev/null
  fi
  JSON_IMAGES+="      {\n        \"idiom\": \"mac\",\n        \"size\": \"${SIZE_LABEL}\",\n        \"scale\": \"${SCALE}\",\n        \"filename\": \"${BASENAME}\"\n      },\n"
  echo "Generated ${BASENAME}"
done

# Trim trailing comma and assemble Contents.json
JSON_IMAGES_TRIMMED=$(echo -e "${JSON_IMAGES}" | sed '$ s/},$/}/')
cat > "${APPICONSET_DIR}/Contents.json" <<JSON
{
  "images" : [
${JSON_IMAGES_TRIMMED}
  ],
  "info" : {
    "version" : 1,
    "author" : "xcode"
  }
}
JSON

echo "Updated ${APPICONSET_DIR}/Contents.json"

echo "Done. Verify the icons in Xcode (AppIcon) and rebuild."
