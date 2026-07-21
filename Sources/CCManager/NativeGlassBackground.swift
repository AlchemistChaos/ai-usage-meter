import AppKit
import SwiftUI

/// Native blur for the menu panel. It is decorative only: returning nil from
/// hitTest prevents the glass layer from stealing clicks or hover events from
/// the SwiftUI controls above it.
private final class NonInteractiveGlassView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureHostWindow()
    }

    func configureHostWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.isOpaque = false
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

struct NativeGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NonInteractiveGlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        (view as? NonInteractiveGlassView)?.configureHostWindow()
    }
}
