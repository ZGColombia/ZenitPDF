import Foundation

/// The stated size budget site photographs are held to.
///
/// A `.zpdfproj` travels: it is mailed, synced, and opened on site over a phone's hotspot.
/// Photographs are the one attachment whose natural size is unbounded — a two-week snag walk
/// produces hundreds of 48-megapixel HEICs — so every import is normalised against the limits
/// below *before* it is stored, and an add that would blow the project's budget is refused
/// with the number in the refusal rather than quietly accepted. The limits are named
/// constants here and nowhere else; a test asserts ``standard`` still equals them, so the
/// stated budget cannot drift apart from the enforced one.
///
/// The instance properties exist so a test can exercise the refusal machinery against a
/// small budget without storing 64 MB of fixtures. Production code always uses ``standard``.
public struct PhotoBudget: Sendable, Hashable {

    // MARK: The stated limits

    /// Longest edge of a stored photograph, in pixels.
    ///
    /// 2048 px fills a 4K display at half width and prints a 17 cm strip at 300 dpi —
    /// enough to read a cable tag in a junction box, which is what site photos are for.
    /// Anything larger is camera resolution, not evidence resolution.
    public static let maximumLongestEdgePixels = 2048

    /// JPEG quality every stored photograph is re-encoded at.
    ///
    /// 0.8 is visually clean on photographic content and roughly a fifth of the bytes of
    /// quality 1.0. Re-encoding *always* happens — HEIC, PNG and TIFF sources included —
    /// so the stored form is one format, one quality, and a deterministic function of the
    /// source pixels, which is what lets the SHA-256 digest deduplicate a photo attached
    /// twice.
    public static let jpegCompressionQuality = 0.8

    /// Largest stored size of a single photograph, in bytes, measured after the downscale
    /// and re-encode.
    ///
    /// 2 MiB. A 2048-px JPEG at quality 0.8 lands well under this on photographic content;
    /// only pathological high-entropy input reaches it, and such an image is refused rather
    /// than stored, because the budget is a promise about the project file, not a hope.
    public static let maximumStoredBytesPerPhoto = 2 * 1024 * 1024

    /// Soft cap on the total bytes of photograph blobs one project stores.
    ///
    /// 64 MiB — at typical stored sizes, several hundred photographs. Past it, adds are
    /// refused with a ``PhotoImportRefusal/projectPhotoBudgetExceeded(storedBytes:incomingBytes:limit:)``
    /// that carries the numbers, so the person is told the budget rather than watching
    /// saves get slower. Attaching an already-stored photograph to another markup costs
    /// zero new bytes and is never refused by this cap.
    public static let maximumProjectPhotoBytes = 64 * 1024 * 1024

    /// Largest source file accepted for import, refused before it is read into memory.
    public static let maximumSourceBytes = 128 * 1024 * 1024

    /// Largest declared pixel count accepted, refused before a decode is attempted.
    ///
    /// 16384 × 16384. A decode bomb that is measured after it is decoded has already won
    /// (the same rule `StampArtworkImporter` keeps), so the declared size from the image
    /// source's metadata is bounded first. This is a hostile-input bound, not a quality
    /// judgment — every camera this product will meet is far below it.
    public static let maximumSourcePixels = 16_384 * 16_384

    /// Largest declared pixel count accepted for a format ImageIO decodes in full.
    ///
    /// ImageIO subsamples JPEG and HEIC *during* decode, which is what lets a 268-megapixel
    /// photograph pass ``maximumSourcePixels`` without its bitmap ever existing. It does not do
    /// that for PNG, TIFF and the rest: a 16384 × 16384 flat-colour PNG is a few hundred
    /// kilobytes and allocated a ~1 GiB RGBA bitmap before the downscale — the decode bomb the
    /// bound exists to stop (BH-438). 40 megapixels (~160 MiB at four bytes a pixel) admits any
    /// screenshot or scan an estimator attaches.
    public static let maximumFullDecodeSourcePixels = 40_000_000

    // MARK: The budget in force

    /// Longest stored edge, in pixels. See ``maximumLongestEdgePixels``.
    public var longestEdgePixels: Int
    /// Stored JPEG quality. See ``jpegCompressionQuality``.
    public var compressionQuality: Double
    /// Per-photo stored-byte cap. See ``maximumStoredBytesPerPhoto``.
    public var bytesPerPhoto: Int
    /// Per-project stored-byte soft cap. See ``maximumProjectPhotoBytes``.
    public var bytesPerProject: Int
    /// Source-file byte bound. See ``maximumSourceBytes``.
    public var sourceBytes: Int
    /// Source pixel-count bound. See ``maximumSourcePixels``.
    public var sourcePixels: Int
    /// Source pixel-count bound for formats decoded in full. See ``maximumFullDecodeSourcePixels``.
    public var fullDecodeSourcePixels: Int

    public init(
        longestEdgePixels: Int,
        compressionQuality: Double,
        bytesPerPhoto: Int,
        bytesPerProject: Int,
        sourceBytes: Int = PhotoBudget.maximumSourceBytes,
        sourcePixels: Int = PhotoBudget.maximumSourcePixels,
        fullDecodeSourcePixels: Int = PhotoBudget.maximumFullDecodeSourcePixels
    ) {
        self.fullDecodeSourcePixels = fullDecodeSourcePixels
        self.longestEdgePixels = longestEdgePixels
        self.compressionQuality = compressionQuality
        self.bytesPerPhoto = bytesPerPhoto
        self.bytesPerProject = bytesPerProject
        self.sourceBytes = sourceBytes
        self.sourcePixels = sourcePixels
    }

    /// The product's budget: the named constants above, and nothing else.
    public static let standard = PhotoBudget(
        longestEdgePixels: maximumLongestEdgePixels,
        compressionQuality: jpegCompressionQuality,
        bytesPerPhoto: maximumStoredBytesPerPhoto,
        bytesPerProject: maximumProjectPhotoBytes
    )
}
