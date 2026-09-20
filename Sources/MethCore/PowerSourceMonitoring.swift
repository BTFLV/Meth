import Foundation

public struct PowerSourceState: Equatable, Sendable {
    public let hasExternalPower: Bool
    public let isCharging: Bool
    public let batteryLevel: Int?
    public let isLowBattery: Bool

    public init(
        hasExternalPower: Bool,
        isCharging: Bool,
        batteryLevel: Int?,
        isLowBattery: Bool
    ) {
        self.hasExternalPower = hasExternalPower
        self.isCharging = isCharging
        self.batteryLevel = batteryLevel
        self.isLowBattery = isLowBattery
    }

    public static let unknown = PowerSourceState(
        hasExternalPower: true,
        isCharging: false,
        batteryLevel: nil,
        isLowBattery: false
    )
}

public protocol PowerSourceMonitoring: AnyObject, Sendable {
    var currentState: PowerSourceState { get }
    var onPowerSourceChange: (@Sendable (PowerSourceState) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
}

