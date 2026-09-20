import Foundation
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "ClosedLidPrivilegedService")

/// Real `Process`-backed command execution. Kept tiny and swappable so tests can verify
/// exactly which commands `ClosedLidPrivilegedService` issues without running privileged
/// subprocesses.
public struct SystemProcessExecutor: ProcessExecuting {
    public init() {}

    public func execute(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            return (process.terminationStatus, stdout, stderr)
        } catch {
            return (-1, "", error.localizedDescription)
        }
    }
}

/// Owns every interaction with the privileged `SleepDisabled` mechanism used by Closed-Lid
/// Mode. All state-mutating operations run a single, fixed `pmset` command via `sudo -n`
/// (never a generic shell), and status queries never execute a mutating command.
public final class ClosedLidPrivilegedService: ClosedLidPrivilegedManaging, @unchecked Sendable {
    public static let shared = ClosedLidPrivilegedService()

    public static let defaultSudoersFilePath = "/private/etc/sudoers.d/meth-closed-lid"
    public static let pmsetPath = "/usr/bin/pmset"
    public static let sudoPath = "/usr/bin/sudo"

    /// Tracks whether Meth itself most recently enabled `SleepDisabled`, so recovery logic
    /// never clobbers a value some other tool or administrator may have set intentionally.
    /// Not security-sensitive: purely an ownership hint, stored per-user.
    private static let ownershipMarkerKey = "com.meth.closedLid.sleepDisabledOwnedByMeth"

    private let sudoersFilePath: String
    private let executor: any ProcessExecuting
    private let ownershipDefaults: UserDefaults

    public init(
        sudoersFilePath: String = ClosedLidPrivilegedService.defaultSudoersFilePath,
        executor: any ProcessExecuting = SystemProcessExecutor(),
        ownershipDefaults: UserDefaults = ClosedLidSharedState.defaults
    ) {
        self.sudoersFilePath = sudoersFilePath
        self.executor = executor
        self.ownershipDefaults = ownershipDefaults
    }

    // MARK: - Status (read-only)

    public func supportStatus() -> ClosedLidSupportStatus {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sudoersFilePath) else {
            return .notInstalled
        }

        guard let attributes = try? fm.attributesOfItem(atPath: sudoersFilePath) else {
            return .invalidConfiguration("Unable to read the sudoers file's attributes.")
        }
        if let ownerID = attributes[.ownerAccountID] as? NSNumber, ownerID.intValue != 0 {
            return .invalidConfiguration("Sudoers file is not owned by root.")
        }
        if let permissions = attributes[.posixPermissions] as? NSNumber, permissions.uint16Value != 0o440 {
            return .invalidConfiguration("Sudoers file does not have the expected 0440 permissions.")
        }

        // Non-mutating: `sudo -n -l <command>` reports whether the command would be
        // permitted without a password, but never executes it.
        guard isCommandPermitted(arguments: ["-a", "disablesleep", "1"]),
              isCommandPermitted(arguments: ["-a", "disablesleep", "0"]) else {
            return .invalidConfiguration("Required pmset commands are not authorized without a password.")
        }

