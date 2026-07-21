import SwiftUI

@main
struct AIMeterApp: App {
    @StateObject private var manager = AccountManager.shared

    init() {
        // `AIMeter --diagnose` prints what the app can actually read and exits.
        // Useful for confirming credential detection without opening the UI.
        if CommandLine.arguments.contains("--diagnose") {
            Diagnostics.run()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"),
           i + 1 < CommandLine.arguments.count {
            Diagnostics.selfTest(name: CommandLine.arguments[i + 1])
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(manager: manager)
        } label: {
            Image(systemName: "gauge.medium")
            if let label = AccountPresentation.menuLabel(for: manager.accounts) {
                Text(label).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
