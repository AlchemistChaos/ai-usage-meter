import Darwin
import Foundation

enum MenuAgentLauncher {
    static let markerArgument = "--menu-agent"
    static let uninstallArgument = "--uninstall-menu-agent"
    static let bundleExecutableEnvironmentKey = "AI_METER_BUNDLE_EXECUTABLE"
    static let showDashboardNotification = Notification.Name(
        "com.alchemistchaos.aimeter.show-dashboard")
    static let terminateForUpdateNotification = Notification.Name(
        "com.alchemistchaos.aimeter.terminate-for-update")
    static let terminateHostNotification = Notification.Name(
        "com.alchemistchaos.aimeter.terminate-host")

    static var shouldHostCurrentProcess: Bool {
        shouldRelay(
            bundleURL: Bundle.main.bundleURL,
            arguments: CommandLine.arguments)
    }

    static func shouldRelay(bundleURL: URL, arguments: [String]) -> Bool {
        bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
            && !arguments.contains(markerArgument)
    }

    static func helperURL(applicationSupportURL: URL) -> URL {
        applicationSupportURL
            .appendingPathComponent("AI Meter", isDirectory: true)
            .appendingPathComponent("Menu Agent", isDirectory: true)
            .appendingPathComponent("AIMeter", isDirectory: false)
    }

    static func bundledHelperURL(bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("AIMeterMenuAgent", isDirectory: false)
    }

    static func relayedArguments(_ arguments: [String]) -> [String] {
        Array(arguments.dropFirst()) + [markerArgument]
    }

    static func makeBundledAgentProcessIfNeeded() throws -> Process? {
        let arguments = CommandLine.arguments
        guard shouldRelay(bundleURL: Bundle.main.bundleURL, arguments: arguments) else {
            return nil
        }

        let bundleExecutable = try bundledExecutableURL()
        let source = bundledHelperURL(bundleURL: Bundle.main.bundleURL)
        let installed = try installHelper(from: source)
        guard installedAgentProcessID(helperURL: installed) == nil else { return nil }

        let process = Process()
        process.executableURL = installed
        process.arguments = relayedArguments(arguments)
        var environment = ProcessInfo.processInfo.environment
        environment[bundleExecutableEnvironmentKey] = bundleExecutable.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs the installed interaction test from an isolated raw copy so a test
    /// can never replace or terminate the steady-state menu agent.
    static func relaySelfTestIfBundled() -> Int32? {
        let arguments = CommandLine.arguments
        guard shouldRelay(bundleURL: Bundle.main.bundleURL, arguments: arguments) else {
            return nil
        }

        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "AI-Meter-SelfTest-\(UUID().uuidString)",
            isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: temporaryDirectory) }
            let source = bundledHelperURL(bundleURL: Bundle.main.bundleURL)
            let helper = temporaryDirectory.appendingPathComponent("AIMeter")
            try fileManager.copyItem(at: source, to: helper)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: helper.path)

            let process = Process()
            process.executableURL = helper
            process.arguments = relayedArguments(arguments)
            var environment = ProcessInfo.processInfo.environment
            environment[bundleExecutableEnvironmentKey] = try bundledExecutableURL().path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            fputs("AI Meter self-test launch failed: \(error)\n", stderr)
            return 1
        }
    }

    static func uninstallAgent() throws {
        let fileManager = FileManager.default
        let applicationSupport = try applicationSupportURL()
        let helper = helperURL(applicationSupportURL: applicationSupport)
        try terminateInstalledAgentIfRunning(at: helper)
        let root = helper
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }

    static func stopInstalledAgent() {
        guard let applicationSupport = try? applicationSupportURL() else { return }
        let helper = helperURL(applicationSupportURL: applicationSupport)
        try? terminateInstalledAgentIfRunning(at: helper)
    }

    private static func bundledExecutableURL() throws -> URL {
        guard let executableURL = Bundle.main.executableURL else {
            throw LauncherError.missingBundleExecutable
        }
        return executableURL
    }

    private static func applicationSupportURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LauncherError.missingApplicationSupport
        }
        return applicationSupport
    }

    private static func installHelper(from source: URL) throws -> URL {
        let fileManager = FileManager.default
        let applicationSupport = try applicationSupportURL()
        let destination = helperURL(applicationSupportURL: applicationSupport)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path),
           fileManager.contentsEqual(atPath: source.path, andPath: destination.path) {
            return destination
        }

        let staging = directory.appendingPathComponent(
            "AIMeter.new.\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: staging.path)
        guard fileManager.contentsEqual(atPath: source.path, andPath: staging.path) else {
            throw LauncherError.invalidStagedHelper
        }

        try terminateInstalledAgentIfRunning(at: destination)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    private static func terminateInstalledAgentIfRunning(at helper: URL) throws {
        DistributedNotificationCenter.default().postNotificationName(
            terminateForUpdateNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        guard let processID = installedAgentProcessID(helperURL: helper) else { return }

        for _ in 0..<20 {
            if Darwin.kill(processID, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if Darwin.kill(processID, SIGTERM) != 0, errno != ESRCH {
            throw LauncherError.couldNotTerminateExistingAgent
        }
        for _ in 0..<40 {
            if Darwin.kill(processID, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw LauncherError.couldNotTerminateExistingAgent
    }

    private static func installedAgentProcessID(helperURL: URL) -> pid_t? {
        let lockURL = helperURL
            .deletingLastPathComponent()
            .appendingPathComponent("instance.lock")
        guard let contents = try? String(contentsOf: lockURL, encoding: .utf8),
              let processID = pid_t(contents.trimmingCharacters(
                in: .whitespacesAndNewlines)),
              processID > 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        let runningExecutable = URL(fileURLWithPath: String(cString: buffer))
            .standardizedFileURL
        guard runningExecutable == helperURL.standardizedFileURL else { return nil }
        return processID
    }

    enum LauncherError: Error {
        case couldNotTerminateExistingAgent
        case invalidStagedHelper
        case missingApplicationSupport
        case missingBundleExecutable
    }
}

enum MenuAgentInstance {
    private static var lockDescriptor: Int32 = -1

    static var ownsLock: Bool { lockDescriptor >= 0 }

    static func acquire() -> Bool {
        guard lockDescriptor < 0 else { return true }
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fputs("AI Meter could not locate Application Support\n", stderr)
            return false
        }
        let helper = MenuAgentLauncher.helperURL(
            applicationSupportURL: applicationSupport)
        let directory = helper.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true)
        } catch {
            fputs("AI Meter could not create its lock directory: \(error)\n", stderr)
            return false
        }
        let lockURL = directory.appendingPathComponent("instance.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            fputs("AI Meter could not open its instance lock\n", stderr)
            return false
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            DistributedNotificationCenter.default().postNotificationName(
                MenuAgentLauncher.showDashboardNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true)
            return false
        }

        let processID = "\(getpid())\n"
        _ = ftruncate(descriptor, 0)
        _ = processID.withCString { pointer in
            Darwin.write(descriptor, pointer, strlen(pointer))
        }
        _ = fsync(descriptor)
        lockDescriptor = descriptor
        return true
    }
}
