<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/rendered/meth-wordmark-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="Assets/rendered/meth-wordmark-light.png">
    <img alt="Meth — keep your Mac awake" src="Assets/rendered/meth-wordmark-light.png" width="420">
  </picture>
</p>

<p align="center">
  <a href="https://github.com/BTFLV/Meth/actions/workflows/ci.yml"><img alt="CI status" src="https://github.com/BTFLV/Meth/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/BTFLV/Meth/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/BTFLV/Meth"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
</p>

---

Meth is a lightweight, native macOS menu bar utility for controlling system sleep. Its
defining feature is **Closed-Lid Mode**: ordinary "keep awake" tools only prevent *idle*
sleep, not the sleep macOS triggers when the lid is closed. Meth adds a dedicated,
narrowly-scoped mechanism specifically for that case, so long-running work — builds,
downloads, vibecoding sessions, remote sessions, local servers — can keep running with the
lid shut.

<p align="center">
  <img alt="Meth menu bar interface and Closed-Lid Mode options" src="Assets/meth_screenshot.png" width="480">
</p>

---

## Features

- **Normal Keep Awake sessions** — indefinite, or for a fixed duration (5 minutes up to
  8 hours), using standard IOKit power assertions.
- **Until sessions** — stay awake until a specific clock time (e.g. "Until 23:00").
- **Display sleep control** — optionally let the display sleep on its own schedule while
  the system stays awake.
- **Closed-Lid Mode** — keeps the Mac running with the lid closed, with an automatic
  low-battery safety cutoff and a crash-recovery watchdog (see below).
- **Launch at Login**, backed by `SMAppService`.
- **Extend** a running timed session by 15 minutes or 1 hour from the menu.

### Menu bar icon

The status item is a template image drawn from vector paths, so it stays crisp at any
resolution and follows the system's light/dark appearance and menu highlighting. Its three
states are distinguishable at a glance:

| Icon | Meaning |
| --- | --- |
| Empty flask | No session — your Mac sleeps normally |
| Flask with a crystal | A keep-awake session is running |
| Solid flask | A session is running **with Closed-Lid Mode** |

---

## Closed-Lid Mode

Standard macOS idle-sleep assertions (`kIOPMAssertPreventUserIdleSystemSleep`,
`kIOPMAssertPreventUserIdleDisplaySleep`) and tools built on them, such as `caffeinate`,
do **not** prevent sleep triggered by closing the lid. Overriding that requires a
different, privileged mechanism: the kernel's `SleepDisabled` parameter, toggled via
`pmset -a disablesleep`.

Because this requires administrator privileges, Meth uses the narrowest mechanism that
gets the job done:

- The Meth process itself **never runs as root** and there is **no background daemon or
  helper process** that runs continuously.
- Administrator authentication is requested **once**, to install a drop-in `sudoers.d`
  rule that lets members of the `admin` group run only two exact commands as root without
  a password, with no wildcards: `pmset -a disablesleep 0` and `pmset -a disablesleep 1`.
- After that one-time setup, enabling and disabling Closed-Lid Mode runs those two fixed
  commands via `sudo -n`, with no further prompts.
- Support can be removed at any time from Settings (this asks for administrator
  authentication again), which restores normal sleep behavior first, then removes the rule
  and verifies both steps succeeded.
- Closed-Lid support cannot be removed while a Closed-Lid session is currently relying on
  it; stop the session first.

**Crash and stale-state recovery.** If Meth is killed unexpectedly, a small independent
watchdog process (spawned only while Closed-Lid Mode is active) detects the exit via a
kernel `kqueue` event and restores normal sleep behavior, retrying a bounded number of
times with backoff and verifying the result. On every launch, Meth also checks for a
`SleepDisabled=1` state left over from an ungraceful shutdown — but only reverts it if
Meth's own records indicate *it* was the one that enabled it. If `SleepDisabled` is
already enabled for some other reason (another tool, or an administrator), Meth leaves it
untouched rather than guessing. Recovery is best effort: it cannot succeed in every
failure mode (for example, if the privileged rule itself has become unusable when
recovery is attempted). If sleep stays disabled, `sudo pmset -a disablesleep 0` restores
it.

**Thermal and battery safety.** Closed-Lid Mode keeps the CPU, memory, and fans active
with the lid shut, which increases heat and battery use. Meth refuses to *start* a
Closed-Lid session while running on battery at 10% or below, and automatically stops a
running one if the battery drops to that threshold while not connected to power. Never
place an actively running, closed MacBook in an enclosed bag or unventilated space.

---

## Security model

- During normal use, the only privileged commands are the two fixed, absolute-path
  `/usr/bin/pmset -a disablesleep 0|1` commands, run through `sudo -n` without a shell.
