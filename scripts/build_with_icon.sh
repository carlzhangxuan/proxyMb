#!/usr/bin/env bash
set -euo pipefail

# Wrapper to generate AppIcon from a PNG and then build/package the app.
# Usage:
#   bash scripts/build_with_icon.sh --icon /path/to/source.png
# or just:
#   bash scripts/build_with_icon.sh
# which will try resources/appicon.png if present.

ICON_SRC=""
CREATE_DMG=false
VERSION="1.0.0"

print_help() {
  cat <<EOF
Usage: $0 [--icon /path/to/source.png] [--dmg [version]]

Options:
  --icon PATH   Optional path to a 1024x1024 (preferred) PNG to generate AppIcon before build.
                If omitted, the script will look for resources/appicon.png. If not found, it will skip.
  --dmg [ver]   After build, also create a DMG (default version: ${VERSION}).
  -h, --help    Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --icon)
      if [[ $# -lt 2 ]]; then
        echo "Error: --icon requires a path argument" >&2
        exit 1
      fi
      ICON_SRC="$2"
      shift 2
      ;;
    --dmg)
      CREATE_DMG=true
      if [[ $# -ge 2 && ! "$2" =~ ^-- ]]; then
        VERSION="$2"
        shift 2
      else
        shift 1
      fi
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_help
      exit 1
      ;;
  esac
done

# Determine icon source
if [[ -z "${ICON_SRC}" && -f "resources/appicon.png" ]]; then
  ICON_SRC="resources/appicon.png"
fi

# Generate icons if we have a source
if [[ -n "${ICON_SRC}" ]]; then
  if [[ -f "${ICON_SRC}" ]]; then
    echo "Generating AppIcon from: ${ICON_SRC}"
    bash scripts/generate_appicon.sh "${ICON_SRC}" "ProxyMb/Assets.xcassets/AppIcon.appiconset"
  else
    echo "Warning: icon source not found at ${ICON_SRC}. Skipping icon generation." >&2
  fi
else
  echo "Note: No icon provided (use --icon PATH or place resources/appicon.png). Skipping icon generation."
fi

# Build and package (zip)
bash scripts/build_and_package.sh

# Optionally create DMG
if [[ "${CREATE_DMG}" == true ]]; then
  bash scripts/create_dmg.sh "${VERSION}"
fi

echo "Done."
