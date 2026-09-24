import Foundation
import XCTest
@testable import MethCore

/// Simulates real `pmset`/`sudo` behavior for a single boolean `SleepDisabled` flag, so
/// `restoreSleepDisabledForFailsafe`'s retry/backoff/verification logic can be exercised
/// deterministically without touching real system state.
final class SimulatedPmsetExecutor: ProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var sleepDisabled: Bool
    private var remainingFailures: Int
    var spawnFailureAlways = false
    private(set) var attemptCount = 0

    init(initiallySleepDisabled: Bool, failuresBeforeSuccess: Int) {
        self.sleepDisabled = initiallySleepDisabled
        self.remainingFailures = failuresBeforeSuccess
    }

    func execute(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }

        if arguments.contains("live") {
            let value = sleepDisabled ? "1" : "0"
            // Matches real `pmset -g live` output, which separates this key from its
            // value with tabs.
            return (0, "System-wide power settings:\n SleepDisabled\t\t\(value)\n", "")
        }

        guard arguments.contains("disablesleep"), arguments.contains("0") else {
            return (0, "", "")
        }

        attemptCount += 1
        if spawnFailureAlways {
            return (-1, "", "spawn failed")
        }
        if remainingFailures > 0 {
            remainingFailures -= 1
            return (1, "", "a password is required")
        }
        sleepDisabled = false
        return (0, "", "")
    }
}

final class ClosedLidPrivilegedServiceTests: XCTestCase {
    func testSupportStatusNeverMutatesSleepState() {
        let recorder = RecordingProcessExecutor()
        let tempDir = FileManager.default.temporaryDirectory
        let sudoersPath = tempDir.appendingPathComponent("meth-test-sudoers-\(UUID().uuidString)").path

        let service = ClosedLidPrivilegedService(sudoersFilePath: sudoersPath, executor: recorder)

        // Case 1: no sudoers file present at all.
        _ = service.supportStatus()
        XCTAssertFalse(recorder.everMutatedDisableSleep)

        // Case 2: a file exists at the expected path (ownership/permissions will not match
        // root:wheel 0440 in a test process, which is itself a safe, non-mutating outcome
        // -- the important invariant is that checking status never executes a mutating
        // `disablesleep` command regardless of what it finds).
        FileManager.default.createFile(atPath: sudoersPath, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(atPath: sudoersPath) }

        _ = service.supportStatus()
        _ = service.isSupportInstalled
        XCTAssertFalse(recorder.everMutatedDisableSleep, "Checking support status must never disable or enable SleepDisabled.")
    }

