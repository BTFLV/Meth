import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionType: Sendable {
    case preventUserIdleSystemSleep
    case preventUserIdleDisplaySleep

    public var assertionName: CFString {
        switch self {
        case .preventUserIdleSystemSleep:
            return kIOPMAssertPreventUserIdleSystemSleep as CFString
        case .preventUserIdleDisplaySleep:
            return kIOPMAssertPreventUserIdleDisplaySleep as CFString
        }
    }
}

public typealias PowerAssertionID = IOPMAssertionID

public enum PowerAssertionError: Error, Equatable, LocalizedError {
    case creationFailed(IOReturn)
    case releaseFailed(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .creationFailed(let code):
            return "Failed to create IOKit power assertion (code: \(code))."
        case .releaseFailed(let code):
            return "Failed to release IOKit power assertion (code: \(code))."
        }
    }
}

public protocol PowerAssertionManaging: AnyObject, Sendable {
    func createAssertion(type: PowerAssertionType, name: String) throws -> PowerAssertionID
    func releaseAssertion(id: PowerAssertionID) -> Bool
}
