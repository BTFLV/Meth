import Foundation
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "PowerAssertion")

public final class PowerAssertionManager: PowerAssertionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var activeAssertions: Set<PowerAssertionID> = []

    public init() {}

    deinit {
        releaseAll()
    }

    public func createAssertion(type: PowerAssertionType, name: String) throws -> PowerAssertionID {
        lock.lock()
        defer { lock.unlock() }

        var assertionID: PowerAssertionID = 0
        let cfName = name as CFString
        let result = IOPMAssertionCreateWithName(
            type.assertionName,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            cfName,
            &assertionID
        )

        guard result == kIOReturnSuccess else {
            logger.error("Failed to create assertion: \(result)")
            throw PowerAssertionError.creationFailed(result)
        }

        activeAssertions.insert(assertionID)
        logger.info("Created power assertion ID \(assertionID) for \(String(describing: type)) (\(name))")
        return assertionID
    }

    public func releaseAssertion(id: PowerAssertionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard activeAssertions.contains(id) else {
            return false
        }

        let result = IOPMAssertionRelease(id)
        activeAssertions.remove(id)

        if result == kIOReturnSuccess {
            logger.info("Released power assertion ID \(id)")
            return true
        } else {
            logger.error("Failed to release power assertion ID \(id): \(result)")
            return false
        }
    }

    public func releaseAll() {
        lock.lock()
        let assertionsToRelease = activeAssertions
        activeAssertions.removeAll()
        lock.unlock()

        for id in assertionsToRelease {
            let res = IOPMAssertionRelease(id)
            if res == kIOReturnSuccess {
                logger.info("Cleaned up power assertion ID \(id)")
            } else {
                logger.error("Error cleaning up power assertion ID \(id): \(res)")
            }
        }
    }
}

/// RAII wrapper for deterministic cleanup of a single assertion.
public final class AssertionToken: @unchecked Sendable {
    public let id: PowerAssertionID
    public let type: PowerAssertionType
    private weak var manager: (any PowerAssertionManaging)?
    private var isReleased = false
    private let lock = NSLock()

    public init(id: PowerAssertionID, type: PowerAssertionType, manager: any PowerAssertionManaging) {
        self.id = id
        self.type = type
        self.manager = manager
    }

    deinit {
        release()
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return }
        isReleased = true
        _ = manager?.releaseAssertion(id: id)
    }
}

