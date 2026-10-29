import CryptoKit
import Foundation

/// The identity of a page the package holds no `page` row for yet (K-03).
///
/// Page rows are written by the first save. Before it, every open used to mint a fresh random
/// id for each page, so two copies of a project that was never saved — a Finder copy, a copy on
/// a colleague's Mac that joins a Shared Review Folder — named the same sheet differently, and a
/// markup made in one landed on a page the other did not have. The document row is written at
/// create and travels with every copy, so an id derived from it and the page's index is the
/// same in all of them, and in every later open of each.
///
/// Name-based, RFC 9562 version 8: the first sixteen bytes of SHA-256 over a fixed namespace,
/// the document row id and the zero-based page index, with the version and variant bits set.
/// Once a save has written the page row, that stored id wins; this is only the fallback.
public enum StablePageIdentity {

    private static let namespace = "com.zenitgroup.zenitpdf.page.v1"

    /// The page id for `pageIndex` of the document row `documentId`.
    public static func pageID(documentId: String, pageIndex: Int) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(documentId.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(String(pageIndex).utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80   // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant 10xx
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