    func testRestoreSleepDisabledForFailsafeSucceedsOnFirstAttempt() {
        let executor = SimulatedPmsetExecutor(initiallySleepDisabled: true, failuresBeforeSuccess: 0)
        let service = ClosedLidPrivilegedService(
            sudoersFilePath: "/tmp/does-not-matter",
            executor: executor,
            ownershipDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        let result = service.restoreSleepDisabledForFailsafe(maxAttempts: 3, retryDelay: { _ in 0 }, sleeper: { _ in })

        XCTAssertTrue(result)
        XCTAssertEqual(executor.attemptCount, 1)
        XCTAssertFalse(service.isSleepDisabled())
    }

    func testRestoreSleepDisabledForFailsafeRetriesThenSucceeds() {
        let executor = SimulatedPmsetExecutor(initiallySleepDisabled: true, failuresBeforeSuccess: 2)
        let service = ClosedLidPrivilegedService(
            sudoersFilePath: "/tmp/does-not-matter",
            executor: executor,
            ownershipDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        let result = service.restoreSleepDisabledForFailsafe(maxAttempts: 5, retryDelay: { _ in 0 }, sleeper: { _ in })

        XCTAssertTrue(result)
        XCTAssertEqual(executor.attemptCount, 3)
    }

    func testRestoreSleepDisabledForFailsafeExhaustsAttemptsAndReportsFailure() {
        let executor = SimulatedPmsetExecutor(initiallySleepDisabled: true, failuresBeforeSuccess: 100)
        let service = ClosedLidPrivilegedService(
            sudoersFilePath: "/tmp/does-not-matter",
            executor: executor,
            ownershipDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        let result = service.restoreSleepDisabledForFailsafe(maxAttempts: 3, retryDelay: { _ in 0 }, sleeper: { _ in })

        XCTAssertFalse(result)
        XCTAssertEqual(executor.attemptCount, 3)
        XCTAssertTrue(service.isSleepDisabled(), "A failed restoration must not be reported as if sleep were restored.")
    }

    func testRestoreSleepDisabledForFailsafeHandlesProcessSpawnFailure() {
        let executor = SimulatedPmsetExecutor(initiallySleepDisabled: true, failuresBeforeSuccess: 0)
        executor.spawnFailureAlways = true
        let service = ClosedLidPrivilegedService(
            sudoersFilePath: "/tmp/does-not-matter",
            executor: executor,
            ownershipDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )

        let result = service.restoreSleepDisabledForFailsafe(maxAttempts: 2, retryDelay: { _ in 0 }, sleeper: { _ in })

        XCTAssertFalse(result)
        XCTAssertEqual(executor.attemptCount, 2)
    }

    func testOwnershipMarkerLifecycle() {
        let executor = SimulatedPmsetExecutor(initiallySleepDisabled: false, failuresBeforeSuccess: 0)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let service = ClosedLidPrivilegedService(
            sudoersFilePath: "/tmp/does-not-matter",
            executor: executor,
            ownershipDefaults: defaults
        )

        XCTAssertFalse(service.isOwnershipMarkerSet())
        service.clearOwnershipMarker() // no-op, must not throw or crash
        XCTAssertFalse(service.isOwnershipMarkerSet())
    }

    /// Regression test: `isSleepDisabled()` once split lines on " " only, so the
    /// tab-separated output of real `pmset -g live` always read as "not disabled" -- which
    /// made the watchdog and startup recovery skip restoring sleep entirely.
    func testIsSleepDisabledParsesTabAndSpaceSeparatedPmsetOutput() {
        let cases: [(output: String, expected: Bool)] = [
            ("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby              1\n", true),
            ("System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n standby              1\n", false),
            (" SleepDisabled              1\n", true),
            (" SleepDisabled              0\n", false),
            // Other keys with a value of 1 must not be mistaken for SleepDisabled.
            ("Currently in use:\n Sleep On Power Button 1\n standby              1\n", false),
            ("", false)
        ]

        for (output, expected) in cases {
            let executor = RecordingProcessExecutor()
            executor.resultProvider = { _, _ in (0, output, "") }
            let service = ClosedLidPrivilegedService(sudoersFilePath: "/tmp/does-not-matter", executor: executor)
            XCTAssertEqual(service.isSleepDisabled(), expected, "pmset output: \(output.debugDescription)")
        }
    }

    private func makeService(
        sleepDisabled: Bool = false,
        runner: RecordingAdministratorRunner
    ) -> (ClosedLidPrivilegedService, String) {
        let sudoersPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("meth-test-sudoers-\(UUID().uuidString)").path
        let executor = RecordingProcessExecutor()
        executor.resultProvider = { _, arguments in
            arguments.contains("live") ? (0, pmsetLiveOutput(sleepDisabled: sleepDisabled), "") : (0, "", "")
        }
        let service = ClosedLidPrivilegedService(
            sudoersFilePath: sudoersPath,
            executor: executor,
            ownershipDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            administratorRunner: runner
        )
        return (service, sudoersPath)
    }

    func testInstallRunsOneValidatedAtomicScriptForTheFixedRule() {
        let runner = RecordingAdministratorRunner()
        let (service, sudoersPath) = makeService(runner: runner)

        // The recording runner installs nothing, so validation afterwards must fail loudly.
        XCTAssertThrowsError(try service.installSupport()) { error in
            XCTAssertEqual(
                error as? ClosedLidError,
                .installationFailed("Support was installed but validation did not confirm it is usable.")
            )
        }

        XCTAssertEqual(runner.commands.count, 1)
        let script = runner.commands.first ?? ""
        XCTAssertTrue(script.contains("/usr/bin/mktemp '\(sudoersPath).XXXXXX'"))
        XCTAssertTrue(script.contains("'%admin ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1'"))
        XCTAssertTrue(script.contains("chmod 0440 \"$TMP\""))
        XCTAssertTrue(script.contains("chown root:wheel \"$TMP\""))
        XCTAssertTrue(script.contains("/usr/sbin/visudo -c -f \"$TMP\""))
        XCTAssertTrue(script.contains("mv -f \"$TMP\" '\(sudoersPath)'"))
    }

    func testCancelledAuthenticationIsReportedAsSuch() {
        let runner = RecordingAdministratorRunner()
        runner.error = .cancelled
        let (service, _) = makeService(runner: runner)

        XCTAssertThrowsError(try service.installSupport()) { error in
            XCTAssertEqual(error as? ClosedLidError, .authorizationCancelled)
        }
        XCTAssertThrowsError(try service.uninstallSupport()) { error in
            XCTAssertEqual(error as? ClosedLidError, .authorizationCancelled)
        }
        XCTAssertThrowsError(try service.restoreSleepDisabledWithAdministratorPrivileges()) { error in
            XCTAssertEqual(error as? ClosedLidError, .authorizationCancelled)
        }
    }

    /// Regression test: script failures used to be wrapped twice, producing messages like
    /// "Failed to install Closed-Lid support: Failed to install Closed-Lid support: …".
    func testAdministratorScriptFailuresAreDescribedOnce() {
        let runner = RecordingAdministratorRunner()
        runner.error = .failed("The operation failed.")
        let (service, _) = makeService(runner: runner)

        XCTAssertThrowsError(try service.installSupport()) { error in
            XCTAssertEqual(error.localizedDescription, "Failed to install Closed-Lid support: The operation failed.")
        }
        XCTAssertThrowsError(try service.uninstallSupport()) { error in
            XCTAssertEqual(error.localizedDescription, "Failed to remove Closed-Lid support: The operation failed.")
        }
    }

    func testUninstallRemovesOnlyTheRuleFile() throws {
        let runner = RecordingAdministratorRunner()
        let (service, sudoersPath) = makeService(runner: runner)

        try service.uninstallSupport()

        XCTAssertEqual(runner.commands, ["rm -f '\(sudoersPath)'"])
    }

    func testAdministratorRestoreRunsOnlyTheFixedPmsetCommand() throws {
        let runner = RecordingAdministratorRunner()
        let (service, _) = makeService(sleepDisabled: false, runner: runner)

        try service.restoreSleepDisabledWithAdministratorPrivileges()

        XCTAssertEqual(runner.commands, ["/usr/bin/pmset -a disablesleep 0"])
    }

    func testAdministratorRestoreFailsIfSleepIsStillDisabled() {
        let runner = RecordingAdministratorRunner()
        let (service, _) = makeService(sleepDisabled: true, runner: runner)

        XCTAssertThrowsError(try service.restoreSleepDisabledWithAdministratorPrivileges()) { error in
            XCTAssertEqual(error as? ClosedLidError, .restoreFailed("System sleep is still disabled."))
        }
    }
}
