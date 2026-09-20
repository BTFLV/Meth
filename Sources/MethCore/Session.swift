import Foundation

public struct Session: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let duration: SessionDuration
    public let allowDisplaySleep: Bool
    public let closedLidMode: Bool

    public init(
        id: UUID = UUID(),
        startDate: Date = Date(),
        duration: SessionDuration,
        allowDisplaySleep: Bool = true,
        closedLidMode: Bool = false
    ) {
        self.id = id
        self.startDate = startDate
        self.duration = duration
        self.allowDisplaySleep = allowDisplaySleep
        self.closedLidMode = closedLidMode
    }

    public var endDate: Date? {
        duration.targetEndDate(startingFrom: startDate)
    }

    public func remainingTime(relativeTo date: Date = Date()) -> TimeInterval? {
        guard let target = endDate else { return nil }
        return max(0, target.timeIntervalSince(date))
    }

    public func isExpired(relativeTo date: Date = Date()) -> Bool {
        guard let target = endDate else { return false }
        return date >= target
    }

    /// Extends a timed session by the specified number of seconds.
    public func extending(by seconds: TimeInterval, relativeTo now: Date = Date()) -> Session {
        guard seconds > 0 else { return self }
        switch duration {
        case .indefinite:
            return self
        case .preset(let current):
            // If already expired, extend from now; otherwise add to remaining
            let remaining = max(0, (startDate.addingTimeInterval(current)).timeIntervalSince(now))
            let newDuration = remaining + seconds
            return Session(
                id: id,
                startDate: now,
                duration: .preset(newDuration),
                allowDisplaySleep: allowDisplaySleep,
                closedLidMode: closedLidMode
            )
        case .until(let targetDate):
            let newTarget = max(now, targetDate).addingTimeInterval(seconds)
            return Session(
                id: id,
                startDate: startDate,
                duration: .until(newTarget),
                allowDisplaySleep: allowDisplaySleep,
                closedLidMode: closedLidMode
            )
        }
    }
}

