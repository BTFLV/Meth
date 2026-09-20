import Foundation
import Darwin
import os.log
import MethCore

/// MethWatchdog is an independent lightweight process designed to guarantee fail-safe restoration
/// of macOS system sleep settings if the main Meth application crashes or terminates unexpectedly.
///
/// Usage: MethWatchdog --parent-pid <PID> [--timeout-seconds <SECONDS>]

private let logger = Logger(subsystem: "com.meth.watchdog", category: "Watchdog")

final class Watchdog {
    let parentPid: pid_t
    let timeoutSeconds: Int?
    let generation: String?
    private let privilegedService: ClosedLidPrivilegedManaging
    private let sharedDefaults: UserDefaults

    init(
        parentPid: pid_t,
        timeoutSeconds: Int?,
        generation: String?,
        privilegedService: ClosedLidPrivilegedManaging = ClosedLidPrivilegedService.shared,
        sharedDefaults: UserDefaults = ClosedLidSharedState.defaults
    ) {
        self.parentPid = parentPid
        self.timeoutSeconds = timeoutSeconds
        self.generation = generation
        self.privilegedService = privilegedService
        self.sharedDefaults = sharedDefaults
    }

    /// Returns the process exit code: 0 only if normal sleep behavior was restored (or was
    /// already restored), non-zero if every recovery attempt failed.
    func run() -> Int32 {
        // Parent already gone by the time we started: recover immediately.
        if kill(parentPid, 0) != 0 {
            return restoreSleepAndReport()
        }

        let kq = kqueue()
        guard kq >= 0 else {
            return fallbackWaitLoop()
        }

        var changes: [kevent] = []

        let procEvent = kevent(
            ident: UInt(parentPid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        changes.append(procEvent)

        if let timeout = timeoutSeconds, timeout > 0 {
            let timerEvent = kevent(
                ident: 1,
                filter: Int16(EVFILT_TIMER),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: 0,
                data: timeout * 1000, // milliseconds
                udata: nil
            )
            changes.append(timerEvent)
        }

        var event = kevent()
        let result = kevent(kq, &changes, Int32(changes.count), &event, 1, nil)
        close(kq)

        guard result > 0 else {
            // Should not normally happen (kevent only returns 0 on a zero timeout, which we
            // never pass); treat conservatively as "unknown, attempt recovery anyway".
            return restoreSleepAndReport()
        }

        return restoreSleepAndReport()
    }

    private func fallbackWaitLoop() -> Int32 {
        var elapsed = 0
        while true {
            sleep(2)
            elapsed += 2
            if kill(parentPid, 0) != 0 {
                return restoreSleepAndReport()
            }
            if let timeout = timeoutSeconds, elapsed >= timeout {
                return restoreSleepAndReport()
            }
        }
    }

    private func restoreSleepAndReport() -> Int32 {
        // If a later activation or session-extension has already published a new
        // generation, that one (or a normal deactivate) owns the current state now --
        // this watchdog (or an orphaned subprocess of an earlier instance of it) must not
        // touch SleepDisabled on its behalf.
        // The watchdog can sit blocked in `kevent` for hours, so the value it cached when
        // it launched may be arbitrarily stale. Force a re-read from the preferences
        // daemon before deciding whether a newer generation has superseded this one.
        sharedDefaults.synchronize()
        if let generation, sharedDefaults.string(forKey: ClosedLidSharedState.activeWatchdogGenerationKey) != generation {
            logger.notice("Superseded by a newer Closed-Lid generation; skipping restoration.")
            return 0
        }

        guard privilegedService.isSleepDisabled() else {
            // Already restored (e.g. the user stopped the session moments before the
            // parent exited); nothing to do, and nothing to log as a failure.
            privilegedService.clearOwnershipMarker()
            return 0
        }

        let succeeded = privilegedService.restoreSleepDisabledForFailsafe(maxAttempts: 5)
        if !succeeded {
            logger.fault("MethWatchdog could not restore normal sleep behavior after repeated attempts.")
        }
        return succeeded ? 0 : 1
    }
}

// Parse command line arguments
var parentPid: pid_t?
var timeout: Int?
var generation: String?

var idx = 1
while idx < CommandLine.arguments.count {
    let arg = CommandLine.arguments[idx]
    if arg == "--parent-pid", idx + 1 < CommandLine.arguments.count {
        parentPid = pid_t(CommandLine.arguments[idx + 1])
        idx += 2
    } else if arg == "--timeout-seconds", idx + 1 < CommandLine.arguments.count {
        timeout = Int(CommandLine.arguments[idx + 1])
        idx += 2
    } else if arg == "--generation", idx + 1 < CommandLine.arguments.count {
        generation = CommandLine.arguments[idx + 1]
        idx += 2
    } else {
        idx += 1
    }
}

guard let pid = parentPid, pid > 0 else {
    FileHandle.standardError.write(Data("Usage: MethWatchdog --parent-pid <PID> [--timeout-seconds <SEC>] [--generation <TOKEN>]\n".utf8))
    exit(1)
}

let watchdog = Watchdog(parentPid: pid, timeoutSeconds: timeout, generation: generation)
exit(watchdog.run())
