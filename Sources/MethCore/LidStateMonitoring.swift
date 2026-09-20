import Foundation

public enum LidState: String, Sendable, Equatable {
    case open
    case closed
    case unknown
}

public protocol LidStateMonitoring: AnyObject, Sendable {
    var currentState: LidState { get }
    var onLidStateChange: (@Sendable (LidState) -> Void)? { get set }
    func startMonitoring()
    func stopMonitoring()
}

