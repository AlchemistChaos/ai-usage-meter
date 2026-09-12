import Foundation
import ServiceManagement

enum LaunchAtLoginBridge {
    private static let statusArgument = "--launch-at-login-status"
    private static let setArgument = "--set-launch-at-login"

    static var isEnabled: Bool {
        guard let rawValue = try? runBundledCommand([statusArgument]),
              let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let status = SMAppService.Status(rawValue: value) else {
            return SMAppService.mainApp.status == .enabled
        }
        return status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard bundleExecutableURL != nil else {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return
        }
        _ = try runBundledCommand([setArgument, enabled ? "true" : "false"])
    }

    /// Handles commands that must execute while Bundle.main still refers to the
    /// installed app. Returns an exit status when a bridge command was present.
    static func handleCommandLine() -> Int32? {
        let arguments = CommandLine.arguments
        if arguments.contains(MenuAgentLauncher.uninstallArgument) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                try MenuAgentLauncher.uninstallAgent()
                return 0
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                return 1
            }
        }
        if arguments.contains(statusArgument) {
            print(SMAppService.mainApp.status.rawValue)
            return 0
        }
        guard let index = arguments.firstIndex(of: setArgument),
              index + 1 < arguments.count else { return nil }
        do {
            if arguments[index + 1] == "true" {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return 0
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static var bundleExecutableURL: URL? {
        ProcessInfo.processInfo.environment[
            MenuAgentLauncher.bundleExecutableEnvironmentKey
        ].map { URL(fileURLWithPath: $0) }
    }

    private static func runBundledCommand(_ arguments: [String]) throws -> String {
        guard let executableURL = bundleExecutableURL else {
            throw BridgeError.missingBundleExecutable
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw BridgeError.commandFailed(message)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    enum BridgeError: LocalizedError {
        case commandFailed(String)
        case missingBundleExecutable

        var errorDescription: String? {
            switch self {
            case .commandFailed(let message):
                return message.isEmpty ? "Launch-at-login command failed" : message
            case .missingBundleExecutable:
                return "The installed AI Meter app could not be located"
            }
        }
    }
}
