import Foundation

/// Storage abstraction so persistence can be swapped out (e.g. for tests).
public protocol CohorlyStorage: Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

/// Default storage backed by `UserDefaults.standard`.
public final class UserDefaultsStorage: CohorlyStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// In-memory storage, useful for unit tests where persistence across
/// relaunches doesn't need to be verified against real `UserDefaults`.
public final class InMemoryStorage: CohorlyStorage, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key]
    }

    public func setString(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        store[key] = value
    }
}
