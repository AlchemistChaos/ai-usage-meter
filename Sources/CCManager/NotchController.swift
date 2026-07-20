import AppKit
import SwiftUI

/// Hosts the notch UI: a borderless, non-activating panel glued to the top
/// centre of the screen, drawn as a black extension of the hardware notch.
/// Collapsed it is a slim wing on each side of the notch; on hover it springs
/// open into the full dashboard. The panel is resized to match, so the
/// invisible parts never steal clicks from the menu bar.
@MainActor
final class NotchController {
    /// Collapsed, the panel matches the physical notch height so it disappears
    /// into it; the small extra width leaves room for two subtle status dots.
    static var collapsedHeight: CGFloat {
        max(NSScreen.main?.safeAreaInsets.top ?? 32, 24)
    }
    static let expandedSize = CGSize(width: 480, height: 400)
    static let wingWidth: CGFloat = 18

    private let panel: NSPanel
    private let manager: AccountManager
    private var expanded = false

    init(manager: AccountManager) {
        self.manager = manager

        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let root = NotchView(
            manager: manager,
            notchWidth: Self.notchWidth(),
            onExpandChange: { [weak self] expanded in
                self?.setExpanded(expanded)
            })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.expandedSize)
        panel.contentView = hosting

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }
    }

    /// The physical notch width, or a plausible stand-in on notchless Macs
    /// so the UI still reads as a "notch" pill.
    static func notchWidth() -> CGFloat {
        guard let screen = NSScreen.main else { return 180 }
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            let w = screen.frame.width - left - right
            if w > 40 { return w }
        }
        return 180
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let size: CGSize = expanded
            ? Self.expandedSize
            : CGSize(width: Self.notchWidth() + Self.wingWidth * 2,
                     height: Self.collapsedHeight)
        let frame = NSRect(
            x: screen.frame.midX - Self.expandedSize.width / 2,
            y: screen.frame.maxY - size.height,
            width: Self.expandedSize.width,
            height: size.height)
        panel.setFrame(frame, display: true)
    }
}
