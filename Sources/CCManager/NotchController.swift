import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted when the notch should snap back to ambient immediately.
    static let ccmCollapse = Notification.Name("ccm.collapse")
}

/// Hosts the notch UI: a borderless, non-activating panel glued to the top
/// centre of the screen, drawn as a black extension of the hardware notch.
/// Collapsed it is a slim wing on each side of the notch; on hover it springs
/// open into the full dashboard. The panel is resized to match, so the
/// invisible parts never steal clicks from the menu bar.
@MainActor
final class NotchController {
    /// The hardware notch height — the ambient state matches it exactly.
    static var notchHeight: CGFloat {
        max(NSScreen.main?.safeAreaInsets.top ?? 32, 24)
    }
    static let expandedSize = CGSize(width: 470, height: 580)

    private let panel: NSPanel
    private let manager: AccountManager
    private var outsideClickMonitor: Any?
    private var state: NotchState = {
        switch ProcessInfo.processInfo.environment["CCM_NOTCH_STATE"] {
        case "full": return .full
        case "glance": return .glance
        default: return .ambient
        }
    }()

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
            onStateChange: { [weak self] state, height in
                self?.setState(state, height: height)
            })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.expandedSize)
        panel.contentView = hosting

        layout()
        panel.orderFrontRegardless()

        // Click anywhere outside the panel → collapse instantly. This is the
        // escape hatch users reach for when the dashboard feels in the way.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state != .ambient else { return }
                NotificationCenter.default.post(name: .ccmCollapse, object: nil)
            }
        }

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

    private var panelHeight: CGFloat = 0
    private var shrinkTask: Task<Void, Never>?

    private func setState(_ value: NotchState, height: CGFloat) {
        state = value
        panelHeight = height
        shrinkTask?.cancel()

        let target = targetSize()
        if target.height >= panel.frame.height {
            // Growing (or equal): give the animation room immediately.
            layout()
        } else {
            // Shrinking: wait for the collapse animation, then size to
            // whatever the state is *now* — never a stale capture.
            shrinkTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 460_000_000)
                guard !Task.isCancelled else { return }
                self.layout()
            }
        }
    }

    private func targetSize() -> CGSize {
        var size = state.size
        if size.height <= 0 { size.height = max(panelHeight, 200) }
        return size
    }

    private func layout() {
        guard let screen = NSScreen.main else { return }
        let size = targetSize()
        let frame = NSRect(
            x: screen.frame.midX - Self.expandedSize.width / 2,
            y: screen.frame.maxY - size.height,
            width: Self.expandedSize.width,
            height: size.height)
        panel.setFrame(frame, display: true)
    }
}
