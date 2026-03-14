import Foundation
import OrderedCollections

/// LRU cache for parsed sessions, capacity 20.
actor SessionCache {
    private var cache = OrderedDictionary<String, ParsedSession>()
    private let capacity: Int

    init(capacity: Int = 20) {
        self.capacity = capacity
    }

    func get(_ key: String) -> ParsedSession? {
        guard let value = cache[key] else { return nil }
        // Move to end (most recently used)
        cache.removeValue(forKey: key)
        cache[key] = value
        return value
    }

    func set(_ key: String, value: ParsedSession) {
        cache.removeValue(forKey: key)
        cache[key] = value

        // Evict oldest if over capacity
        while cache.count > capacity {
            cache.removeFirst()
        }
    }

    func invalidate(_ key: String) {
        cache.removeValue(forKey: key)
    }

    func clear() {
        cache.removeAll()
    }
}