- Installing and removing Closed-Lid support each run one short, fixed shell script as
  root through the standard macOS administrator prompt (AppleScript's `do shell script …
  with administrator privileges`). The scripts contain no user-supplied input.
- The sudoers rule is written to a temporary, root-owned file first, validated with
  `visudo -c -f`, and only then atomically renamed into place — it is never written
  through a redirection at its final path.
- No persistent daemon, no XPC service, no login item beyond the app itself.
- No analytics, telemetry, crash reporting, or third-party tracking.
- No networking code and no third-party dependencies. Meth does not check for updates,
  phone home, or make any network connections; the only place a network is involved is
  when a user manually downloads a release from GitHub in their browser.

---

## Installation

1. Download `Meth-<version>.zip` from the [latest release](https://github.com/BTFLV/Meth/releases/latest).
2. Unzip it and move `Meth.app` to your **Applications** folder.
3. Open `Meth.app`. Meth runs in the menu bar only; it has no Dock icon.

Official releases are signed with an Apple Developer ID Application certificate and
notarized by Apple, so macOS opens them after its usual confirmation for apps downloaded
from the internet. Each release also includes `SHA256SUMS.txt` with the checksum of the
download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

### What macOS will ask

- **First launch:** the standard "downloaded from the internet" confirmation.
- **Closed-Lid Support** (only if you use Closed-Lid Mode): an administrator password
  prompt, once, when you click **Install Support** in **Settings → Closed-Lid Support**,
  and again if you later click **Remove Support**.
- **Launch at Login** (only if you enable it): macOS may show a notification that a login
  item was added. It is listed under **System Settings → General → Login Items**.

Meth uses no APIs that require Accessibility, Full Disk Access, notification, or network
permissions.

## Uninstallation

1. If you installed Closed-Lid support, open **Settings → Closed-Lid Support** and click
   **Remove Support** first. This restores normal sleep behavior and removes the sudoers
   rule. If the app is already gone, remove the rule manually:
   `sudo rm /private/etc/sudoers.d/meth-closed-lid`
2. If you enabled **Launch at Login**, turn it off in Settings (or remove Meth under
   **System Settings → General → Login Items**).
3. Quit Meth and delete `Meth.app` from **Applications**.
4. Optionally, remove Meth's preferences:
   `defaults delete com.meth.app; defaults delete com.meth.app.shared`

---

## Building from source

Requirements: macOS 13.0+ and Xcode 16+ (a full Xcode installation, not just the Command
Line Tools, is required for the Xcode project and to run the test suite — XCTest ships
with Xcode).

```bash
git clone https://github.com/BTFLV/Meth.git
cd Meth

# Quick local build for the host architecture only
swift build -c release

# Run the test suite (requires Xcode, not just Command Line Tools)
swift test

# Or build/test via the Xcode project generated by project.yml (XcodeGen)
xcodebuild build -project Meth.xcodeproj -scheme Meth -configuration Release
xcodebuild test -project Meth.xcodeproj -scheme MethTests -destination "platform=macOS"

# Package a Universal 2 (arm64 + x86_64) dist/Meth.app and dist/Meth.zip, ad-hoc signed
./scripts/build_app.sh
```

Locally built apps are ad-hoc signed, so Gatekeeper treats them as unidentified-developer
apps. See [CONTRIBUTING.md](CONTRIBUTING.md) for Developer ID signing, the branch model,
and the release process.

`Meth.xcodeproj` is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen);
edit `project.yml` and run `xcodegen generate` rather than editing the project directly.

---

## System requirements

- macOS 13.0 (Ventura) or later.
- **Universal 2**: each release zip contains a single `Meth.app` with both Apple
  Silicon (arm64) and Intel (x86_64) binaries; the correct slice is used automatically.
  Intel compatibility is built and packaged but is not actively tested on real Intel
  hardware, since none is available in this project's build environment.
- Administrator authentication (once) only if Closed-Lid Mode is used; ordinary keep-awake
  sessions require no elevated privileges at all.

---

## Releases and versioning

Meth follows [Semantic Versioning](https://semver.org). Each release is an immutable
GitHub Release tagged `vX.Y.Z`, built, signed, and notarized by GitHub Actions from the
reviewed commit on `main`. Changes are listed in [CHANGELOG.md](CHANGELOG.md).

---

## Brand assets

The logo — an Erlenmeyer flask holding a faceted crystal — lives in
[`Assets/logo`](Assets/logo) as SVG, in light, dark, and full-colour app icon variants.
Everything else is derived from those sources by
[`scripts/generate_logo_assets.sh`](scripts/generate_logo_assets.sh): the README artwork in
`Assets/rendered`, and the app's `AppIcon.icns`. The generated files are committed, so no
build or CI step needs an SVG toolchain; re-run the script only after editing an SVG.

The menu bar glyph is deliberately *not* derived from them — at 16-18 pt it needs its own
weights, so it is drawn directly from vector paths in
[`MenuBarIcon.swift`](Sources/Meth/UI/MenuBarIcon.swift).

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
