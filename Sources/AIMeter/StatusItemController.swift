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
            Task { @MainActor in _ = self?.updateStatusItem() }
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

    @discardableResult
    private func updateStatusItem() -> NSStatusItem {
        let result = lifecycle.ensureItem()
        if result.created {
            configure(result.item)
        }
        updateStatusItem(result.item)
        return result.item
    }

    func runInteractionSelfTest() -> Bool {
        let item = updateStatusItem()
        guard let button = item.button else {
            print("FAIL: status item has no button")
            return false
        }
        guard button.target === self else {
            print("FAIL: status item button lost its target")
            return false
        }
        guard button.action == #selector(togglePopover(_:)) else {
            print("FAIL: status item button lost its action")
            return false
        }

        let normallyAnimates = popover.animates
        popover.animates = false
        defer { popover.animates = normallyAnimates }
        togglePopover(button)
        let opened = popover.isShown
        let isOnscreen: Bool
        if let window = popover.contentViewController?.view.window,
           let screen = window.screen {
            isOnscreen = screen.frame.contains(window.frame)
        } else {
            isOnscreen = false
        }
        togglePopover(button)
        let closed = !popover.isShown
        if !opened { print("FAIL: popover did not open") }
        if !isOnscreen { print("FAIL: popover opened outside its screen") }
        if !closed { print("FAIL: popover did not close") }
        return opened && isOnscreen && closed
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
            preferredEdge: .maxY)
    }
}
