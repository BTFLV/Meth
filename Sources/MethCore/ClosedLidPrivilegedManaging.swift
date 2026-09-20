import Foundation

public enum ClosedLidError: Error, Equatable, LocalizedError {
    case supportNotInstalled
    case activeSessionInProgress
    case batteryTooLow(Int?)
    case executionFailed(command: String, exitCode: Int32, stderr: String)
    case installationFailed(String)
    case uninstallationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .supportNotInstalled:
            return "Closed-Lid support is not installed. Please install it in Settings."
        case .activeSessionInProgress:
            return "Stop the active Closed-Lid session before removing Closed-Lid support."
        case .batteryTooLow(let level):
            let reading = level.map { "\($0)%" } ?? "below the safety threshold"
            return "Closed-Lid Mode was not started: the battery is at \(reading) and the Mac is not connected to power. Connect a power adapter and try again."
        case .executionFailed(let command, let exitCode, let stderr):
            return "Command '\(command)' failed with code \(exitCode): \(stderr)"
        case .installationFailed(let reason):
            return "Failed to install Closed-Lid support: \(reason)"
        case .uninstallationFailed(let reason):
            return "Failed to remove Closed-Lid support: \(reason)"
        }
    }
}

/// Distinguishes "files present", "configuration is valid", and "commands are actually
/// authorized" so callers never have to infer privileged-command availability from a
/// single ambiguous Boolean.
public enum ClosedLidSupportStatus: Equatable, Sendable {
    case notInstalled
    case invalidConfiguration(String)
    case installed
}

/// Executes a fixed external command and reports its result. Exists purely as a seam so
/// tests can verify which commands a privileged operation actually invokes without
/// running real privileged subprocesses.
public protocol ProcessExecuting: Sendable {
    func execute(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String)
}

public protocol ClosedLidPrivilegedManaging: AnyObject, Sendable {
    /// Read-only: must never mutate system sleep state.
    func supportStatus() -> ClosedLidSupportStatus
    /// Read-only: queries live `pmset` state, does not mutate anything.
    func isSleepDisabled() -> Bool
    func enableSleepDisabled() throws
    func disableSleepDisabled() throws
    func putDisplayToSleep()
    func installSupport() throws
    func uninstallSupport() throws

    /// Best-effort, retrying restoration used only by crash/timeout failsafe paths
    /// (the watchdog and startup recovery), never by interactive UI flows.
    @discardableResult
    func restoreSleepDisabledForFailsafe(maxAttempts: Int) -> Bool

    /// Tracks whether Meth itself is the one that most recently set `SleepDisabled`,
    /// so recovery logic never clobbers a value it did not set.
    func isOwnershipMarkerSet() -> Bool
    func clearOwnershipMarker()
}

public extension ClosedLidPrivilegedManaging {
    /// Convenience for call sites that only care about the binary "can Closed-Lid Mode
    /// be used right now" question.
    var isSupportInstalled: Bool {
        supportStatus() == .installed
    }
}

/// `Meth.app` and the standalone `MethWatchdog` helper are separate processes with
/// different bundle identifiers, so `UserDefaults.standard` resolves to two different,
/// invisible-to-each-other preference domains. Anything that needs to be read or written
/// by both (the ownership marker, the active watchdog generation) must use this explicit,
/// shared suite instead.
public enum ClosedLidSharedState {
    public static let suiteName = "com.meth.app.shared"

    public static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Identifies which watchdog process is currently authorized to restore sleep state.
    /// Written by `WatchdogClient` before a watchdog is spawned; checked by the watchdog
    /// itself immediately before it would mutate `SleepDisabled`, so a watchdog that has
    /// been superseded by a later activation or session-extension (but whose own process,
    /// or an orphaned subprocess of it, is still alive) can detect that and do nothing.
    public static let activeWatchdogGenerationKey = "com.meth.closedLid.activeWatchdogGeneration"
}

