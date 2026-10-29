import Foundation

/// Everything `ZPDFTestingSupport` can fail with. No fixture path calls `fatalError`,
/// force-unwraps, or `try!`.
public enum FixtureError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The destination directory could not be created.
    case directoryUnavailable(path: String, reason: String)
    /// The fixture bytes could not be written to disk.
    case writeFailed(path: String, reason: String)
    /// A generated string could not be encoded, which would mean a non-Latin-1
    /// character reached a PDF literal.
    case encodingFailed(kind: FixtureKind, reason: String)
    /// Deflate compression of a fixture payload failed.
    case compressionFailed(kind: FixtureKind)
    /// CoreGraphics refused to create the encrypted PDF context.
    case encryptedContextUnavailable
    /// A generation invariant was violated. This is a bug in the generator, reported
    /// as a typed error rather than a trap so a test run reports rather than dies.
    case generationFailed(kind: FixtureKind, reason: String)

    public var description: String {
        switch self {
        case let .directoryUnavailable(path, reason):
            return "ZPDFTestingSupport: cannot use directory \(path): \(reason)"
        case let .writeFailed(path, reason):
            return "ZPDFTestingSupport: cannot write \(path): \(reason)"
        case let .encodingFailed(kind, reason):
            return "ZPDFTestingSupport: cannot encode fixture \(kind.rawValue): \(reason)"
        case let .compressionFailed(kind):
            return "ZPDFTestingSupport: deflate failed for fixture \(kind.rawValue)"
        case .encryptedContextUnavailable:
            return "ZPDFTestingSupport: CoreGraphics refused to create an encrypted PDF context"
        case let .generationFailed(kind, reason):
            return "ZPDFTestingSupport: cannot generate fixture \(kind.rawValue): \(reason)"
        }
    }
}
