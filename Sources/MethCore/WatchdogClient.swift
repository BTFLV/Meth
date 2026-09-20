import Foundation
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "WatchdogClient")

public final class WatchdogClient: @unchecked Sendable {
    private let lock = NSLock()
    private var watchdogProcess: Process?

    public init() {}

    deinit {
        stop()
    }

    public func start(timeoutSeconds: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }

        // Stop any existing watchdog
        stopInternal()

        guard let watchdogURL = locateWatchdogBinary() else {
            logger.warning("Could not find MethWatchdog binary. Running without standalone watchdog process.")
            return
        }

        let process = Process()
        process.executableURL = watchdogURL
        var args = ["--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)"]
        if let timeout = timeoutSeconds, timeout > 0 {
            args.append(contentsOf: ["--timeout-seconds", "\(timeout)"])
        }
        process.arguments = args

        // Detach I/O so watchdog doesn't hold open pipes
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            self.watchdogProcess = process
            logger.info("Spawned MethWatchdog (PID: \(process.processIdentifier)) with args: \(args)")
        } catch {
            logger.error("Failed to spawn MethWatchdog: \(error.localizedDescription)")
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopInternal()
    }

    private func stopInternal() {
        guard let process = watchdogProcess, process.isRunning else {
            watchdogProcess = nil
            return
        }

        process.terminate()
        logger.info("Terminated watchdog process (PID: \(process.processIdentifier))")
        watchdogProcess = nil
    }

    private func locateWatchdogBinary() -> URL? {
        let fm = FileManager.default

        // 1. Inside App Bundle Contents/MacOS/MethWatchdog
        if let execURL = Bundle.main.executableURL {
            let candidate = execURL.deletingLastPathComponent().appendingPathComponent("MethWatchdog")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // 2. In bundle resources
        if let resURL = Bundle.main.resourceURL {
            let candidate = resURL.appendingPathComponent("MethWatchdog")
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // 3. Current working directory or build products directory
        let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/MethWatchdog")
        if fm.isExecutableFile(atPath: cwdCandidate.path) {
            return cwdCandidate
        }

        let releaseCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/release/MethWatchdog")
        if fm.isExecutableFile(atPath: releaseCandidate.path) {
            return releaseCandidate
        }

        return nil
    }
}

