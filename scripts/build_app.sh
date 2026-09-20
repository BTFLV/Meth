#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/Meth.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"
ZIP_PATH="${DIST_DIR}/Meth.zip"

ARM64_DIR=".build/arm64-apple-macosx/release"
X86_64_DIR=".build/x86_64-apple-macosx/release"

# Build each architecture slice separately and merge with lipo, rather than relying on
# `swift build --arch a --arch b` producing a fat binary directly: that path requires the
# Xcode-only "swiftbuild"/XCBuild backend, while building one arch at a time and merging
# works with SwiftPM's native build system everywhere, including CI images without a full
# Xcode install for this step.
echo "==> Building Meth (arm64, Release)..."
swift build -c release --arch arm64

echo "==> Building Meth (x86_64, Release)..."
swift build -c release --arch x86_64

echo "==> Creating application bundle at ${APP_BUNDLE}..."
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

for binary in Meth MethWatchdog; do
  lipo -create -output "${MACOS_DIR}/${binary}" \
    "${ARM64_DIR}/${binary}" \
    "${X86_64_DIR}/${binary}"
  chmod +x "${MACOS_DIR}/${binary}"
done

# Copy Info.plist, substituting the Xcode-style build variables it uses (this script is
# the non-Xcode packaging route, so nothing else performs that substitution).
sed \
  -e "s/\$(DEVELOPMENT_LANGUAGE)/en/g" \
  -e "s/\$(EXECUTABLE_NAME)/Meth/g" \
  -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.meth.app/g" \
  -e "s/\$(PRODUCT_NAME)/Meth/g" \
  "${ROOT_DIR}/Sources/Meth/Resources/Info.plist" > "${APP_BUNDLE}/Contents/Info.plist"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Ad-hoc code sign for local running without Apple Developer identity
echo "==> Ad-hoc signing Meth.app..."
codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "==> Verifying application bundle..."
for binary in Meth MethWatchdog; do
  path="${MACOS_DIR}/${binary}"
  [ -f "${path}" ] || { echo "Missing ${path}" >&2; exit 1; }
  [ -x "${path}" ] || { echo "${path} is not executable" >&2; exit 1; }

  archs="$(lipo -archs "${path}")"
  echo "    ${binary}: ${archs}"
  case "${archs}" in
    *arm64*x86_64* | *x86_64*arm64*) ;;
    *) echo "${path} is not a Universal 2 (arm64 + x86_64) binary: ${archs}" >&2; exit 1 ;;
  esac
done

plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null
identifier="$(plutil -extract CFBundleIdentifier raw "${APP_BUNDLE}/Contents/Info.plist")"
[ "${identifier}" = "com.meth.app" ] || { echo "Unexpected CFBundleIdentifier: ${identifier}" >&2; exit 1; }

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
  "Meth.app/Contents/Info.plist"; do
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
