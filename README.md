# Meth

Meth is a lightweight, native macOS menu bar utility designed to control system sleep and prevent unexpected sleep interruptions.

Its primary differentiator is an explicit, reliable **Closed-Lid Mode**. While standard macOS sleep assertions prevent idle sleep when a laptop is open, they do not prevent sleep when the MacBook lid is closed. Meth provides a dedicated mechanism to keep long-running tasks—such as software builds, large downloads, remote SSH sessions, local web or database servers, and background processes—active when the lid is closed.

Meth is not affiliated with Amphetamine.

---

## Capabilities

Meth separates power management into distinct modes rather than treating all sleep states identically:

### 1. Normal Keep Awake Mode
Uses native macOS IOKit power management assertions (`kIOPMAssertPreventUserIdleSystemSleep` and `kIOPMAssertPreventUserIdleDisplaySleep`) to prevent the Mac from entering idle sleep during inactive periods.
- **Session Durations**: Indefinitely, 5 minutes, 15 minutes, 30 minutes, 1 hour, 2 hours, 4 hours, 8 hours, or Until a specific time (e.g., Until 23:00).
- **Display Sleep Option**: By default, "Allow Display Sleep" is enabled so that internal and external displays can turn off on their idle timers while the system continues running. Users can uncheck this option to force displays to stay on.

### 2. Closed-Lid Mode
Closing the MacBook lid triggers a hardware clamshell signal that bypasses standard idle power assertions. Closed-Lid Mode engages a system-level override to keep user processes running even with the lid shut.
- **Internal Display Behavior**: Closing the lid immediately powers down the internal LCD panel backlight, avoiding wasted power and display heat.
- **Power Source Resilience**: Maintains active state across power adapter connect and disconnect events on Apple Silicon.
- **Battery Safety Cutoff**: Automatically deactivates and restores default sleep behavior if the battery drops to 10% or below on battery power, protecting the system from emergency hardware shutoffs.
- **Session Restoration**: Safely restores normal sleep settings when the session stops, the timer expires, the app quits, or a session is replaced.

---

## Thermal and Safety Considerations

> **Warning:**
> Closed-Lid Mode keeps the Mac processor, memory, and fans active while the lid is closed. This increases battery consumption and generates heat.
> 
> **Never place an actively running closed MacBook into an enclosed bag, backpack, sleeve, or unventilated space.** Keep the laptop on a flat, solid surface with adequate ventilation around the exhaust vents.

---

## Security Model and Privileged State

Standard macOS power management does not permit unprivileged user applications to override lid-closed sleep. Modifying this behavior requires toggling the kernel's `SleepDisabled` parameter via `/usr/bin/pmset -a disablesleep`.

To maintain the principle of least privilege:
1. **The application never runs as root.** Meth runs strictly as an unprivileged user process.
2. **No permanent daemons or open-ended privileges.** Meth does not install persistent root daemons or background network agents.
3. **Narrowly Scoped Sudoers Rule**: Administrator authentication is requested once during setup to install a drop-in configuration file at:
   ```text
   /private/etc/sudoers.d/meth-closed-lid
   ```
   This configuration strictly permits members of the `%admin` group to execute only:
   - `/usr/bin/pmset -a disablesleep 0`
   - `/usr/bin/pmset -a disablesleep 1`
   No wildcards, arbitrary commands, or script execution are allowed.
4. **Auditable and Removable**: The configuration file is validated using `/usr/sbin/visudo -c -f` during installation and can be cleanly removed at any time with a single click in Meth Settings (`Remove Support`).

### Fail-Safe Crash Recovery

Meth incorporates multiple safeguards against leaving the system in a permanently altered sleep state:
- **Independent Watchdog**: When Closed-Lid Mode is engaged, Meth spawns a lightweight watchdog (`MethWatchdog`) that monitors the parent application process using kernel events (`kqueue` `EVFILT_PROC` / `NOTE_EXIT`). If Meth crashes, is force-terminated, or reaches its scheduled session timeout, the watchdog immediately restores normal sleep behavior (`pmset -a disablesleep 0`).
- **Launch Recovery**: Each time Meth starts, it verifies system sleep status. If an orphan `SleepDisabled 1` state is detected without an active session, it automatically resets the state to normal.
- **Normal Quit Cleanup**: Application termination cleanly releases all active IOKit assertions and disables privileged overrides.

---

## Installation

### Option 1: Direct Download
1. Download `Meth.zip` from the latest release.
2. Unzip and move `Meth.app` to your `/Applications` directory.
3. Open `Meth.app`.
4. To enable Closed-Lid Mode, open **Settings > Closed-Lid Support** and click **Install Support** to authorize the scoped rule.

### Option 2: Build from Source
Requirements: macOS 13.0+, Swift 5.9+ / Xcode 15+.

```bash
# Clone the repository
git clone https://github.com/philipmohr/Meth.git
cd Meth

# Build with Swift Package Manager
swift build -c release

# Run the automated test suite
swift test

# Build the distributable Meth.app bundle and Meth.zip
./scripts/build_app.sh
```

The packaged application will be generated in `dist/Meth.app` and `dist/Meth.zip`.

---

## System Requirements

- **macOS**: macOS 13.0 (Ventura) or later.
- **Architectures**: Apple Silicon (M1/M2/M3/M4) and Intel (x86_64).
- **Privileges**: Standard user permissions for ordinary keep-awake mode. Administrator authentication (once) is required only if Closed-Lid Mode is enabled.

---

## Privacy

Meth is strictly offline software.
- Zero network traffic or network listeners.
- No analytics, telemetry, or crash reporting services.
- No third-party tracking frameworks.
- No user accounts or cloud synchronization.

---

## Limitations

- **Gatekeeper**: Standalone development builds without Apple Developer ID notarization require right-clicking the app and selecting *Open* on first launch.
- **Thermal Dissipation**: MacBooks dissipate heat partly through the keyboard deck. When closed under heavy CPU or GPU loads, thermal throttling may occur sooner than with the display open.

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

