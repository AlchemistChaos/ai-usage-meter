import Foundation

private final class FakeStatusItem: StatusItemRepresenting {
    var isVisible: Bool
    var isAttached: Bool

    init(isVisible: Bool = true, isAttached: Bool = true) {
        self.isVisible = isVisible
        self.isAttached = isAttached
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum StatusItemLifecycleHarness {
    static func main() {
        var creationCount = 0
        let lifecycle = StatusItemLifecycle<FakeStatusItem> {
            creationCount += 1
            return FakeStatusItem()
        }

        let first = lifecycle.ensureItem()
        expect(first.created, "the first ensure should create the item")
        expect(creationCount == 1, "the item should be created exactly once")

        let reused = lifecycle.ensureItem()
        expect(!reused.created, "an attached item should be reused")
        expect(reused.item === first.item, "recovery must not duplicate the gauge")

        first.item.isVisible = false
        let restored = lifecycle.ensureItem()
        expect(!restored.created, "an invisible attached item should be restored")
        expect(restored.item.isVisible, "recovery should make the item visible")
        expect(creationCount == 1, "visibility recovery should not create an item")

        first.item.isAttached = false
        let replacement = lifecycle.ensureItem()
        expect(replacement.created, "a detached item should be replaced")
        expect(replacement.item !== first.item, "replacement should be a new item")
        expect(creationCount == 2, "detachment should create one replacement")

        let final = lifecycle.ensureItem()
        expect(!final.created, "the replacement should be stable")
        expect(final.item === replacement.item, "repeated recovery should stay idempotent")
        expect(creationCount == 2, "repeated recovery must not duplicate the gauge")

        print("PASS: status item lifecycle")
    }
}
