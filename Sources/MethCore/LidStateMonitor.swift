import Foundation
import IOKit
import IOKit.pwr_mgt
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "LidStateMonitor")

public final class LidStateMonitor: LidStateMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentState: LidState = .unknown
    private var notifyPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var notificationObject: io_object_t = 0
    private var rootDomainService: io_service_t = 0
    private var isMonitoring = false

    public var onLidStateChange: (@Sendable (LidState) -> Void)?

    public var currentState: LidState {
        lock.lock()
        defer { lock.unlock() }
        return _currentState
    }

    public init() {
        self._currentState = Self.queryCurrentLidState()
    }

    deinit {
        stopMonitoring()
    }

    public func startMonitoring() {
        lock.lock()
        guard !isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = true
        _currentState = Self.queryCurrentLidState()
        lock.unlock()

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("Failed to create IONotificationPort")
            return
        }
        self.notifyPort = port

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            self.runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            logger.error("Failed to find IOPMrootDomain service")
            return
        }
        self.rootDomainService = rootDomain

        let refCon = Unmanaged.passUnretained(self).toOpaque()

        let kr = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            { refCon, service, messageType, messageArgument in
                guard let refCon = refCon else { return }
                let monitor = Unmanaged<LidStateMonitor>.fromOpaque(refCon).takeUnretainedValue()
                monitor.handleInterestNotification(messageType: messageType, messageArgument: messageArgument)
            },
            refCon,
            &notificationObject
        )

        if kr != kIOReturnSuccess {
            logger.error("IOServiceAddInterestNotification failed: \(kr)")
        } else {
            logger.info("Successfully registered for lid state notifications")
        }
    }

    public func stopMonitoring() {
        lock.lock()
        guard isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = false

        if notificationObject != 0 {
            IOObjectRelease(notificationObject)
            notificationObject = 0
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }

        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }

        if rootDomainService != 0 {
            IOObjectRelease(rootDomainService)
            rootDomainService = 0
        }
        lock.unlock()
        logger.info("Stopped lid state monitoring")
    }

    // kIOPMMessageClamshellStateChange is defined in IOPM.h as iokit_family_msg(sub_iokit_powermanagement, 0x100) = 0xe0034100
    public static let kIOPMMessageClamshellStateChange: UInt32 = 0xe0034100

    private func handleInterestNotification(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        if messageType == Self.kIOPMMessageClamshellStateChange {
            let newState = Self.queryCurrentLidState()
            updateState(newState)
        }
    }

    private func updateState(_ newState: LidState) {
        lock.lock()
        guard _currentState != newState else {
            lock.unlock()
            return
        }
        _currentState = newState
        let callback = onLidStateChange
        lock.unlock()

        logger.info("Lid state changed to: \(newState.rawValue)")
        if let callback = callback {
            DispatchQueue.main.async {
                callback(newState)
            }
        }
    }

    public static func queryCurrentLidState() -> LidState {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return .unknown }
        defer { IOObjectRelease(rootDomain) }

        guard let prop = IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return .unknown
        }

        if let boolVal = prop as? Bool {
            return boolVal ? .closed : .open
        } else if let numVal = prop as? NSNumber {
            return numVal.boolValue ? .closed : .open
        }

        return .unknown
    }
}
