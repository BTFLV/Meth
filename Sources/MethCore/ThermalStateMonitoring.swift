import Foundation

public enum ThermalSeverity: Int, Comparable, Sendable, Equatable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalSeverity, rhs: ThermalSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(_ processThermalState: ProcessInfo.ThermalState) {
        switch processThermalState {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .nominal
        }
    }

    public var isOverheated: Bool {
        self >= .critical
    }
}

public protocol ThermalStateMonitoring: AnyObject, Sendable {
    var currentState: ThermalSeverity { get }
    var onThermalStateChange: (@Sendable (ThermalSeverity) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
}

