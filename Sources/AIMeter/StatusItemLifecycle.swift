protocol StatusItemRepresenting: AnyObject {
    var isVisible: Bool { get set }
    var isAttached: Bool { get }
}

final class StatusItemLifecycle<Item: StatusItemRepresenting> {
    private let makeItem: () -> Item
    private var item: Item?

    init(makeItem: @escaping () -> Item) {
        self.makeItem = makeItem
    }

    func ensureItem() -> (item: Item, created: Bool) {
        if let item, item.isAttached {
            item.isVisible = true
            return (item, false)
        }

        let item = makeItem()
        item.isVisible = true
        self.item = item
        return (item, true)
    }
}
