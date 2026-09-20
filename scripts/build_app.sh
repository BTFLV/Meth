#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Building Meth in Release configuration..."
cd "${ROOT_DIR}"
swift build -c release

BIN_DIR="${ROOT_DIR}/.build/release"
DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/Meth.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

echo "==> Creating application bundle at ${APP_BUNDLE}..."
rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy executables
cp "${BIN_DIR}/Meth" "${MACOS_DIR}/Meth"
cp "${BIN_DIR}/MethWatchdog" "${MACOS_DIR}/MethWatchdog"
chmod +x "${MACOS_DIR}/Meth" "${MACOS_DIR}/MethWatchdog"

# Copy Info.plist and PkgInfo
cp "${ROOT_DIR}/Sources/Meth/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Ad-hoc code sign for local running without Apple Developer identity
echo "==> Ad-hoc signing Meth.app..."
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Creating zip archive..."
cd "${DIST_DIR}"
zip -r -y "Meth.zip" "Meth.app"

echo "==> Successfully created ${DIST_DIR}/Meth.zip"

