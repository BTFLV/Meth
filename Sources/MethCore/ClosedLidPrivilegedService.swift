import Foundation
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "ClosedLidPrivilegedService")

public final class ClosedLidPrivilegedService: ClosedLidPrivilegedManaging, @unchecked Sendable {
    public static let shared = ClosedLidPrivilegedService()

    public static let sudoersFilePath = "/private/etc/sudoers.d/meth-closed-lid"
    public static let pmsetPath = "/usr/bin/pmset"
    public static let sudoPath = "/usr/bin/sudo"

    public init() {}

    public var isSupportInstalled: Bool {
        if FileManager.default.fileExists(atPath: Self.sudoersFilePath) {
            // Validate that sudo -n can actually execute pmset without prompting
            let res = execute(executable: Self.sudoPath, arguments: ["-n", Self.pmsetPath, "-a", "disablesleep", "0"])
            return res.exitCode == 0
        }
        return false
    }

    public func isSleepDisabled() -> Bool {
        let res = execute(executable: Self.pmsetPath, arguments: ["-g", "live"])
        guard res.exitCode == 0 else {
            return false
        }
        // Check for line matching "SleepDisabled 1" or containing "SleepDisabled" with value 1
        for line in res.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SleepDisabled") {
                let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, parts[1] == "1" {
                    return true
                }
            }
        }
        return false
    }

    public func enableSleepDisabled() throws {
        guard isSupportInstalled else {
            throw ClosedLidError.supportNotInstalled
        }

        let res = execute(executable: Self.sudoPath, arguments: ["-n", Self.pmsetPath, "-a", "disablesleep", "1"])
        guard res.exitCode == 0 else {
            logger.error("Failed to enable SleepDisabled: \(res.stderr)")
            throw ClosedLidError.executionFailed(
                command: "sudo -n pmset -a disablesleep 1",
                exitCode: res.exitCode,
                stderr: res.stderr
            )
        }
        logger.info("Successfully enabled SleepDisabled (pmset -a disablesleep 1)")
    }

    public func disableSleepDisabled() throws {
        // We attempt disable even if sudoers might be removed, but use -n
        let res = execute(executable: Self.sudoPath, arguments: ["-n", Self.pmsetPath, "-a", "disablesleep", "0"])
        if res.exitCode != 0 {
            logger.error("Failed to disable SleepDisabled: \(res.stderr)")
            throw ClosedLidError.executionFailed(
                command: "sudo -n pmset -a disablesleep 0",
                exitCode: res.exitCode,
                stderr: res.stderr
            )
        }
        logger.info("Successfully disabled SleepDisabled (pmset -a disablesleep 0)")
    }

    public func putDisplayToSleep() {
        let res = execute(executable: Self.pmsetPath, arguments: ["displaysleepnow"])
        if res.exitCode == 0 {
            logger.info("Triggered display sleep via pmset displaysleepnow")
        } else {
            logger.error("Failed to trigger display sleep: \(res.stderr)")
        }
    }

    public func installSupport() throws {
        let ruleContent = "%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let script = """
        do shell script "printf '%s\\n' '\(ruleContent)' > '\(Self.sudoersFilePath)' && chmod 0440 '\(Self.sudoersFilePath)' && chown root:wheel '\(Self.sudoersFilePath)' && /usr/sbin/visudo -c -f '\(Self.sudoersFilePath)'" with administrator privileges
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                logger.error("Installation AppleScript failed: \(message)")
                throw ClosedLidError.installationFailed(message)
            }
        } else {
            throw ClosedLidError.installationFailed("Failed to initialize AppleScript.")
        }

        // Verify that it works
        guard isSupportInstalled else {
            throw ClosedLidError.installationFailed("Support installed but authorization check failed.")
        }
        logger.info("Closed-Lid support installed successfully.")
    }

    public func uninstallSupport() throws {
        let script = """
        do shell script "/usr/bin/pmset -a disablesleep 0; rm -f '\(Self.sudoersFilePath)'" with administrator privileges
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                logger.error("Uninstallation AppleScript failed: \(message)")
                throw ClosedLidError.uninstallationFailed(message)
            }
        } else {
            throw ClosedLidError.uninstallationFailed("Failed to initialize AppleScript.")
        }
        logger.info("Closed-Lid support uninstalled successfully.")
    }

    private func execute(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
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

