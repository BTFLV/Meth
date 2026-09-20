import Foundation

public enum ClosedLidError: Error, Equatable, LocalizedError {
    case supportNotInstalled
    case executionFailed(command: String, exitCode: Int32, stderr: String)
    case installationFailed(String)
    case uninstallationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .supportNotInstalled:
            return "Closed-Lid support is not installed. Please install it in Settings."
        case .executionFailed(let command, let exitCode, let stderr):
            return "Command '\(command)' failed with code \(exitCode): \(stderr)"
        case .installationFailed(let reason):
            return "Failed to install Closed-Lid support: \(reason)"
        case .uninstallationFailed(let reason):
            return "Failed to remove Closed-Lid support: \(reason)"
        }
    }
}

public protocol ClosedLidPrivilegedManaging: AnyObject, Sendable {
    var isSupportInstalled: Bool { get }
    func isSleepDisabled() -> Bool
    func enableSleepDisabled() throws
    func disableSleepDisabled() throws
    func putDisplayToSleep()
    func installSupport() throws
    func uninstallSupport() throws
}

