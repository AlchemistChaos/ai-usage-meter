struct MenuBarSelection: Equatable {
    var showsClaudeFiveHour: Bool
    var showsClaudeWeekly: Bool
    var showsCodexWeekly: Bool

    static let standard = MenuBarSelection(
        showsClaudeFiveHour: true,
        showsClaudeWeekly: false,
        showsCodexWeekly: true)
}

enum MenuBarPreferenceKey {
    static let claudeFiveHour = "menuBar.showsClaudeFiveHour"
    static let claudeWeekly = "menuBar.showsClaudeWeekly"
    static let codexWeekly = "menuBar.showsCodexWeekly"
}
