import AppKit
import Combine
import SwiftUI

extension NSStatusItem: StatusItemRepresenting {
    var isAttached: Bool { statusBar != nil }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let manager: AccountManager
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var preferencesObserver: NSObjectProtocol?
    private var popoverResizeObserver: NSObjectProtocol?
    private weak var popoverAnchor: NSStatusBarButton?
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
        popover.delegate = self
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
        if let popoverResizeObserver {
            NotificationCenter.default.removeObserver(popoverResizeObserver)
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

    func runInteractionSelfTest(
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let item = updateStatusItem()
        guard let button = item.button else {
            print("FAIL: status item has no button")
            completion(false)
            return
        }
        guard button.target === self else {
            print("FAIL: status item button lost its target")
            completion(false)
            return
        }
        guard button.action == #selector(togglePopover(_:)) else {
            print("FAIL: status item button lost its action")
            completion(false)
            return
        }

        let normallyAnimates = popover.animates
        popover.animates = false
        togglePopover(button)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            let opened = self.popover.isShown
            let isOnscreen: Bool
            var placementDiagnostic = "popover window geometry unavailable"
            if let window = self.popover.contentViewController?.view.window,
               let screen = window.screen,
               let statusButtonFrame = self.statusButtonFrame(for: button) {
                placementDiagnostic = "window=\(window.frame) screen=\(screen.frame) status=\(statusButtonFrame)"
                isOnscreen = screen.frame.contains(window.frame)
                    && window.frame.maxY <= statusButtonFrame.minY + 1
            } else {
                isOnscreen = false
            }
            self.togglePopover(button)
            let closed = !self.popover.isShown
            self.popover.animates = normallyAnimates
            if !opened { print("FAIL: popover did not open") }
            if !isOnscreen {
                print("FAIL: popover opened outside its screen (\(placementDiagnostic))")
            }
            if !closed { print("FAIL: popover did not close") }
            completion(opened && isOnscreen && closed)
        }
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
        popoverAnchor = sender
        popover.show(
            relativeTo: sender.bounds,
            of: sender,
            preferredEdge: .maxY)
        observePopoverResize()
        schedulePopoverPlacement()
    }

    func popoverDidClose(_ notification: Notification) {
        stopObservingPopoverResize()
        popoverAnchor = nil
    }

    private func observePopoverResize() {
        stopObservingPopoverResize()
        guard let window = popover.contentViewController?.view.window else { return }
        popoverResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePopoverPlacement() }
        }
    }

    private func schedulePopoverPlacement() {
        keepPopoverOnscreen()
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.popover.isShown == true else { return }
                self?.keepPopoverOnscreen()
            }
        }
    }

    private func stopObservingPopoverResize() {
        if let popoverResizeObserver {
            NotificationCenter.default.removeObserver(popoverResizeObserver)
            self.popoverResizeObserver = nil
        }
    }

    private func keepPopoverOnscreen() {
        guard let anchor = popoverAnchor,
              let window = popover.contentViewController?.view.window,
              let statusButtonFrame = statusButtonFrame(for: anchor),
              let screen = anchor.window?.screen ?? window.screen else { return }
        let frame = PopoverPlacement.frame(
            windowSize: window.frame.size,
            below: statusButtonFrame,
            within: screen.visibleFrame)
        if window.frame.origin != frame.origin {
            window.setFrameOrigin(frame.origin)
        }
    }

    private func statusButtonFrame(for button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }
}
