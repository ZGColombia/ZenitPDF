import Foundation
import ZPDFContracts

/// Identity of one photograph-to-markup attachment.
///
/// Its own type rather than a bare `UUID`, for the same reason every other identifier in
/// this product is: a `PhotoAttachmentID` cannot be handed to an API that wanted a
/// ``ZPDFContracts/MarkupID``. It lives in this package, not in the frozen contracts —
/// photographs are a sidecar and `MarkupRecord` is untouched by them.
public struct PhotoAttachmentID: ContractIdentifier {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// One photograph attached to one markup: the attribution, never the pixels.
///
/// The pixels live in the store's content-addressed blob, named by ``digest``. Two
/// attachments may share one digest — the same junction-box photo attached to the cable
/// markup and to the conduit markup stores the picture once — which is why the attachment
/// and the photograph are separate things with separate identities.
public struct PhotoAttachment: Sendable, Hashable, Codable, Identifiable {

    /// This attachment's own identity, stable across save and reopen.
    public let id: PhotoAttachmentID

    /// The markup the photograph is attached to.
    ///
    /// A reference into the takeoff, held here as a sidecar key. Nothing in the frozen
    /// `MarkupRecord` knows photographs exist.
    public let markupID: MarkupID

    /// Lowercase-hex SHA-256 of the **stored** JPEG bytes — the blob's name.
    public let digest: String

    /// When the photograph was taken, if known.
    ///
    /// Caller-supplied, or read from the source's EXIF `DateTimeOriginal` at import.
    /// EXIF capture times carry no timezone; they are read as UTC, which keeps the value
    /// deterministic across machines at the cost of being naive about where the site was.
    public var capturedAt: Date?

    /// The person's note about what the photograph shows.
    public var caption: String?

    /// Pixel width of the stored (downscaled) photograph.
    public let pixelWidth: Int

    /// Pixel height of the stored (downscaled) photograph.
    public let pixelHeight: Int

    /// Byte size of the stored JPEG blob.
    public let byteCount: Int

    public init(
        id: PhotoAttachmentID,
        markupID: MarkupID,
        digest: String,
        capturedAt: Date? = nil,
        caption: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        byteCount: Int
    ) {
        self.id = id
        self.markupID = markupID
        self.digest = digest
        self.capturedAt = capturedAt
        self.caption = caption
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }
}

/// Why a photograph import was refused, with the limit it hit.
///
/// The same rule as `ArtworkImportRefusal`: a refusal is a product surface, not a log
/// line. "This project stores 63.9 MB of photographs; the budget is 64 MB" is something
/// the person can act on. "Import failed" is not.
public enum PhotoImportRefusal: Error, Codable, Hashable, Sendable {

    /// The source file is larger than ``PhotoBudget/sourceBytes``.
    case sourceTooLarge(bytes: Int, limit: Int)
    /// The source declares more pixels than ``PhotoBudget/sourcePixels``, refused before
    /// a decode is attempted.
    case sourcePixelsTooLarge(pixels: Int, limit: Int)
    /// The bytes could not be read as an image at all.
    case unreadableImage
    /// The downscaled photograph could not be re-encoded as JPEG.
    case encodingFailed
    /// Even after the downscale and re-encode, the photograph is larger than
    /// ``PhotoBudget/bytesPerPhoto``. Refused, never stored.
    case photoTooLarge(bytes: Int, limit: Int)
    /// Storing this photograph would push the project past ``PhotoBudget/bytesPerProject``.
    /// Refused before anything touches the disk.
    case projectPhotoBudgetExceeded(storedBytes: Int, incomingBytes: Int, limit: Int)

    /// A sentence for the person, with the number in it.
    public var reason: String {
        switch self {
        case let .sourceTooLarge(bytes, limit):
            return "The file is \(bytes) bytes; the limit for an imported photograph is \(limit)."
        case let .sourcePixelsTooLarge(pixels, limit):
            return "The image declares \(pixels) pixels; the limit is \(limit)."
        case .unreadableImage:
            return "The file could not be read as an image."
        case .encodingFailed:
            return "The photograph could not be re-encoded for storage."
        case let .photoTooLarge(bytes, limit):
            return "Stored, this photograph would be \(bytes) bytes; the limit per photograph is \(limit)."
        case let .projectPhotoBudgetExceeded(storedBytes, incomingBytes, limit):
            return "This project stores \(storedBytes) bytes of photographs; adding \(incomingBytes) more "
                + "would pass the \(limit)-byte budget."
        }
    }
}

/// A failure of the store itself, as opposed to a refusal of an import.
public enum PhotoStoreFailure: Error, Hashable, Sendable {

    /// The manifest exists but cannot be decoded. Refused loudly: silently opening an
    /// empty store over an unreadable manifest would let the next write orphan every
    /// photograph the manifest named.
    case manifestUnreadable(path: String, detail: String)
    /// The manifest was written by a newer build than this one can read.
    case manifestVersionUnsupported(found: Int, supported: Int)
    /// No attachment with this identity exists in the store.
    case attachmentNotFound(PhotoAttachmentID)
    /// A digest that is not 64 lowercase hex characters. A manifest read off disk is
    /// input again; a hostile digest must never become a file path.
    case malformedDigest(String)
    /// The manifest names a blob the directory does not hold.
    case blobMissing(digest: String)
    /// The blob's bytes no longer hash to their own name.
    case blobCorrupted(digest: String)
}
