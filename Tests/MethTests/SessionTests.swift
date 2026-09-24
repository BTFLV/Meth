import Foundation
import XCTest
@testable import MethCore

final class SessionTests: XCTestCase {
    func testPresetDurationEndDate() {
        let start = Date(timeIntervalSince1970: 1000)
        let duration = SessionDuration.preset(3600)
        let end = duration.targetEndDate(startingFrom: start)
        XCTAssertEqual(end, Date(timeIntervalSince1970: 4600))
    }

    func testIndefiniteDurationEndDate() {
        let start = Date()
        let duration = SessionDuration.indefinite
        XCTAssertNil(duration.targetEndDate(startingFrom: start))
        XCTAssertTrue(duration.isIndefinite)
    }

    func testUntilDateCalculationFutureToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 20
        comps.hour = 10
        comps.minute = 0
        comps.second = 0
        let refDate = cal.date(from: comps)!

        let target = SessionDuration.nextDate(hour: 15, minute: 30, relativeTo: refDate, calendar: cal)

        let targetComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: target)
        XCTAssertEqual(targetComps.year, 2026)
        XCTAssertEqual(targetComps.month, 9)
        XCTAssertEqual(targetComps.day, 20)
        XCTAssertEqual(targetComps.hour, 15)
        XCTAssertEqual(targetComps.minute, 30)
    }

    func testUntilDateCalculationPastRollsOverToTomorrow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        var comps = DateComponents()
        comps.year = 2026
        comps.month = 9
        comps.day = 20
        comps.hour = 20
        comps.minute = 0
        comps.second = 0
        let refDate = cal.date(from: comps)!

        // Requested 08:00 (which has already passed today at 20:00)
        let target = SessionDuration.nextDate(hour: 8, minute: 0, relativeTo: refDate, calendar: cal)

        let targetComps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: target)
        XCTAssertEqual(targetComps.year, 2026)
        XCTAssertEqual(targetComps.month, 9)
        XCTAssertEqual(targetComps.day, 21) // Rolls over to tomorrow
        XCTAssertEqual(targetComps.hour, 8)
        XCTAssertEqual(targetComps.minute, 0)
    }

    func testSessionRemainingTimeAndExpiration() {
        let start = Date(timeIntervalSince1970: 1000)
        let session = Session(
            startDate: start,
            duration: .preset(600) // 10 minutes, ends at 1600
        )

        let midway = Date(timeIntervalSince1970: 1300)
        XCTAssertEqual(session.remainingTime(relativeTo: midway), 300)
        XCTAssertFalse(session.isExpired(relativeTo: midway))

        let afterEnd = Date(timeIntervalSince1970: 1700)
        XCTAssertEqual(session.remainingTime(relativeTo: afterEnd), 0)
        XCTAssertTrue(session.isExpired(relativeTo: afterEnd))
    }

    func testSessionExtension() {
        let start = Date(timeIntervalSince1970: 1000)
        let session = Session(
            startDate: start,
            duration: .preset(600) // 10 minutes -> ends at 1600
        )

        let checkPoint = Date(timeIntervalSince1970: 1200) // remaining: 400s
        let extended = session.extending(by: 900, relativeTo: checkPoint) // adds 15 min (900s) -> new remaining: 1300s

        XCTAssertEqual(extended.remainingTime(relativeTo: checkPoint), 1300)
    }

    func testFormatRemaining() {
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: 45), "00:45")
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: 125), "02:05")
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: 3665), "01:01:05")
    }

    /// The countdown rounds partial seconds up, so a 5-minute session starts at 05:00 and the
    /// final second reads 00:01 instead of 00:00.
    func testFormatRemainingRoundsPartialSecondsUp() {
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: 299.6), "05:00")
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: 0.2), "00:01")
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: 0), "00:00")
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: -3), "00:00")
        XCTAssertEqual(SessionDuration.formatRemaining(seconds: 3599.5), "01:00:00")
    }

    func testDescribeTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 22, minute: 0))!

        let laterToday = calendar.date(byAdding: .minute, value: 90, to: now)!
        let tomorrow = calendar.date(byAdding: .hour, value: 11, to: now)!
        let inTwoDays = calendar.date(byAdding: .day, value: 2, to: now)!

        XCTAssertTrue(SessionDuration.describeTime(laterToday, relativeTo: now, calendar: calendar, locale: locale).hasPrefix("today at "))
        XCTAssertTrue(SessionDuration.describeTime(tomorrow, relativeTo: now, calendar: calendar, locale: locale).hasPrefix("tomorrow at "))
        let later = SessionDuration.describeTime(inTwoDays, relativeTo: now, calendar: calendar, locale: locale)
        XCTAssertTrue(later.hasPrefix("Sep 26 at "), later)
    }
}
