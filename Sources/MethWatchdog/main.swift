import Foundation
import Darwin

/// MethWatchdog is an independent lightweight process designed to guarantee fail-safe restoration
/// of macOS system sleep settings if the main Meth application crashes or terminates unexpectedly.
///
/// Usage: MethWatchdog --parent-pid <PID> [--timeout-seconds <SECONDS>]

final class Watchdog {
    let parentPid: pid_t
    let timeoutSeconds: Int?

    init(parentPid: pid_t, timeoutSeconds: Int?) {
        self.parentPid = parentPid
        self.timeoutSeconds = timeoutSeconds
    }

    func run() {
        // First verify parent is alive
        if kill(parentPid, 0) != 0 {
            restoreSleepAndExit()
        }

        let kq = kqueue()
        guard kq >= 0 else {
            // Fallback: simple wait loop if kqueue fails
            fallbackWaitLoop()
            return
        }

        var changes: [kevent] = []

        // Register process exit filter
        let procEvent = kevent(
            ident: UInt(parentPid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        changes.append(procEvent)

        // If timeout specified, register timer filter (ident: 1, filter: EVFILT_TIMER)
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

        if result > 0 {
            // Either parent exited or timer expired
            restoreSleepAndExit()
        }
    }

    private func fallbackWaitLoop() {
        var elapsed = 0
        while true {
            sleep(2)
            elapsed += 2
            if kill(parentPid, 0) != 0 {
                restoreSleepAndExit()
            }
            if let timeout = timeoutSeconds, elapsed >= timeout {
                restoreSleepAndExit()
            }
        }
    }

    private func restoreSleepAndExit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]
        try? process.run()
        process.waitUntilExit()
        exit(0)
    }
}

// Parse command line arguments
var parentPid: pid_t?
var timeout: Int?

var idx = 1
while idx < CommandLine.arguments.count {
    let arg = CommandLine.arguments[idx]
    if arg == "--parent-pid", idx + 1 < CommandLine.arguments.count {
        parentPid = pid_t(CommandLine.arguments[idx + 1])
        idx += 2
    } else if arg == "--timeout-seconds", idx + 1 < CommandLine.arguments.count {
        timeout = Int(CommandLine.arguments[idx + 1])
        idx += 2
    } else {
        idx += 1
    }
}

guard let pid = parentPid, pid > 0 else {
    FileHandle.standardError.write(Data("Usage: MethWatchdog --parent-pid <PID> [--timeout-seconds <SEC>]\n".utf8))
    exit(1)
}

let watchdog = Watchdog(parentPid: pid, timeoutSeconds: timeout)
watchdog.run()
