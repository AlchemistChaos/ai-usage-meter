import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var showDashboardObserver: NSObjectProtocol?
    private var terminateForUpdateObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(manager: AccountManager.shared)
        statusItemController = controller
        controller.ensureStatusItem()

        showDashboardObserver = DistributedNotificationCenter.default().addObserver(
            forName: MenuAgentLauncher.showDashboardNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.statusItemController?.showPopover() }
        }
        terminateForUpdateObserver = DistributedNotificationCenter.default().addObserver(
            forName: MenuAgentLauncher.terminateForUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(recoverStatusItem(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recoverStatusItem(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        statusItemController?.ensureStatusItem()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusItemController?.ensureStatusItem()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let showDashboardObserver {
            DistributedNotificationCenter.default().removeObserver(
                showDashboardObserver)
        }
        if let terminateForUpdateObserver {
            DistributedNotificationCenter.default().removeObserver(
                terminateForUpdateObserver)
        }
        if MenuAgentInstance.ownsLock {
            DistributedNotificationCenter.default().postNotificationName(
                MenuAgentLauncher.terminateHostNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true)
        }
    }

    @objc private func recoverStatusItem(_ notification: Notification) {
        statusItemController?.ensureStatusItem()
    }
}

@MainActor
final class MenuAgentHostDelegate: NSObject, NSApplicationDelegate {
    private var agentProcess: Process?
    private var terminateObserver: NSObjectProtocol?
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempt = 0
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureAgent()
        terminateObserver = DistributedNotificationCenter.default().addObserver(
            forName: MenuAgentLauncher.terminateHostNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isTerminating = true
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        restartAttempt = 0
        ensureAgent(showDashboard: true)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        restartWorkItem?.cancel()
        agentProcess?.terminationHandler = nil
        if let terminateObserver {
            DistributedNotificationCenter.default().removeObserver(terminateObserver)
        }
        MenuAgentLauncher.stopInstalledAgent()
        agentProcess = nil
    }

    private func ensureAgent(showDashboard: Bool = false) {
        restartWorkItem?.cancel()
        restartWorkItem = nil

        if agentProcess?.isRunning == true {
            if showDashboard { postShowDashboard() }
            return
        }

        do {
            guard let process = try MenuAgentLauncher.makeBundledAgentProcessIfNeeded()
            else {
                if showDashboard { postShowDashboard() }
                return
            }
            process.terminationHandler = { [weak self] finished in
                Task { @MainActor in self?.agentDidTerminate(finished) }
            }
            agentProcess = process
            try process.run()

            if showDashboard {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.postShowDashboard()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak process] in
                guard let self, let process,
                      self.agentProcess === process,
                      process.isRunning else { return }
                self.restartAttempt = 0
            }
        } catch {
            agentProcess = nil
            fputs("AI Meter menu agent launch failed: \(error)\n", stderr)
            scheduleRestart()
        }
    }

    private func agentDidTerminate(_ process: Process) {
        guard agentProcess === process else { return }
        agentProcess = nil
        guard !isTerminating else { return }
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !isTerminating, restartAttempt < 3 else { return }
        let delays = [0.25, 1.0, 2.0]
        let delay = delays[restartAttempt]
        restartAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in self?.ensureAgent() }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func postShowDashboard() {
        DistributedNotificationCenter.default().postNotificationName(
            MenuAgentLauncher.showDashboardNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
    }
}

@main
enum AIMeterApp {
    @MainActor
    static func main() {
        if let status = LaunchAtLoginBridge.handleCommandLine() {
            exit(status)
        }
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--selftest"),
           index + 1 < CommandLine.arguments.count {
            Diagnostics.selfTest(name: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--status-item-selftest") {
            if let status = MenuAgentLauncher.relaySelfTestIfBundled() {
                if status != 0 { exit(status) }
                return
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let controller = StatusItemController(
                manager: AccountManager(startPolling: false),
                usesAutosaveName: false)
            controller.ensureStatusItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                controller.runInteractionSelfTest { passed in
                    if passed {
                        print("PASS: installed status item interaction")
                    } else {
                        print("FAIL: installed status item interaction")
                    }
                    application.terminate(nil)
                }
            }
            application.run()
            withExtendedLifetime(controller) {}
            return
        }

        if MenuAgentLauncher.shouldHostCurrentProcess {
            let application = NSApplication.shared
            let delegate = MenuAgentHostDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            application.run()
            withExtendedLifetime(delegate) {}
            return
        }
        guard MenuAgentInstance.acquire() else { return }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
