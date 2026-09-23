#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

DIST_DIR="${ROOT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/Meth.app"
MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

# Version metadata. The public version comes from .release-version (validated by
# release_metadata.sh); the build number is the commit count, which only grows along
# main's history. Shallow or non-git checkouts (e.g. PR CI) use build number 0.
VERSION="$("${SCRIPT_DIR}/release_metadata.sh" version)"
if [ "$(git -C "${ROOT_DIR}" rev-parse --is-shallow-repository 2>/dev/null || echo true)" = "false" ]; then
  BUILD_NUMBER="$(git -C "${ROOT_DIR}" rev-list --count HEAD)"
else
  BUILD_NUMBER=0
fi
echo "==> Meth ${VERSION} (build ${BUILD_NUMBER})"

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
  -e "s/\$(MARKETING_VERSION)/${VERSION}/g" \
  -e "s/\$(CURRENT_PROJECT_VERSION)/${BUILD_NUMBER}/g" \
  "${ROOT_DIR}/Sources/Meth/Resources/Info.plist" > "${APP_BUNDLE}/Contents/Info.plist"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# App icon. Committed as a pre-rendered .icns (see scripts/generate_logo_assets.sh) so
# packaging needs no SVG toolchain.
cp "${ROOT_DIR}/Sources/Meth/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# Code signing. Ad-hoc by default, so contributors need no Apple Developer certificate.
# Official builds set SIGNING_IDENTITY to a "Developer ID Application: ..." identity (and
# optionally SIGNING_KEYCHAIN, as CI does). Nested code is signed explicitly inside-out
# instead of relying on --deep.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SIGNING_KEYCHAIN="${SIGNING_KEYCHAIN:-}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-5BA47U384K}"

codesign_args=(--force)
if [ -n "${SIGNING_IDENTITY}" ]; then
  echo "==> Signing Meth.app with Developer ID identity..."
  codesign_args+=(--sign "${SIGNING_IDENTITY}" --options runtime --timestamp)
  if [ -n "${SIGNING_KEYCHAIN}" ]; then
    codesign_args+=(--keychain "${SIGNING_KEYCHAIN}")
  fi
else
  echo "==> Ad-hoc signing Meth.app (set SIGNING_IDENTITY for Developer ID signing)..."
  codesign_args+=(--sign -)
fi

codesign "${codesign_args[@]}" --identifier com.meth.watchdog "${MACOS_DIR}/MethWatchdog"
codesign "${codesign_args[@]}" --identifier com.meth.app "${MACOS_DIR}/Meth"
codesign "${codesign_args[@]}" "${APP_BUNDLE}"

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

if [ -n "${SIGNING_IDENTITY}" ]; then
  # Apple's designated requirement for Developer ID Application code: chains to an Apple
  # anchor through the Developer ID intermediate, with a Developer ID Application leaf
  # certificate issued to the expected team. Rejects ad-hoc and any other certificate type.
  developer_id_requirement="anchor apple generic"
  developer_id_requirement+=" and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
  developer_id_requirement+=" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
  developer_id_requirement+=" and certificate leaf[subject.OU] = \"${EXPECTED_TEAM_ID}\""

  for path in "${MACOS_DIR}/MethWatchdog" "${MACOS_DIR}/Meth" "${APP_BUNDLE}"; do
    codesign --verify --strict --test-requirement="=${developer_id_requirement}" "${path}" \
      || { echo "${path} is not signed with a Developer ID Application identity for team ${EXPECTED_TEAM_ID}" >&2; exit 1; }

    signature_info="$(codesign --display --verbose=2 "${path}" 2>&1)"
    if grep -q "^Signature=adhoc" <<< "${signature_info}"; then
      echo "${path} is ad-hoc signed although SIGNING_IDENTITY was provided" >&2
      exit 1
    fi
    grep -qFx "TeamIdentifier=${EXPECTED_TEAM_ID}" <<< "${signature_info}" \
      || { echo "${path} does not have TeamIdentifier=${EXPECTED_TEAM_ID}" >&2; exit 1; }
    grep -qE "^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime" <<< "${signature_info}" \
      || { echo "${path} is not signed with the hardened runtime" >&2; exit 1; }
    grep -q "^Timestamp=" <<< "${signature_info}" \
      || { echo "${path} has no secure timestamp" >&2; exit 1; }
    # SIGNING_IDENTITY may also be a certificate SHA-1 hash, which has no Authority line to match.
    if ! [[ "${SIGNING_IDENTITY}" =~ ^[0-9A-Fa-f]{40}$ ]]; then
      grep -qFx "Authority=${SIGNING_IDENTITY}" <<< "${signature_info}" \
        || { echo "${path} is not signed by ${SIGNING_IDENTITY}" >&2; exit 1; }
    fi
    echo "    $(basename "${path}"): Developer ID, team ${EXPECTED_TEAM_ID}, hardened runtime, timestamped"
  done
fi

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

[ -s "${RESOURCES_DIR}/AppIcon.icns" ] || { echo "Missing ${RESOURCES_DIR}/AppIcon.icns" >&2; exit 1; }

plutil -lint "${APP_BUNDLE}/Contents/Info.plist" >/dev/null
identifier="$(plutil -extract CFBundleIdentifier raw "${APP_BUNDLE}/Contents/Info.plist")"
[ "${identifier}" = "com.meth.app" ] || { echo "Unexpected CFBundleIdentifier: ${identifier}" >&2; exit 1; }
short_version="$(plutil -extract CFBundleShortVersionString raw "${APP_BUNDLE}/Contents/Info.plist")"
[ "${short_version}" = "${VERSION}" ] || { echo "Unexpected CFBundleShortVersionString: ${short_version}" >&2; exit 1; }
bundle_version="$(plutil -extract CFBundleVersion raw "${APP_BUNDLE}/Contents/Info.plist")"
[ "${bundle_version}" = "${BUILD_NUMBER}" ] || { echo "Unexpected CFBundleVersion: ${bundle_version}" >&2; exit 1; }
if grep -q '\$(' "${APP_BUNDLE}/Contents/Info.plist"; then
  echo "Info.plist still contains unsubstituted build variables" >&2
  exit 1
fi

# Zip packaging lives in its own script so CI can re-create the zip after notarization and
# stapling without rebuilding.
"${SCRIPT_DIR}/package_zip.sh"
