#!/usr/bin/env bash
# Regenerates every raster asset from the SVG sources in Assets/logo.
#
# The generated files are committed, so neither CI nor a normal build needs the tools
# below; run this only after changing one of the SVGs.
#
# Requires: rsvg-convert (brew install librsvg) and iconutil (ships with macOS).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

LOGO_DIR="Assets/logo"
OUT_DIR="Assets/rendered"
ICNS_PATH="Sources/Meth/Resources/AppIcon.icns"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil not found" >&2; exit 1; }

mkdir -p "${OUT_DIR}"

echo "==> Rendering README artwork..."
rsvg-convert -w 800 "${LOGO_DIR}/meth-wordmark-light.svg" -o "${OUT_DIR}/meth-wordmark-light.png"
rsvg-convert -w 800 "${LOGO_DIR}/meth-wordmark-dark.svg"  -o "${OUT_DIR}/meth-wordmark-dark.png"
rsvg-convert -w 256 "${LOGO_DIR}/meth-mark-light.svg"     -o "${OUT_DIR}/meth-mark-light.png"
rsvg-convert -w 256 "${LOGO_DIR}/meth-mark-dark.svg"      -o "${OUT_DIR}/meth-mark-dark.png"
rsvg-convert -w 512 -h 512 "${LOGO_DIR}/meth-appicon.svg" -o "${OUT_DIR}/meth-appicon-512.png"

echo "==> Building ${ICNS_PATH}..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET}"

# Every size is rendered straight from the vector source rather than downscaled from a
# single large PNG, so the small representations stay crisp.
render_icon() {
  local px="$1" name="$2"
  rsvg-convert -w "${px}" -h "${px}" "${LOGO_DIR}/meth-appicon.svg" -o "${ICONSET}/${name}"
}

render_icon 16   icon_16x16.png
render_icon 32   icon_16x16@2x.png
render_icon 32   icon_32x32.png
render_icon 64   icon_32x32@2x.png
render_icon 128  icon_128x128.png
render_icon 256  icon_128x128@2x.png
render_icon 256  icon_256x256.png
render_icon 512  icon_256x256@2x.png
render_icon 512  icon_512x512.png
render_icon 1024 icon_512x512@2x.png

mkdir -p "$(dirname "${ICNS_PATH}")"
iconutil -c icns "${ICONSET}" -o "${ICNS_PATH}"
rm -rf "$(dirname "${ICONSET}")"

echo "==> Done."
ls -la "${OUT_DIR}" "${ICNS_PATH}"
