import Foundation
import IOKit.ps
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "PowerSourceMonitor")

public final class PowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentState: PowerSourceState = .unknown
    private var runLoopSource: CFRunLoopSource?
    private var isMonitoring = false
    private let stateProvider: @Sendable () -> PowerSourceState

    public var onPowerSourceChange: (@Sendable (PowerSourceState) -> Void)?

    /// The cached value is only kept current by change notifications while monitoring.
    /// Otherwise it could be hours old (captured at launch or during an earlier session), so a
    /// fresh reading is taken instead: Closed-Lid activation checks the battery through this
    /// property *before* monitoring starts.
    public var currentState: PowerSourceState {
        lock.lock()
        defer { lock.unlock() }
        if !isMonitoring {
            _currentState = stateProvider()
        }
        return _currentState
    }

    /// - Parameter stateProvider: reads the current power source state; injectable for tests.
    public init(stateProvider: @escaping @Sendable () -> PowerSourceState = { PowerSourceMonitor.queryCurrentPowerState() }) {
        self.stateProvider = stateProvider
        self._currentState = stateProvider()
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
        _currentState = stateProvider()
        lock.unlock()

        let refCon = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ refCon in
            guard let refCon = refCon else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(refCon).takeUnretainedValue()
            monitor.handlePowerSourceNotification()
        }, refCon)?.takeRetainedValue() else {
            logger.error("Failed to create IOPSNotification run loop source")
            // Without notifications the cache would go stale; keep reading live instead.
            lock.lock()
            isMonitoring = false
            lock.unlock()
            return
        }

        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        logger.info("Started power source monitoring")
    }

    public func stopMonitoring() {
        lock.lock()
        guard isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = false

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        lock.unlock()
        logger.info("Stopped power source monitoring")
    }

    private func handlePowerSourceNotification() {
        let newState = stateProvider()
        lock.lock()
        guard _currentState != newState else {
            lock.unlock()
            return
        }
        _currentState = newState
        let callback = onPowerSourceChange
        lock.unlock()

        logger.info("Power source changed: AC=\(newState.hasExternalPower), charging=\(newState.isCharging), battery=\(String(describing: newState.batteryLevel))%")
        if let callback = callback {
            DispatchQueue.main.async {
                callback(newState)
            }
        }
    }

    public static func queryCurrentPowerState() -> PowerSourceState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }

        var hasExternalPower = false
        var isCharging = false
        var batteryLevel: Int?

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }

            if let powerSourceState = desc[kIOPSPowerSourceStateKey as String] as? String {
                if powerSourceState == (kIOPSACPowerValue as String) {
                    hasExternalPower = true
                }
            }

            if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                isCharging = charging
            }

            if let currentCapacity = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let maxCapacity = desc[kIOPSMaxCapacityKey as String] as? Int, maxCapacity > 0 {
                let percent = (currentCapacity * 100) / maxCapacity
                batteryLevel = percent
            }
        }

        let isLow = (batteryLevel ?? 100) <= PowerSourceState.lowBatteryThreshold && !hasExternalPower

        return PowerSourceState(
            hasExternalPower: hasExternalPower,
            isCharging: isCharging,
            batteryLevel: batteryLevel,
            isLowBattery: isLow
        )
    }
}

