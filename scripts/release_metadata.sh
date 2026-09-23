#!/usr/bin/env bash
# Release metadata helper. `.release-version` is the single source of truth for Meth's
# public version; see CONTRIBUTING.md for the release process.
#
#   release_metadata.sh version   Print the validated version from .release-version.
#   release_metadata.sh check     Additionally require a dated, non-empty CHANGELOG.md
#                                 section for that version; print the version.
#   release_metadata.sh notes     Print the GitHub Release notes for that version: a short
#                                 header followed by its CHANGELOG.md section.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION_FILE="${ROOT_DIR}/.release-version"
CHANGELOG="${ROOT_DIR}/CHANGELOG.md"
INFO_PLIST="${ROOT_DIR}/Sources/Meth/Resources/Info.plist"
REPO_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-BTFLV/Meth}"

die() {
  echo "error: $*" >&2
  exit 1
}

read_version() {
  [ -f "${VERSION_FILE}" ] || die ".release-version is missing"
  local version
  version="$(tr -d '[:space:]' < "${VERSION_FILE}")"
  # Plain MAJOR.MINOR.PATCH only: it becomes CFBundleShortVersionString, which macOS
  # expects to be numeric, and pre-release versions are not published by this pipeline.
  [[ "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die ".release-version must contain a MAJOR.MINOR.PATCH version, got '${version}'"
  printf '%s\n' "${version}"
}

# Prints the body of the "## [VERSION] - YYYY-MM-DD" section, without surrounding blank
# lines, up to the next "## " heading or the link reference definitions at the end.
changelog_section() {
  local version="$1"
  awk -v heading="## [${version}] - " '
    index($0, heading) == 1 { found = 1; next }
    found && (/^## / || /^\[[^]]+\]: /) { exit }
    found { lines[++n] = $0 }
    END {
      first = 1
      while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n
      while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "${CHANGELOG}"
}

check() {
  local version="$1"
  [ -f "${CHANGELOG}" ] || die "CHANGELOG.md is missing"
  grep -qxE "## \[${version//./\\.}\] - [0-9]{4}-[0-9]{2}-[0-9]{2}" "${CHANGELOG}" \
    || die "CHANGELOG.md has no '## [${version}] - YYYY-MM-DD' section"
  [ -n "$(changelog_section "${version}")" ] \
    || die "CHANGELOG.md section for ${version} is empty"

  # The bundle version must come from .release-version, never be hard-coded in the plist.
  grep -qF '<string>$(MARKETING_VERSION)</string>' "${INFO_PLIST}" \
    || die "Info.plist must use \$(MARKETING_VERSION) for CFBundleShortVersionString"
  grep -qF '<string>$(CURRENT_PROJECT_VERSION)</string>' "${INFO_PLIST}" \
    || die "Info.plist must use \$(CURRENT_PROJECT_VERSION) for CFBundleVersion"
}

notes() {
  local version="$1" min_macos
  min_macos="$(awk '/<key>LSMinimumSystemVersion<\/key>/ { getline; gsub(/.*<string>|<\/string>.*/, ""); print; exit }' "${INFO_PLIST}")"
  [ -n "${min_macos}" ] || die "LSMinimumSystemVersion not found in Info.plist"

  cat <<EOF
- **Requires** macOS ${min_macos} or later
- **Universal** binary for Apple Silicon and Intel Macs
- **Signed** with an Apple Developer ID Application certificate and **notarized** by Apple

**Install:** download \`Meth-${version}.zip\`, unzip it, and move \`Meth.app\` to your
Applications folder. \`SHA256SUMS.txt\` contains the SHA-256 checksum of the download.

## Changes in ${version}

$(changelog_section "${version}")

See [CHANGELOG.md](${REPO_URL}/blob/v${version}/CHANGELOG.md) for the full history.
EOF
}

command="${1:-}"
case "${command}" in
  version)
    read_version
    ;;
  check)
    version="$(read_version)"
    check "${version}"
    printf '%s\n' "${version}"
    ;;
  notes)
    version="$(read_version)"
    check "${version}"
    notes "${version}"
    ;;
  *)
    echo "Usage: $(basename "$0") version|check|notes" >&2
    exit 2
    ;;
esac
