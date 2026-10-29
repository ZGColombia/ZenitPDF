import Foundation

/// The narrow slice of `UserDefaults` that UI packages persist small preference blobs through.
///
/// Every UI package that remembers something between launches — the window layout, the ledger's
/// saved column layouts, how far the first-run guide got — needs the same two operations and the
/// same reason to abstract them: a test that writes the user's real preferences is a test that
/// changes the user's machine. The seam lives here so each package does not invent its own.
///
/// The methods are deliberately not called `data(forKey:)`, because `UserDefaults` already has a
/// method by that name with a different meaning to the compiler's overload resolution.
public protocol ZPDFDefaultsStoring: AnyObject {

    /// Reads a stored blob, or `nil` when the key has never been written.
    func persistedData(forKey key: String) -> Data?

    /// Writes a blob, or removes the key when `data` is `nil`.
    func setPersistedData(_ data: Data?, forKey key: String)
}

extension ZPDFDefaultsStoring {

    /// Decodes a `Codable` value stored under a key, or `nil` when nothing readable is there.
    ///
    /// A blob that fails to decode is treated as absent rather than as an error: a preference
    /// written by an older build must never stop the app from opening.
    public func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = persistedData(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Encodes a `Codable` value under a key.
    ///
    /// - Returns: `true` when the value was written. A value that cannot be encoded is dropped
    ///   rather than trapping, because losing a preference is never worth crashing over.
    @discardableResult
    public func encode<Value: Encodable>(_ value: Value, forKey key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        setPersistedData(data, forKey: key)
        return true
    }
}

extension UserDefaults: ZPDFDefaultsStoring {

    public func persistedData(forKey key: String) -> Data? { data(forKey: key) }

    public func setPersistedData(_ data: Data?, forKey key: String) {
        if let data {
            set(data, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }
}

/// An in-memory defaults store, used by tests and by previews.
public final class ZPDFInMemoryDefaults: ZPDFDefaultsStoring {

    private var storage: [String: Data] = [:]

    /// Creates an empty store.
    public init() {}

    public func persistedData(forKey key: String) -> Data? { storage[key] }

    public func setPersistedData(_ data: Data?, forKey key: String) {
        if let data {
            storage[key] = data
        } else {
            storage.removeValue(forKey: key)
        }
    }

    /// Whether anything has been written. Useful for asserting a save actually happened.
    public var isEmpty: Bool { storage.isEmpty }
}
