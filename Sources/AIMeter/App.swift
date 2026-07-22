import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(manager: AccountManager.shared)
        statusItemController = controller
        controller.ensureStatusItem()

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
    }

    @objc private func recoverStatusItem(_ notification: Notification) {
        statusItemController?.ensureStatusItem()
    }
}

@main
enum AIMeterApp {
    @MainActor
    static func main() {
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
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let controller = StatusItemController(manager: AccountManager.shared)
            controller.ensureStatusItem()
            DispatchQueue.main.async {
                if controller.runInteractionSelfTest() {
                    print("PASS: installed status item interaction")
                } else {
                    print("FAIL: installed status item interaction")
                }
                application.terminate(nil)
            }
            application.run()
            withExtendedLifetime(controller) {}
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
