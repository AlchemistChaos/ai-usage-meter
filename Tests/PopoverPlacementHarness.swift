import AppKit

@main
enum PopoverPlacementHarness {
    static func main() {
        let visibleFrame = NSRect(x: 61, y: 0, width: 1606, height: 1084)
        let statusButton = NSRect(x: 1009, y: 1084, width: 111, height: 33)

        let initial = PopoverPlacement.frame(
            windowSize: NSSize(width: 526, height: 372),
            below: statusButton,
            within: visibleFrame)
        assert(initial.maxY == statusButton.minY)

        let expanded = PopoverPlacement.frame(
            windowSize: NSSize(width: 526, height: 680),
            below: statusButton,
            within: visibleFrame)
        assert(expanded.maxY == statusButton.minY)
        assert(expanded.minY >= visibleFrame.minY)
        assert(expanded.minX >= visibleFrame.minX)
        assert(expanded.maxX <= visibleFrame.maxX)

        let rightEdgeButton = NSRect(x: 1640, y: 1084, width: 27, height: 33)
        let rightClamped = PopoverPlacement.frame(
            windowSize: NSSize(width: 526, height: 680),
            below: rightEdgeButton,
            within: visibleFrame)
        assert(rightClamped.maxX == visibleFrame.maxX)

        print("PASS: popover placement")
    }
}
