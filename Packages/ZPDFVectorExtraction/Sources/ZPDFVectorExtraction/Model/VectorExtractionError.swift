import Foundation

/// Every way extraction can fail outright.
///
/// A PDF is hostile data. Everything that can go wrong with one is a typed value here,
/// so a caller can distinguish "this file is broken" from "this page has no vectors",
/// which is a normal outcome and not an error at all.
public enum VectorExtractionError: Error, Sendable, Hashable {
    /// CoreGraphics could not open the file as a PDF.
    case documentUnreadable(fileName: String)
    /// The document is encrypted and no usable password was supplied.
    case documentEncrypted(fileName: String)
    /// The document opened but reports no pages, or a broken page tree.
    case documentHasNoPages(fileName: String)
    /// `pageIndex` is outside `0..<pageCount`.
    case pageIndexOutOfRange(index: Int, pageCount: Int)
    /// The page exists but CoreGraphics would not produce a content stream for it.
    case contentStreamUnavailable(pageIndex: Int)
    /// The file could not be read from disk.
    case fileUnreadable(fileName: String, reason: String)
    /// `Task.isCancelled` became true during extraction.
    case cancelled
    /// A serialised extraction could not be decoded.
    case cacheDecodingFailed(reason: String)
    /// An option was outside its documented range.
    case invalidOption(name: String, reason: String)
}

extension VectorExtractionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .documentUnreadable(let name):
            return "PDF could not be opened: \(name)"
        case .documentEncrypted(let name):
            return "PDF is encrypted and locked: \(name)"
        case .documentHasNoPages(let name):
            return "PDF reports no pages: \(name)"
        case .pageIndexOutOfRange(let index, let count):
            return "page index \(index) is outside 0..<\(count)"
        case .contentStreamUnavailable(let index):
            return "page \(index) has no readable content stream"
        case .fileUnreadable(let name, let reason):
            return "file could not be read: \(name) (\(reason))"
        case .cancelled:
            return "extraction was cancelled"
        case .cacheDecodingFailed(let reason):
            return "cached extraction could not be decoded: \(reason)"
        case .invalidOption(let name, let reason):
            return "invalid option \(name): \(reason)"
        }
    }
}
