import SwiftUI

@main
struct AIMeterApp: App {
    @StateObject private var manager = AccountManager.shared
    @AppStorage(MenuBarPreferenceKey.claudeFiveHour)
    private var showsClaudeFiveHour = MenuBarSelection.standard.showsClaudeFiveHour
    @AppStorage(MenuBarPreferenceKey.claudeWeekly)
    private var showsClaudeWeekly = MenuBarSelection.standard.showsClaudeWeekly
    @AppStorage(MenuBarPreferenceKey.codexWeekly)
    private var showsCodexWeekly = MenuBarSelection.standard.showsCodexWeekly

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
            if let label = AccountPresentation.menuLabel(
                for: manager.accounts,
                selection: MenuBarSelection(
                    showsClaudeFiveHour: showsClaudeFiveHour,
                    showsClaudeWeekly: showsClaudeWeekly,
                    showsCodexWeekly: showsCodexWeekly)
            ) {
                Text(label).monospacedDigit()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
