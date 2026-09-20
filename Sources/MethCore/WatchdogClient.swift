import Foundation
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "WatchdogClient")

public final class WatchdogClient: @unchecked Sendable {
    private let lock = NSLock()
    private var watchdogProcess: Process?
    private let sharedDefaults: UserDefaults
    private let binaryLocator: @Sendable () -> URL?

    public init(
        sharedDefaults: UserDefaults = ClosedLidSharedState.defaults,
        binaryLocator: @escaping @Sendable () -> URL? = { WatchdogClient.locateWatchdogBinary() }
    ) {
        self.sharedDefaults = sharedDefaults
        self.binaryLocator = binaryLocator
    }

    deinit {
        stop()
    }

    public func start(timeoutSeconds: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }

        // Stop any existing watchdog
        stopInternal()

        guard let watchdogURL = binaryLocator() else {
            logger.warning("Could not find MethWatchdog binary. Running without standalone watchdog process.")
            sharedDefaults.removeObject(forKey: ClosedLidSharedState.activeWatchdogGenerationKey)
            return
        }

        // A fresh, unique token per spawn: lets the watchdog notice if it has been
        // superseded by a later activation/extension even if its own process (or an
        // orphaned subprocess it started) outlives the handoff to a replacement.
        let generation = UUID().uuidString

        let process = Process()
        process.executableURL = watchdogURL
        var args = ["--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)", "--generation", generation]
        if let timeout = timeoutSeconds, timeout > 0 {
            args.append(contentsOf: ["--timeout-seconds", "\(timeout)"])
        }
        process.arguments = args

        // Detach I/O so watchdog doesn't hold open pipes
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            // Published before the process is spawned, so the generation is guaranteed
            // visible by the time the watchdog itself starts checking it.
            sharedDefaults.set(generation, forKey: ClosedLidSharedState.activeWatchdogGenerationKey)
            try process.run()
            self.watchdogProcess = process
            logger.info("Spawned MethWatchdog (PID: \(process.processIdentifier), generation \(generation))")
        } catch {
            logger.error("Failed to spawn MethWatchdog: \(error.localizedDescription)")
            sharedDefaults.removeObject(forKey: ClosedLidSharedState.activeWatchdogGenerationKey)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        // No generation is authorized to act once we are deliberately stopping: the normal
        // deactivate path restores sleep itself rather than relying on the watchdog.
        sharedDefaults.removeObject(forKey: ClosedLidSharedState.activeWatchdogGenerationKey)
        stopInternal()
    }

    private func stopInternal() {
        guard let process = watchdogProcess, process.isRunning else {
            watchdogProcess = nil
            return
        }

        process.terminate()
        // Wait for the old watchdog to fully exit before returning, so a caller that is
        // about to start a replacement watchdog (e.g. session extension) can never overlap
        // with this one reacting to its own timeout at the same instant.
        process.waitUntilExit()
        logger.info("Terminated watchdog process (PID: \(process.processIdentifier))")
        watchdogProcess = nil
    }

    public static func locateWatchdogBinary() -> URL? {
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

