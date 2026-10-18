import Foundation
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "ThermalStateMonitor")

public final class ThermalStateMonitor: ThermalStateMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentState: ThermalSeverity
    private var observer: NSObjectProtocol?
    private var isMonitoring = false
    private let stateProvider: @Sendable () -> ThermalSeverity

    public var onThermalStateChange: (@Sendable (ThermalSeverity) -> Void)?

    public var currentState: ThermalSeverity {
        lock.lock()
        defer { lock.unlock() }
        if !isMonitoring {
            _currentState = stateProvider()
        }
        return _currentState
    }

    public init(stateProvider: @escaping @Sendable () -> ThermalSeverity = { ThermalSeverity(ProcessInfo.processInfo.thermalState) }) {
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

        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleThermalNotification()
        }
        logger.info("Started thermal state monitoring")
    }

    public func stopMonitoring() {
        lock.lock()
        guard isMonitoring else {
            lock.unlock()
            return
        }
        isMonitoring = false
        let token = observer
        observer = nil
        lock.unlock()

        if let token {
            NotificationCenter.default.removeObserver(token)
        }
        logger.info("Stopped thermal state monitoring")
    }

    private func handleThermalNotification() {
        let newState = stateProvider()
        lock.lock()
        guard _currentState != newState else {
            lock.unlock()
            return
        }
        _currentState = newState
        let callback = onThermalStateChange
        lock.unlock()

        logger.info("Thermal state changed to: \(String(describing: newState))")
        if let callback {
            DispatchQueue.main.async {
                callback(newState)
            }
        }
    }
}

