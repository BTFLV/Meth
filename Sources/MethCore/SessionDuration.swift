import Foundation

public enum SessionDuration: Equatable, Hashable, Sendable {
    case indefinite
    case preset(TimeInterval)
    case until(Date)

    public static let fiveMinutes: TimeInterval = 5 * 60
    public static let fifteenMinutes: TimeInterval = 15 * 60
    public static let thirtyMinutes: TimeInterval = 30 * 60
    public static let oneHour: TimeInterval = 60 * 60
    public static let twoHours: TimeInterval = 2 * 60 * 60
    public static let fourHours: TimeInterval = 4 * 60 * 60
    public static let eightHours: TimeInterval = 8 * 60 * 60

    public var isIndefinite: Bool {
        if case .indefinite = self { return true }
        return false
    }

    public var timeInterval: TimeInterval? {
        switch self {
        case .indefinite:
            return nil
        case .preset(let interval):
            return interval
        case .until(let date):
            return max(0, date.timeIntervalSinceNow)
        }
    }

    public func targetEndDate(startingFrom startDate: Date) -> Date? {
        switch self {
        case .indefinite:
            return nil
        case .preset(let interval):
            return startDate.addingTimeInterval(interval)
        case .until(let date):
            return date
        }
    }

    /// Calculates the next occurrence of a given hour and minute relative to a reference date.
    /// If the time has already passed today, rolls over to tomorrow.
    public static func nextDate(hour: Int, minute: Int, relativeTo referenceDate: Date = Date(), calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: referenceDate)
        components.hour = hour
        components.minute = minute
        components.second = 0

        guard let candidate = calendar.date(from: components) else {
            return referenceDate.addingTimeInterval(3600)
        }

        if candidate <= referenceDate {
            return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86400)
        }

        return candidate
    }

    /// Formats a countdown as `MM:SS` or `HH:MM:SS`. Partial seconds round up, so a
    /// 5-minute session starts at 05:00 and its final second reads 00:01.
    public static func formatRemaining(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.up)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    /// Describes a point in time relative to `now` -- "today at 14:35", "tomorrow at 09:00",
    /// or "Sep 26 at 09:00" -- with the time and date in the user's locale.
    public static func describeTime(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let time = timeFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) {
            return "today at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.locale = locale
        dayFormatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(dayFormatter.string(from: date)) at \(time)"
    }
}
