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

/// Runs a fixed shell command as root after macOS asks the user for administrator
/// authentication. A seam so tests can verify the exact privileged scripts without running
/// them.
public protocol AdministratorScriptRunning: Sendable {
    func runAsAdministrator(_ shellCommand: String) throws
}

public enum AdministratorScriptError: Error, Equatable {
    case cancelled
    case failed(String)
}

/// Runs the command through AppleScript's `do shell script … with administrator
/// privileges`, which shows the standard macOS authentication prompt.
public struct AppleScriptAdministratorRunner: AdministratorScriptRunning {
    /// AppleScript's "User canceled." error.
    private static let userCancelledErrorNumber = -128

    public init() {}

    public func runAsAdministrator(_ shellCommand: String) throws {
        // NSAppleScript may only be used on the main thread, while callers run on the
        // Closed-Lid controller's executor. Hopping over synchronously cannot deadlock: the
        // main thread only ever awaits that executor, it never blocks on it.
        if Thread.isMainThread {
            try Self.run(shellCommand)
        } else {
            try DispatchQueue.main.sync { try Self.run(shellCommand) }
        }
    }

    private static func run(_ shellCommand: String) throws {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        guard let appleScript = NSAppleScript(source: script) else {
            throw AdministratorScriptError.failed("Failed to initialize AppleScript runner.")
        }

        var scriptError: NSDictionary?
        appleScript.executeAndReturnError(&scriptError)
        if let scriptError {
            if (scriptError[NSAppleScript.errorNumber] as? Int) == userCancelledErrorNumber {
                throw AdministratorScriptError.cancelled
            }
            let message = scriptError[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw AdministratorScriptError.failed(message)
        }
    }
}

/// Owns every interaction with the privileged `SleepDisabled` mechanism used by Closed-Lid
/// Mode. During normal use, state-mutating operations run a single, fixed `pmset` command
/// via `sudo -n` (never a shell), and status queries never execute a mutating command.
/// Installing and removing support, and restoring sleep without a usable rule, each run one
/// fixed script through the administrator authentication prompt instead.
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
    private let administratorRunner: any AdministratorScriptRunning

    public init(
        sudoersFilePath: String = ClosedLidPrivilegedService.defaultSudoersFilePath,
        executor: any ProcessExecuting = SystemProcessExecutor(),
        ownershipDefaults: UserDefaults = ClosedLidSharedState.defaults,
        administratorRunner: any AdministratorScriptRunning = AppleScriptAdministratorRunner()
    ) {
        self.sudoersFilePath = sudoersFilePath
        self.executor = executor
        self.ownershipDefaults = ownershipDefaults
        self.administratorRunner = administratorRunner
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

        // Non-mutating: `sudo -n -l <command>` never executes the command. It succeeds only
        // if sudoers parses, some NOPASSWD rule applies to this account (so listing needs no
        // password), and the command is permitted at all -- for an administrator possibly by
        // the password-protected `%admin ALL=(ALL) ALL` rule rather than Meth's. Combined
        // with the root-owned 0440 file above, that is the strongest check available without
        // running `pmset`; an unusable rule still surfaces as a failure when enabling.
        guard isCommandPermitted(arguments: ["-a", "disablesleep", "1"]),
              isCommandPermitted(arguments: ["-a", "disablesleep", "0"]) else {
            return .invalidConfiguration("This account cannot use the installed rule without a password. Closed-Lid Mode requires an administrator account.")
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

        // Current macOS releases separate the key from its value with tabs
        // (" SleepDisabled\t\t1"), others with runs of spaces, so split on any whitespace.
        // Splitting on " " alone made this always report false on real systems, which
        // silently disabled the watchdog and startup recovery.
        for line in result.stdout.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    // The marker is written by `Meth.app` and read/cleared by the separate `MethWatchdog`
    // process, so every access explicitly flushes or re-reads the shared suite rather than
    // trusting whatever each process cached at launch.

    public func isOwnershipMarkerSet() -> Bool {
        ownershipDefaults.synchronize()
        return ownershipDefaults.bool(forKey: Self.ownershipMarkerKey)
    }

    public func clearOwnershipMarker() {
        ownershipDefaults.removeObject(forKey: Self.ownershipMarkerKey)
        ownershipDefaults.synchronize()
    }

    private func setOwnershipMarker() {
        ownershipDefaults.set(true, forKey: Self.ownershipMarkerKey)
        ownershipDefaults.synchronize()
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
            try administratorRunner.runAsAdministrator(shellCommand)
        } catch {
            logger.error("Installation failed: \(String(describing: error))")
            throw Self.administratorError(error, wrap: ClosedLidError.installationFailed)
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
            try administratorRunner.runAsAdministrator("rm -f '\(sudoersFilePath)'")
        } catch {
            logger.error("Uninstallation failed: \(String(describing: error))")
            throw Self.administratorError(error, wrap: ClosedLidError.uninstallationFailed)
        }

        // 3. Verify removal; never report success unless the file is actually gone.
        guard !FileManager.default.fileExists(atPath: sudoersFilePath) else {
            throw ClosedLidError.uninstallationFailed("Sudoers file still exists after removal was attempted.")
        }

        clearOwnershipMarker()
        logger.info("Closed-Lid support uninstalled successfully.")
    }

    public func restoreSleepDisabledWithAdministratorPrivileges() throws {
        do {
            try administratorRunner.runAsAdministrator("\(Self.pmsetPath) -a disablesleep 0")
        } catch {
            logger.error("Restoring normal sleep failed: \(String(describing: error))")
            throw Self.administratorError(error, wrap: ClosedLidError.restoreFailed)
        }
        guard !isSleepDisabled() else {
            throw ClosedLidError.restoreFailed("System sleep is still disabled.")
        }
        clearOwnershipMarker()
        logger.info("Normal sleep restored with administrator authentication.")
    }

    /// Maps a failed administrator script to a single user-facing error: a dismissed
    /// authentication prompt is reported as such, never as a failure of the operation.
    private static func administratorError(_ error: Error, wrap: (String) -> ClosedLidError) -> ClosedLidError {
        switch error {
        case AdministratorScriptError.cancelled:
            return .authorizationCancelled
        case AdministratorScriptError.failed(let message):
            return wrap(message)
        default:
            return wrap(error.localizedDescription)
        }
    }
}

