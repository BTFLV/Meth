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

    public static func formatRemaining(seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}

