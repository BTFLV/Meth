import AppIntents
import Foundation
import os.log
import MethCore

private let logger = Logger(subsystem: "com.meth.app", category: "Automation")

// MARK: - App Intents (Shortcuts & Spotlight)

public enum MethPresetDurationAppEnum: String, AppEnum {
    case indefinite
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case eightHours

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        "Session Duration"
    }

    public static var caseDisplayRepresentations: [MethPresetDurationAppEnum: DisplayRepresentation] {
        [
            .indefinite: "Indefinitely",
            .fiveMinutes: "5 Minutes",
            .fifteenMinutes: "15 Minutes",
            .thirtyMinutes: "30 Minutes",
            .oneHour: "1 Hour",
            .twoHours: "2 Hours",
            .fourHours: "4 Hours",
            .eightHours: "8 Hours"
        ]
    }

    public var sessionDuration: SessionDuration {
        switch self {
        case .indefinite: return .indefinite
        case .fiveMinutes: return .preset(SessionDuration.fiveMinutes)
        case .fifteenMinutes: return .preset(SessionDuration.fifteenMinutes)
        case .thirtyMinutes: return .preset(SessionDuration.thirtyMinutes)
        case .oneHour: return .preset(SessionDuration.oneHour)
        case .twoHours: return .preset(SessionDuration.twoHours)
        case .fourHours: return .preset(SessionDuration.fourHours)
        case .eightHours: return .preset(SessionDuration.eightHours)
        }
    }
}

public struct StartMethSessionIntent: AppIntent {
    public static var title: LocalizedStringResource = "Start Keep-Awake Session"
    public static var description = IntentDescription("Starts a Meth keep-awake session with the chosen duration and options.")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Duration", default: .oneHour)
    public var duration: MethPresetDurationAppEnum

    @Parameter(title: "Closed-Lid Mode", default: false)
    public var closedLidMode: Bool

    @Parameter(title: "Allow Display Sleep", default: true)
    public var allowDisplaySleep: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SessionManager.shared.startSession(
            duration: duration.sessionDuration,
            allowDisplaySleep: allowDisplaySleep,
            closedLidMode: closedLidMode
        )
        return .result(dialog: "Meth session started.")
    }
}

public struct StopMethSessionIntent: AppIntent {
    public static var title: LocalizedStringResource = "Stop Keep-Awake Session"
    public static var description = IntentDescription("Stops the currently active Meth keep-awake session.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        await SessionManager.shared.stopSession()
        return .result(dialog: "Meth session stopped.")
    }
}

public struct ExtendMethSessionIntent: AppIntent {
    public static var title: LocalizedStringResource = "Extend Keep-Awake Session"
    public static var description = IntentDescription("Extends the active timed Meth session by the specified number of minutes.")
    public static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes", default: 15)
    public var minutes: Int

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let clampedMinutes = max(1, minutes)
        await SessionManager.shared.extendSession(by: TimeInterval(clampedMinutes * 60))
        return .result(dialog: "Extended Meth session by \(clampedMinutes) minutes.")
    }
}

public struct GetMethStatusIntent: AppIntent {
    public static var title: LocalizedStringResource = "Get Keep-Awake Status"
    public static var description = IntentDescription("Reports whether a Meth session is active and whether Closed-Lid Mode is enabled.")
    public static var openAppWhenRun: Bool = false

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let manager = SessionManager.shared
        guard let session = manager.activeSession else {
            let status = "Inactive"
            return .result(value: status, dialog: "No Meth session is currently active.")
        }
        let mode = session.closedLidMode ? "Closed-Lid Mode" : "Normal Mode"
        if let remaining = manager.remainingTime {
            let formatted = SessionDuration.formatRemaining(seconds: remaining)
            let summary = "Active (\(mode), \(formatted) remaining)"
            return .result(value: summary, dialog: "\(summary)")
        } else {
            let summary = "Active (\(mode), Indefinite)"
            return .result(value: summary, dialog: "\(summary)")
        }
    }
}

public struct MethShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMethSessionIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Keep my Mac awake with \(.applicationName)"
            ],
            shortTitle: "Start Session",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: StopMethSessionIntent(),
            phrases: [
                "Stop \(.applicationName)"
            ],
            shortTitle: "Stop Session",
            systemImageName: "Stop"
        )
    }
}

// MARK: - URL Scheme (`meth://`) & CLI Handler

/// Handles `meth://` automation URLs so users can control Meth from the command line
/// (`open "meth://start?minutes=60&closedLid=1"`), Raycast, Alfred, or shell scripts.
///
/// Supported commands:
/// - `meth://start` (optional query items: `minutes=<N>`, `seconds=<N>`, `until=HH:MM`,
///   `closedLid=1|0|true|false`, `displaySleep=1|0|true|false`)
/// - `meth://stop`
/// - `meth://toggle`
/// - `meth://extend?minutes=<N>` (default: 15)
@MainActor
public enum MethURLRouter {
    public static func handle(_ url: URL, sessionManager: SessionManager? = nil) {
        let sessionManager = sessionManager ?? SessionManager.shared
        guard url.scheme?.lowercased() == "meth" else { return }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            }
        )

        Task { @MainActor in
            do {
                switch action {
                case "start":
                    let duration = parseDuration(from: query)
                    let closedLid = parseBool(query["closedlid"] ?? query["closed-lid"])
                    let displaySleep = parseBool(query["displaysleep"] ?? query["display-sleep"])
                    if (closedLid ?? sessionManager.defaultClosedLidMode) && !sessionManager.hasAcknowledgedThermalWarning {
                        ThermalWarningWindowController.show(
                            onConfirm: {
                                sessionManager.hasAcknowledgedThermalWarning = true
                                Task { @MainActor in
                                    try? await sessionManager.startSession(
                                        duration: duration,
                                        allowDisplaySleep: displaySleep,
                                        closedLidMode: closedLid
                                    )
                                }
                            },
                            onCancel: {}
                        )
                    } else {
                        try await sessionManager.startSession(
                            duration: duration,
                            allowDisplaySleep: displaySleep,
                            closedLidMode: closedLid
                        )
                    }
                case "stop":
                    await sessionManager.stopSession()
                case "toggle":
                    if sessionManager.isSessionActive {
                        await sessionManager.stopSession()
                    } else {
                        let duration = parseDuration(from: query)
                        try await sessionManager.startSession(duration: duration)
                    }
                case "extend":
                    let minutes = Double(query["minutes"] ?? "") ?? 15
                    let seconds = Double(query["seconds"] ?? "") ?? (minutes * 60)
                    if seconds > 0 {
                        await sessionManager.extendSession(by: seconds)
                    }
                default:
                    logger.warning("Ignored unrecognized meth:// action: \(action)")
                }
            } catch {
                logger.error("Failed to execute meth:// URL action '\(action)': \(error.localizedDescription)")
            }
        }
    }

    public static func parseDuration(from query: [String: String]) -> SessionDuration {
        if let untilStr = query["until"] {
            let parts = untilStr.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) {
                return .until(SessionDuration.nextDate(hour: parts[0], minute: parts[1]))
            }
        }
        if let secondsStr = query["seconds"], let seconds = Double(secondsStr), seconds > 0 {
            return .preset(seconds)
        }
        if let minutesStr = query["minutes"], let minutes = Double(minutesStr), minutes > 0 {
            return .preset(minutes * 60)
        }
        if let hoursStr = query["hours"], let hours = Double(hoursStr), hours > 0 {
            return .preset(hours * 3600)
        }
        return .indefinite
    }

    public static func parseBool(_ value: String?) -> Bool? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}

