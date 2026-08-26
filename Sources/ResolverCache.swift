import Foundation

/// Caches resolved addresses so a connection does not pay a resolver round trip.
///
/// macOS serializes `getaddrinfo` through mDNSResponder, so a burst of
/// connections queues up behind each other even when every answer is already in
/// the system cache. In upstream mode the cost is pure waste: every connection
/// re-resolves the same corporate proxy hostname.
final class ResolverCache: @unchecked Sendable {
    private static let ttl: TimeInterval = 60
    private static let limit = 256

    static let shared = ResolverCache()

    private struct Entry {
        let addresses: [ResolvedAddress]
        let expiry: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func addresses(for key: String) -> [ResolvedAddress]? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else {
            return nil
        }

        guard entry.expiry > Date() else {
            entries.removeValue(forKey: key)
            return nil
        }

        return entry.addresses
    }

    func store(_ addresses: [ResolvedAddress], for key: String) {
        guard !addresses.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        // Bounded so a long-lived daemon cannot accumulate every host ever
        // visited. Wholesale eviction is fine at this size.
        if entries.count >= Self.limit {
            entries.removeAll(keepingCapacity: true)
        }

        entries[key] = Entry(addresses: addresses, expiry: Date().addingTimeInterval(Self.ttl))
    }

    func invalidate(_ key: String) {
        lock.lock()
        entries.removeValue(forKey: key)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
