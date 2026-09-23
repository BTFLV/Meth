#!/usr/bin/env bash
# Creates and verifies dist/Meth.zip from an already-built dist/Meth.app. Called by
# build_app.sh, and again by CI after notarization so the release zip contains the stapled
# app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/Meth.app"
ZIP_PATH="${DIST_DIR}/Meth.zip"

[ -d "${APP_BUNDLE}" ] || { echo "Missing ${APP_BUNDLE}; run scripts/build_app.sh first" >&2; exit 1; }

echo "==> Creating zip archive..."
rm -f "${ZIP_PATH}"
# ditto preserves the bundle structure, permissions, and resource forks correctly, unlike
# the generic `zip` tool.
ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

echo "==> Verifying zip archive..."
[ -s "${ZIP_PATH}" ] || { echo "${ZIP_PATH} is missing or empty" >&2; exit 1; }
unzip -tq "${ZIP_PATH}" >/dev/null

# Captured into a variable first: piping `unzip -Z1` directly into `grep -q` can trigger a
# spurious SIGPIPE/pipefail failure when grep exits before unzip finishes writing.
zip_listing="$(unzip -Z1 "${ZIP_PATH}")"
for expected in \
  "Meth.app/Contents/MacOS/Meth" \
  "Meth.app/Contents/MacOS/MethWatchdog" \
  "Meth.app/Contents/Info.plist" \
  "Meth.app/Contents/Resources/AppIcon.icns"; do
  found=0
  while IFS= read -r entry; do
    if [ "${entry}" = "${expected}" ]; then
      found=1
      break
    fi
  done <<< "${zip_listing}"
  [ "${found}" -eq 1 ] || { echo "${expected} missing from archive" >&2; exit 1; }
done

echo "==> Successfully created ${ZIP_PATH}"
