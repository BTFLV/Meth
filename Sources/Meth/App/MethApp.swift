import AppKit
import Foundation
import MethCore

@main
enum MethMain {
    @MainActor
    static func main() {
        if let exitCode = handleCLIArgumentsIfPresent() {
            exit(exitCode)
        }

        let app = NSApplication.shared
        // `NSApplication.delegate` is a weak reference, so the delegate is kept alive by
        // this local binding for as long as `run()` does not return -- i.e. the whole
        // process lifetime.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func handleCLIArgumentsIfPresent() -> Int32? {
        let args = Array(CommandLine.arguments.dropFirst())
        // Ignore standard macOS launch arguments like -NSDocumentRevisionsDebugMode or -psn_...
        guard let first = args.first, !first.hasPrefix("-") else {
            if args.first == "--help" || args.first == "-h" {
                printCLIUsage()
                return 0
            }
            return nil
        }

        switch first.lowercased() {
        case "start", "stop", "toggle", "extend":
            var queryItems: [URLQueryItem] = []
            var idx = 1
            while idx < args.count {
                let flag = args[idx]
                if (flag == "--minutes" || flag == "-m"), idx + 1 < args.count {
                    queryItems.append(URLQueryItem(name: "minutes", value: args[idx + 1]))
                    idx += 2
                } else if (flag == "--seconds" || flag == "-s"), idx + 1 < args.count {
                    queryItems.append(URLQueryItem(name: "seconds", value: args[idx + 1]))
                    idx += 2
                } else if (flag == "--hours" || flag == "-H"), idx + 1 < args.count {
                    queryItems.append(URLQueryItem(name: "hours", value: args[idx + 1]))
                    idx += 2
                } else if (flag == "--until" || flag == "-u"), idx + 1 < args.count {
                    queryItems.append(URLQueryItem(name: "until", value: args[idx + 1]))
                    idx += 2
                } else if flag == "--closed-lid" {
                    queryItems.append(URLQueryItem(name: "closedLid", value: "true"))
                    idx += 1
                } else if flag == "--no-closed-lid" {
                    queryItems.append(URLQueryItem(name: "closedLid", value: "false"))
                    idx += 1
                } else if flag == "--no-display-sleep" {
                    queryItems.append(URLQueryItem(name: "displaySleep", value: "false"))
                    idx += 1
                } else if flag == "--allow-display-sleep" {
                    queryItems.append(URLQueryItem(name: "displaySleep", value: "true"))
                    idx += 1
                } else {
                    idx += 1
                }
            }
            var comps = URLComponents()
            comps.scheme = "meth"
            comps.host = first.lowercased()
            if !queryItems.isEmpty {
                comps.queryItems = queryItems
            }
            guard let url = comps.url else { return 1 }
            return NSWorkspace.shared.open(url) ? 0 : 1

        case "status":
            let service = ClosedLidPrivilegedService.shared
            let sleepDisabled = service.isSleepDisabled()
            let support = service.supportStatus() == .installed ? "installed" : "not-installed"
            print("sleep-disabled: \(sleepDisabled)")
            print("closed-lid-support: \(support)")
            return 0

        case "help":
            printCLIUsage()
            return 0

        default:
            return nil
        }
    }

    private static func printCLIUsage() {
        let usage = """
        Usage: Meth <command> [options]

        Commands:
          start    Start a keep-awake session
                   [--minutes <N>] [--hours <N>] [--until <HH:MM>]
                   [--closed-lid | --no-closed-lid]
                   [--allow-display-sleep | --no-display-sleep]
          stop     Stop the active session
          toggle   Toggle a keep-awake session on or off
          extend   Extend the active timed session [--minutes <N>]
          status   Print current system sleep and Closed-Lid support status
          help     Show this help message
        """
        print(usage)
    }
}
