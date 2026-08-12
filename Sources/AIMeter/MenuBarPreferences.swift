struct MenuBarSelection: Equatable {
    var showsClaudeFiveHour: Bool
    var showsClaudeWeekly: Bool
    var showsClaudeFable: Bool
    var showsCodexWeekly: Bool

    static let standard = MenuBarSelection(
        showsClaudeFiveHour: true,
        showsClaudeWeekly: false,
        showsClaudeFable: false,
        showsCodexWeekly: true)
}

enum MenuBarPreferenceKey {
    static let claudeFiveHour = "menuBar.showsClaudeFiveHour"
    static let claudeWeekly = "menuBar.showsClaudeWeekly"
    static let claudeFable = "menuBar.showsClaudeFable"
    static let codexWeekly = "menuBar.showsCodexWeekly"
}
