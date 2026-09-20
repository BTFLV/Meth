import Foundation
import XCTest
@testable import MethCore

/// Exercises the generation-token bookkeeping directly, using a harmless real executable
/// (`/usr/bin/true`) in place of the real MethWatchdog binary so the test spawns a process
/// but never touches `pmset`/`sudo`.
final class WatchdogClientTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.meth.tests.\(UUID().uuidString)")!
    }

    func testStartPublishesAFreshGenerationPerSpawn() {
        let defaults = makeIsolatedDefaults()
        let client = WatchdogClient(sharedDefaults: defaults, binaryLocator: { URL(fileURLWithPath: "/usr/bin/true") })

        client.start(timeoutSeconds: 5)
        let first = defaults.string(forKey: ClosedLidSharedState.activeWatchdogGenerationKey)
        XCTAssertNotNil(first, "Starting a watchdog must publish a generation token.")

        client.start(timeoutSeconds: 10)
        let second = defaults.string(forKey: ClosedLidSharedState.activeWatchdogGenerationKey)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second, "Each new watchdog spawn must invalidate the previous generation.")

        client.stop()
    }

    func testStopClearsTheGeneration() {
        let defaults = makeIsolatedDefaults()
        let client = WatchdogClient(sharedDefaults: defaults, binaryLocator: { URL(fileURLWithPath: "/usr/bin/true") })

        client.start(timeoutSeconds: 5)
        XCTAssertNotNil(defaults.string(forKey: ClosedLidSharedState.activeWatchdogGenerationKey))

        client.stop()
        XCTAssertNil(
            defaults.string(forKey: ClosedLidSharedState.activeWatchdogGenerationKey),
            "Stopping must clear the generation so no stale watchdog can act on Meth's behalf."
        )
    }

    func testMissingBinaryNeverPublishesAGeneration() {
        let defaults = makeIsolatedDefaults()
        let client = WatchdogClient(sharedDefaults: defaults, binaryLocator: { nil })

        client.start(timeoutSeconds: 5)

        XCTAssertNil(defaults.string(forKey: ClosedLidSharedState.activeWatchdogGenerationKey))
    }
}
