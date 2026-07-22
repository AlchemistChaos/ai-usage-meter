import AppKit

enum PopoverPlacement {
    static func frame(
        windowSize: NSSize,
        below statusButtonFrame: NSRect,
        within visibleFrame: NSRect
    ) -> NSRect {
        let centeredX = statusButtonFrame.midX - (windowSize.width / 2)
        let originX: CGFloat
        if windowSize.width >= visibleFrame.width {
            originX = visibleFrame.minX
        } else {
            originX = min(
                max(centeredX, visibleFrame.minX),
                visibleFrame.maxX - windowSize.width)
        }

        let top = min(statusButtonFrame.minY, visibleFrame.maxY)
        let originY = max(visibleFrame.minY, top - windowSize.height)
        return NSRect(
            origin: NSPoint(x: originX.rounded(), y: originY.rounded()),
            size: windowSize)
    }
}
