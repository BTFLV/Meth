# Changelog

All notable changes to Meth are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Meth
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-09-24

### Added

- The menu shows when a running session ends and whether the display may sleep; sessions
  without a time limit show when they started.
- If system sleep is disabled while no Closed-Lid session is running (for example after a
  failed restore, or set by another tool), the menu says so and offers **Restore Normal
  Sleep…**. It uses Closed-Lid support when installed and otherwise asks for
  administrator authentication.
- The Until… time picker shows whether the chosen time is today or tomorrow.
- Opening Meth while it is already running shows its Settings window, which helps when
  the menu bar icon is hidden, for example behind the notch.
- Settings explains when macOS blocks Launch at Login and links to the Login Items
  settings.

### Changed

- Settings shows why Closed-Lid support needs attention, including that Closed-Lid Mode
  requires an administrator account.
- Cancelling an administrator password prompt is no longer reported as an error.
- Opening a second copy of Meth while one is running now quits the new copy with an
  explanation instead of running both.

### Fixed

- Closed-Lid Mode could start with the battery already at 10% or below, because Meth
  checked a battery reading taken when it launched.
- Extending a session while it was being stopped, for example just as it expired, could
  turn Closed-Lid Mode back on with no session left to turn it off.
- When Closed-Lid Mode was stopped automatically (low battery, or support removed) but
  normal sleep could not be restored, Meth reported a clean stop instead of warning.
- Meth's launch-time recovery could undo a Closed-Lid session started while the check was
  still running.
- Stopping Closed-Lid Mode was reported as failed when sleep had in fact already been
  restored.
- Installing or removing Closed-Lid support ran AppleScript off the main thread, which
  macOS does not support, and its error messages repeated their prefix.
- The countdown starts at the full duration (for example 05:00) instead of one second
  less.

### Security

- The crash-recovery watchdog is only ever launched from inside the app bundle, never
  from a location that depends on the working directory.

## [1.0.0] - 2026-09-23

First stable release.

### Added

- Menu bar app that keeps your Mac awake indefinitely, for a fixed duration (5 minutes to
  8 hours), or until a chosen time of day.
- Running timed sessions can be extended by 15 minutes or 1 hour; the menu shows the
  remaining time.
- Option to let the display sleep while the system stays awake.
- **Closed-Lid Mode**, which keeps the Mac running with the lid closed. It relies on a
  narrowly scoped `sudoers.d` rule that lets administrator accounts run only
  `pmset -a disablesleep 0` and `pmset -a disablesleep 1` without a password, installed
  once with administrator approval and removable at any time from Settings.
- Closed-Lid safety measures: a one-time notice about heat and ventilation, the display is
  put to sleep when the lid closes, and Closed-Lid Mode refuses to start, or stops
  automatically, at 10% battery or below when not connected to power.
- Crash recovery for Closed-Lid Mode: a watchdog process restores normal sleep if Meth
  exits unexpectedly, and a launch-time check reverts leftover state that Meth itself set,
  without touching sleep settings changed by other tools.
- Launch at Login.
- Menu bar icon that shows whether no session, a session, or a Closed-Lid session is
  active.
- About window showing the installed version.
- Universal binary (Apple Silicon and Intel) for macOS 13 Ventura or later. Intel builds
  are produced and verified but not tested on Intel hardware.
- Releases are signed with an Apple Developer ID Application certificate and notarized by
  Apple.

### Fixed

- Detection of the `SleepDisabled` setting on current macOS versions. Earlier development
  builds misread it, so the crash-recovery watchdog and launch-time check could leave
  sleep disabled after Meth exited unexpectedly.

### Security

- Meth contains no networking code, analytics, or telemetry, and has no third-party
  dependencies.
- The Meth process never runs as root and no background daemon is installed. During normal
  use its only privileged commands are the two fixed `pmset` commands allowed by the
  `sudoers.d` rule; installing or removing that rule runs a fixed script as root after an
  administrator password prompt.

[Unreleased]: https://github.com/BTFLV/Meth/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/BTFLV/Meth/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BTFLV/Meth/releases/tag/v1.0.0
