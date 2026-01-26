import Foundation

/// A minimal, session-scoped LRU cache.
///
/// Thread-safe via internal lock; values are stored as-is.
final class EmbeddingLRUCache<Key: Hashable, Value>: @unchecked Sendable {
    final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?

        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    struct Stats {
        var hits: Int = 0
        var misses: Int = 0

        var hitRate: Float {
            let total = hits + misses
            guard total > 0 else { return 0 }
            return Float(hits) / Float(total)
        }
    }

    init(capacity: Int) {
        self.capacity = max(0, capacity)
        self.lock = NSLock()
        self.state = State()
    }

    var stats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return state.stats
    }

    func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let node = state.map[key] else {
            state.stats.misses += 1
            return nil
        }
        state.stats.hits += 1
        state.moveToFront(node)
        return node.value
    }

    func set(_ key: Key, _ value: Value) {
        lock.lock()
        defer { lock.unlock() }

        guard capacity > 0 else { return }

        if let node = state.map[key] {
            node.value = value
            state.moveToFront(node)
            return
        }

        let node = Node(key: key, value: value)
        state.map[key] = node
        state.insertAtFront(node)

        if state.map.count > capacity {
            if let tail = state.tail {
                state.remove(tail)
                state.map.removeValue(forKey: tail.key)
            }
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }

        state.map.removeAll(keepingCapacity: false)
        state.head = nil
        state.tail = nil
        state.stats = Stats()
    }

    // MARK: - Internals

    private struct State {
        var map: [Key: Node] = [:]
        var head: Node?
        var tail: Node?
        var stats: Stats = Stats()

        mutating func insertAtFront(_ node: Node) {
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
            if tail == nil {
                tail = node
            }
        }

        mutating func remove(_ node: Node) {
            let p = node.prev
            let n = node.next

            if let p {
                p.next = n
            } else {
                head = n
            }

            if let n {
                n.prev = p
            } else {
                tail = p
            }

            node.prev = nil
            node.next = nil
        }

        mutating func moveToFront(_ node: Node) {
            if head === node { return }
            remove(node)
            insertAtFront(node)
        }
    }

    private let capacity: Int
    private let lock: NSLock
    private var state: State
}
