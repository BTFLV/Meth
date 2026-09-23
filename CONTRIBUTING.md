# Contributing to Meth

## Branch model

Meth uses a simple GitHub-flow model. There is no long-lived `develop` branch.

| Branch | Purpose |
| --- | --- |
| `main` | Stable, reviewed, always releasable. Protected: changes arrive only through pull requests that pass the `Verify` check. |
| `feature/<name>` | New functionality. |
| `fix/<name>` | Bug fixes. |
| `docs/<name>` | Documentation-only changes. |
| `release/vX.Y.Z` | Short-lived release preparation (version, changelog, final checks). |

Normal changes:

1. Branch from `main`: `git switch -c fix/short-description main`
2. Commit, push, and open a pull request against `main`.
3. CI (`.github/workflows/ci.yml`) builds the SwiftPM package and the Xcode project, runs
   the XCTest suite, and packages an ad-hoc signed app. The `Verify` job must pass.
4. Merge. Merging to `main` does **not** publish a release.

Add a line to the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md) for any
user-visible change.

## Building locally

```bash
swift build                     # quick host-architecture build
./scripts/build_app.sh          # Universal 2 dist/Meth.app + dist/Meth.zip, ad-hoc signed
```

`Meth.xcodeproj` is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); edit `project.yml` and run
`xcodegen generate` rather than editing the project directly. Running the tests requires
a full Xcode installation.

Maintainers with a Developer ID Application certificate in their keychain can produce a
Developer ID signed build (not notarized) locally:

```bash
SIGNING_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" ./scripts/build_app.sh
```

Official, notarized builds are produced only by the release workflow.

## Versioning

Meth follows [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

- [`.release-version`](.release-version) is the single source of truth. It holds the
  version of the most recent release, e.g. `1.0.0`.
- `scripts/build_app.sh` stamps it into the app as `CFBundleShortVersionString`. The build
  number (`CFBundleVersion`) is the number of commits on the built branch, so it increases
  with every release. Local builds report the last released version with their own build
  number; builds from the Xcode project use the placeholder `0.0.0 (0)`.
- The release tag is `v` followed by the version, e.g. `v1.0.0`.

## Releasing

A release is triggered by merging a pull request that changes `.release-version`. Nothing
else publishes a release.

1. Create the release branch from an up-to-date `main`:
   `git switch -c release/vX.Y.Z main`
2. Set `.release-version` to `X.Y.Z`.
3. In `CHANGELOG.md`, rename `[Unreleased]` entries into a new `## [X.Y.Z] - YYYY-MM-DD`
   section, leave an empty `## [Unreleased]` above it, and update the links at the bottom.
4. Check the metadata and preview the release notes:
   `./scripts/release_metadata.sh notes`
5. Commit, push, and open a pull request against `main`. CI verifies that
   `.release-version` changes only on a matching `release/vX.Y.Z` branch, that the
   version is higher than the current one, that it has a changelog section, and that the
   tag does not exist yet.
6. Merge the pull request (squash, merge commit, or rebase all work). Do not put
   `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, `[actions skip]`, or a
   `skip-checks: true` trailer in the merge commit message; GitHub would then skip the
   release workflow.

After the merge, `.github/workflows/release.yml` runs on `main`:

1. **Prepare** validates the version and changelog and confirms that neither the tag nor
   the GitHub Release exists yet.
2. **Verify** runs the complete CI workflow on the merge commit.
3. **Package** builds that commit in the protected `release-signing` environment, signs it
   with the Developer ID certificate, notarizes and staples it, checks it with Gatekeeper,
   and produces `Meth-X.Y.Z.zip` and `SHA256SUMS.txt`.
4. **Publish** creates the annotated tag `vX.Y.Z` on that commit and the GitHub Release
   "Meth X.Y.Z", with notes generated from the changelog section.

### If a release run fails

- **Before Publish** (tests, signing, notarization, stapling, Gatekeeper): nothing has been
  tagged or published.
- **In Publish, after the tag was pushed** (for example `gh release create` failed): the
  tag `vX.Y.Z` stays on the release commit without a GitHub Release. A retry detects this
  and only creates the missing release. If a draft release was left behind, the retry
  stops until you delete that draft (keep the tag).

To retry after fixing the cause (for example an expired certificate), **re-run the failed
workflow run** from the Actions tab; it keeps the original commit. Starting **Release**
manually on `main` also works, but only while `main` is still the release commit.

A retry never moves, deletes, or re-creates a tag and never modifies an existing GitHub
Release. It refuses to continue if the tag points at a different commit or the release
already exists. Ship fixes as a new patch version instead.

Signing and notarization credentials exist only as secrets of the `release-signing`
environment, which is restricted to `main`. Pull requests, including those from forks,
never have access to them.
