/// The first elements of a sequence in a given order, without sorting the rest.
enum TopK {
    /// The first `count` elements of `elements` ordered by `areInIncreasingOrder`, in that order. O(n log count): a heap
    /// keeps the `count` best seen so far, so a long tail costs one comparison per element.
    static func select<Element>(_ elements: some Sequence<Element>, count: Int,
                                by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        guard count > 0 else { return [] }
        // A max-heap in the given order: the root is the last of the kept elements, the first to give way.
        var heap: [Element] = []
        heap.reserveCapacity(Swift.min(count, 1_024))
        for element in elements {
            if heap.count < count {
                heap.append(element)
                siftUp(&heap, from: heap.count - 1, by: areInIncreasingOrder)
            } else if areInIncreasingOrder(element, heap[0]) {
                heap[0] = element
                siftDown(&heap, from: 0, by: areInIncreasingOrder)
            }
        }
        heap.sort(by: areInIncreasingOrder)
        return heap
    }

    /// Restores "no parent comes before its child" upwards from `index`.
    private static func siftUp<Element>(_ heap: inout [Element], from index: Int, by areInIncreasingOrder: (Element, Element) -> Bool) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard areInIncreasingOrder(heap[parent], heap[child]) else { return }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    /// Restores "no parent comes before its child" downwards from `index`.
    private static func siftDown<Element>(_ heap: inout [Element], from index: Int, by areInIncreasingOrder: (Element, Element) -> Bool) {
        var parent = index
        let count = heap.count
        while true {
            let left = 2 * parent + 1
            guard left < count else { return }
            var latest = left
            let right = left + 1
            if right < count, areInIncreasingOrder(heap[left], heap[right]) { latest = right }
            guard areInIncreasingOrder(heap[parent], heap[latest]) else { return }
            heap.swapAt(parent, latest)
            parent = latest
        }
    }
}
