import SwiftUI

@main
struct CCManagerApp: App {
    @StateObject private var manager = AccountManager()

    init() {
        // `CCManager --diagnose` prints what the app can actually read and exits.
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
            // Show the tightest remaining budget right in the menu bar.
            if let account = manager.recommended ?? manager.accounts.first(where: { $0.isActive }),
               let window = account.shortWindow ?? account.longWindow {
                Image(systemName: symbol(for: window.usedPercent))
                Text("\(Int(window.remainingPercent))%")
            } else {
                Image(systemName: "gauge.medium")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func symbol(for used: Double) -> String {
        switch used {
        case ..<40: return "gauge.high"
        case ..<75: return "gauge.medium"
        default: return "gauge.low"
        }
    }
}
