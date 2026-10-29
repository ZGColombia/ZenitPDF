import Foundation

/// The page cache key: document SHA-256, page index, extractor version.
///
/// A fourth component is added because it is required for correctness: the fingerprint
/// of the options. Filtering thresholds and the page-space convention change the emitted
/// geometry, so an entry produced under one configuration must never be served under
/// another. The fingerprint is an FNV-1a hash of the option values — never Swift's
/// `Hasher`, which is randomly seeded per process and would make the key useless across
/// launches.
public struct VectorCacheKey: Sendable, Hashable, Codable {
    /// Lowercase hex SHA-256 of the whole document file.
    public let documentDigest: String
    public let pageIndex: Int
    public let extractorVersion: Int
    public let configurationFingerprint: UInt64

    public init(
        documentDigest: String,
        pageIndex: Int,
        extractorVersion: Int,
        configurationFingerprint: UInt64
    ) {
        self.documentDigest = documentDigest
        self.pageIndex = pageIndex
        self.extractorVersion = extractorVersion
        self.configurationFingerprint = configurationFingerprint
    }

    /// A stable, filesystem-safe name for an on-disk cache entry inside the project
    /// package. Deterministic and collision-resistant.
    public var storageName: String {
        let fingerprint = String(configurationFingerprint, radix: 16, uppercase: false)
        return "\(documentDigest)-p\(pageIndex)-v\(extractorVersion)-\(fingerprint).zvx"
    }
}
