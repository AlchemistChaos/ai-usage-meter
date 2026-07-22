import AppKit
import Combine
import SwiftUI

extension NSStatusItem: StatusItemRepresenting {
    var isAttached: Bool { statusBar != nil }
}

@MainActor
final class StatusItemController: NSObject {
    private let manager: AccountManager
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var preferencesObserver: NSObjectProtocol?
    private lazy var lifecycle = StatusItemLifecycle<NSStatusItem> {
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        item.autosaveName = "com.alchemistchaos.aimeter.status-item"
        return item
    }

    init(manager: AccountManager) {
        self.manager = manager
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuView(manager: manager))

        manager.$accounts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
    }

    deinit {
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    func ensureStatusItem() {
        updateStatusItem()
    }

    private func updateStatusItem() {
        let result = lifecycle.ensureItem()
        if result.created {
            configure(result.item)
        }
        updateStatusItem(result.item)
    }

    private func configure(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        let image = NSImage(
            systemSymbolName: "gauge.medium",
            accessibilityDescription: "AI Meter")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
    }

    private func updateStatusItem(_ item: NSStatusItem) {
        guard let button = item.button else { return }
        let selection = MenuBarSelection(
            showsClaudeFiveHour: preference(
                MenuBarPreferenceKey.claudeFiveHour,
                fallback: MenuBarSelection.standard.showsClaudeFiveHour),
            showsClaudeWeekly: preference(
                MenuBarPreferenceKey.claudeWeekly,
                fallback: MenuBarSelection.standard.showsClaudeWeekly),
            showsCodexWeekly: preference(
                MenuBarPreferenceKey.codexWeekly,
                fallback: MenuBarSelection.standard.showsCodexWeekly))
        let label = AccountPresentation.menuLabel(
            for: manager.accounts,
            selection: selection)
        button.title = label.map { " \($0)" } ?? ""
        button.toolTip = label.map { "AI Meter · \($0)" } ?? "AI Meter"
    }

    private func preference(_ key: String, fallback: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return fallback
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(
            relativeTo: sender.bounds,
            of: sender,
            preferredEdge: .minY)
    }
}
