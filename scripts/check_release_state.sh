#!/usr/bin/env bash
# Decides whether the release workflow may publish TAG from COMMIT, based on the remote
# state. Used by .github/workflows/release.yml before building and again right before
# tagging. Requires `gh` (GH_TOKEN) and a git remote named origin.
#
#   check_release_state.sh TAG COMMIT
#
# Prints one word and exits 0 only in the two safe states:
#   new     neither the tag nor a GitHub Release exists yet
#   resume  the tag already points at COMMIT but no GitHub Release exists, i.e. an
#           earlier run pushed the tag and then failed before the release was created
# Exits non-zero, without changing anything, if a GitHub Release (published or draft)
# already exists for TAG, if the tag points at a different commit, or if the state cannot
# be determined. Tags and releases are never moved, deleted, or replaced.
set -euo pipefail

tag="${1:?usage: check_release_state.sh TAG COMMIT}"
commit="${2:?usage: check_release_state.sh TAG COMMIT}"
[[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::Invalid tag '${tag}'." >&2; exit 1; }
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

# Lists every release for the tag, including drafts when the token has write access.
# A failed API call aborts the script (fail closed) instead of reading as "no release".
release_drafts="$(gh api --paginate "repos/${repo}/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"${tag}\") | .draft")"
if grep -qx false <<< "${release_drafts}"; then
  echo "::error::The GitHub Release ${tag} already exists. Published releases are never replaced; release a new version instead." >&2
  exit 1
fi
if grep -qx true <<< "${release_drafts}"; then
  echo "::error::A draft GitHub Release for ${tag} exists, probably left by an interrupted run. Review and delete the draft (keep the tag), then retry." >&2
  exit 1
fi

# Annotated tags are listed twice: the tag object, and the commit it points to ("^{}").
remote_refs="$(git ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}")"
tag_commit="$(awk -v ref="refs/tags/${tag}^{}" '$2 == ref { print $1 }' <<< "${remote_refs}")"
if [ -z "${tag_commit}" ]; then
  tag_commit="$(awk -v ref="refs/tags/${tag}" '$2 == ref { print $1 }' <<< "${remote_refs}")"
fi

if [ -z "${tag_commit}" ]; then
  echo "new"
elif [ "${tag_commit}" = "${commit}" ]; then
  echo "::notice::Tag ${tag} already points at ${commit} but has no GitHub Release; resuming." >&2
  echo "resume"
else
  echo "::error::Tag ${tag} already exists at ${tag_commit}, not at ${commit}. Tags are never moved." >&2
  exit 1
fi