        return .installed
    }

    private func isCommandPermitted(arguments: [String]) -> Bool {
        let result = executor.execute(executable: Self.sudoPath, arguments: ["-n", "-l", Self.pmsetPath] + arguments)
        return result.exitCode == 0
    }

    public func isSleepDisabled() -> Bool {
        let result = executor.execute(executable: Self.pmsetPath, arguments: ["-g", "live"])
        guard result.exitCode == 0 else { return false }

        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SleepDisabled") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[1] == "1" {
                return true
            }
        }
        return false
    }

    public func isOwnershipMarkerSet() -> Bool {
        ownershipDefaults.bool(forKey: Self.ownershipMarkerKey)
    }

    public func clearOwnershipMarker() {
        ownershipDefaults.removeObject(forKey: Self.ownershipMarkerKey)
    }

    private func setOwnershipMarker() {
        ownershipDefaults.set(true, forKey: Self.ownershipMarkerKey)
    }

    // MARK: - Mutating operations

    public func enableSleepDisabled() throws {
        guard supportStatus() == .installed else {
            throw ClosedLidError.supportNotInstalled
        }

        // Record ownership before mutating: if the process crashes between these two
        // lines, the marker is merely stale (harmless), whereas the reverse order could
        // leave SleepDisabled=1 with no record that Meth is responsible for it.
        setOwnershipMarker()

        let result = executor.execute(executable: Self.sudoPath, arguments: ["-n", Self.pmsetPath, "-a", "disablesleep", "1"])
        guard result.exitCode == 0 else {
            logger.error("Failed to enable SleepDisabled: \(result.stderr)")
            throw ClosedLidError.executionFailed(
                command: "sudo -n pmset -a disablesleep 1",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        logger.info("Successfully enabled SleepDisabled (pmset -a disablesleep 1)")
    }

    public func disableSleepDisabled() throws {
        let result = executor.execute(executable: Self.sudoPath, arguments: ["-n", Self.pmsetPath, "-a", "disablesleep", "0"])
        guard result.exitCode == 0 else {
            logger.error("Failed to disable SleepDisabled: \(result.stderr)")
            throw ClosedLidError.executionFailed(
                command: "sudo -n pmset -a disablesleep 0",
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        clearOwnershipMarker()
        logger.info("Successfully disabled SleepDisabled (pmset -a disablesleep 0)")
    }

    @discardableResult
    public func restoreSleepDisabledForFailsafe(maxAttempts: Int = 4) -> Bool {
        restoreSleepDisabledForFailsafe(
            maxAttempts: maxAttempts,
            retryDelay: { attempt in min(0.4, 0.1 * Double(attempt)) },
            sleeper: { seconds in
                guard seconds > 0 else { return }
                usleep(useconds_t(seconds * 1_000_000))
            }
        )
    }

    /// Testable overload: `retryDelay`/`sleeper` are injectable seams, not part of the
    /// public protocol, so tests can exercise retry/backoff behavior without real delays.
    @discardableResult
    public func restoreSleepDisabledForFailsafe(
        maxAttempts: Int,
        retryDelay: (Int) -> TimeInterval,
        sleeper: (TimeInterval) -> Void
    ) -> Bool {
        guard maxAttempts > 0 else { return !isSleepDisabled() }

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                sleeper(retryDelay(attempt))
            }
            let result = executor.execute(executable: Self.sudoPath, arguments: ["-n", Self.pmsetPath, "-a", "disablesleep", "0"])
            if result.exitCode == 0 && !isSleepDisabled() {
                clearOwnershipMarker()
                logger.info("Failsafe SleepDisabled restoration succeeded on attempt \(attempt)/\(maxAttempts).")
                return true
            }
            logger.error("Failsafe SleepDisabled restoration attempt \(attempt)/\(maxAttempts) failed (exit=\(result.exitCode)): \(result.stderr)")
        }

        logger.fault("Failsafe SleepDisabled restoration failed after \(maxAttempts) attempts. System sleep may remain disabled until Meth is relaunched.")
        return false
    }

    public func putDisplayToSleep() {
        let result = executor.execute(executable: Self.pmsetPath, arguments: ["displaysleepnow"])
        if result.exitCode == 0 {
            logger.info("Triggered display sleep via pmset displaysleepnow")
        } else {
            logger.error("Failed to trigger display sleep: \(result.stderr)")
        }
    }

    // MARK: - Install / uninstall

    public func installSupport() throws {
        let ruleContent = "%admin ALL=(root) NOPASSWD: \(Self.pmsetPath) -a disablesleep 0, \(Self.pmsetPath) -a disablesleep 1"

        // Write to a randomly-named temporary file in the same root-owned directory, set
        // ownership/permissions, validate with visudo, and only then atomically rename it
        // into place. This avoids ever exposing a partially-configured file, or writing
        // through a pre-existing symlink, at the final sudoers path.
        let shellCommand = """
        set -e
        TMP=$(/usr/bin/mktemp '\(sudoersFilePath).XXXXXX')
        trap 'rm -f "$TMP"' EXIT
        printf '%s\\n' '\(ruleContent)' > "$TMP"
        chmod 0440 "$TMP"
        chown root:wheel "$TMP"
        /usr/sbin/visudo -c -f "$TMP"
        mv -f "$TMP" '\(sudoersFilePath)'
        """

        do {
            try runAsAdministrator(shellCommand)
        } catch {
            logger.error("Installation failed: \(error.localizedDescription)")
            throw ClosedLidError.installationFailed(error.localizedDescription)
        }

        guard supportStatus() == .installed else {
            throw ClosedLidError.installationFailed("Support was installed but validation did not confirm it is usable.")
        }
        logger.info("Closed-Lid support installed successfully.")
    }

    public func uninstallSupport() throws {
        // 1. Restore normal sleep behavior first, while the privileged rule still exists.
        if isSleepDisabled() {
            try disableSleepDisabled()
        }
        guard !isSleepDisabled() else {
            throw ClosedLidError.uninstallationFailed("Could not confirm normal sleep behavior before removing support.")
        }

        // 2. Remove the sudoers file under a single administrator authorization.
        do {
            try runAsAdministrator("rm -f '\(sudoersFilePath)'")
        } catch {
            logger.error("Uninstallation failed: \(error.localizedDescription)")
            throw ClosedLidError.uninstallationFailed(error.localizedDescription)
        }

        // 3. Verify removal; never report success unless the file is actually gone.
        guard !FileManager.default.fileExists(atPath: sudoersFilePath) else {
            throw ClosedLidError.uninstallationFailed("Sudoers file still exists after removal was attempted.")
        }

        clearOwnershipMarker()
        logger.info("Closed-Lid support uninstalled successfully.")
    }

    private func runAsAdministrator(_ shellCommand: String) throws {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        guard let appleScript = NSAppleScript(source: script) else {
            throw ClosedLidError.installationFailed("Failed to initialize AppleScript runner.")
        }

        var scriptError: NSDictionary?
        appleScript.executeAndReturnError(&scriptError)
        if let scriptError {
            let message = scriptError[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw ClosedLidError.installationFailed(message)
        }
    }
}

