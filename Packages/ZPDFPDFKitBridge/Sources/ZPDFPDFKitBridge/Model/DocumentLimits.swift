import Foundation

/// Every bound this package enforces on hostile input, in one place.
///
/// A PDF is data written by someone else. Each field below is a ceiling that turns an
/// unbounded loop or allocation into a typed error, and every one of them is
/// configurable because a takeoff app opens 300 MB drawing sets that a text reader
/// never would (spec 7.4: "max page count/file size configurable").
public struct DocumentLimits: Sendable, Hashable {
    /// Largest file, in bytes, that will be opened. Default 2 GiB.
    public var maximumFileByteCount: Int
    /// Largest page count that will be opened. Default 20 000.
    public var maximumPageCount: Int
    /// Largest bitmap, in pixels, a single render may allocate. Default 64 megapixels,
    /// which is a 24 x 36 in ARCH-D sheet at roughly 300 dpi.
    public var maximumRenderPixels: Int
    /// Largest thumbnail edge, in pixels. Default 2048.
    public var maximumThumbnailEdge: Int
    /// Characters of a single page's text that will be extracted. Default 4 000 000.
    public var maximumPageCharacters: Int
    /// Characters of a search query. Default 1024.
    public var maximumQueryLength: Int
    /// Search hits returned before the search stops early. Default 10 000.
    public var maximumSearchHits: Int
    /// Character boxes returned by one call. Default 200 000.
    public var maximumCharacterBoxes: Int
    /// Nodes in an outline tree before traversal stops. Default 50 000.
    public var maximumOutlineNodes: Int
    /// Depth of an outline tree before traversal stops. Default 64.
    public var maximumOutlineDepth: Int
    /// Named destinations parsed out of the catalog. Default 50 000.
    public var maximumNamedDestinations: Int
    /// Page-label ranges parsed out of the catalog. Default 20 000.
    public var maximumPageLabelRanges: Int
    /// Annotations read from one page. Default 20 000.
    public var maximumAnnotationsPerPage: Int
    /// Operations in one page-operation batch. Default 4096.
    public var maximumPageOperations: Int
    /// Objects visited while scanning the catalog and annotations for hazards. Default
    /// 50 000. A cyclic name tree is a real PDF, so the scan is bounded, not trusting.
    public var maximumHazardScanNodes: Int
    /// Bytes of a PDF read while probing the header. Default 4096.
    public var headerProbeByteCount: Int
    /// Bytes of the tail read while probing for `%%EOF`. Default 4096.
    public var trailerProbeByteCount: Int

    public init(
        maximumFileByteCount: Int = 2 << 30,
        maximumPageCount: Int = 20_000,
        maximumRenderPixels: Int = 64_000_000,
        maximumThumbnailEdge: Int = 2048,
        maximumPageCharacters: Int = 4_000_000,
        maximumQueryLength: Int = 1024,
        maximumSearchHits: Int = 10_000,
        maximumCharacterBoxes: Int = 200_000,
        maximumOutlineNodes: Int = 50_000,
        maximumOutlineDepth: Int = 64,
        maximumNamedDestinations: Int = 50_000,
        maximumPageLabelRanges: Int = 20_000,
        maximumAnnotationsPerPage: Int = 20_000,
        maximumPageOperations: Int = 4096,
        maximumHazardScanNodes: Int = 50_000,
        headerProbeByteCount: Int = 4096,
        trailerProbeByteCount: Int = 4096
    ) {
        self.maximumFileByteCount = maximumFileByteCount
        self.maximumPageCount = maximumPageCount
        self.maximumRenderPixels = maximumRenderPixels
        self.maximumThumbnailEdge = maximumThumbnailEdge
        self.maximumPageCharacters = maximumPageCharacters
        self.maximumQueryLength = maximumQueryLength
        self.maximumSearchHits = maximumSearchHits
        self.maximumCharacterBoxes = maximumCharacterBoxes
        self.maximumOutlineNodes = maximumOutlineNodes
        self.maximumOutlineDepth = maximumOutlineDepth
        self.maximumNamedDestinations = maximumNamedDestinations
        self.maximumPageLabelRanges = maximumPageLabelRanges
        self.maximumAnnotationsPerPage = maximumAnnotationsPerPage
        self.maximumPageOperations = maximumPageOperations
        self.maximumHazardScanNodes = maximumHazardScanNodes
        self.headerProbeByteCount = headerProbeByteCount
        self.trailerProbeByteCount = trailerProbeByteCount
    }

    /// The shipping defaults.
    public static let standard = DocumentLimits()
}

/// The security posture of this package, stated as data so it can be asserted in a test
/// instead of being a promise in a comment (spec 7.4).
///
/// None of these flags is settable. They exist because "we never run PDF JavaScript" is
/// a claim, and a claim that no test can read is a claim nobody can check. The
/// corresponding *behaviour* is structural: this package exposes no API that performs a
/// PDF action, and it never constructs a `PDFView`, which is the only PDFKit object that
/// performs actions on the user's behalf.
public struct PDFBridgeSecurityPolicy: Sendable, Hashable {
    /// Document-level and annotation-level `/JavaScript` is reported and never executed.
    public let executesDocumentJavaScript: Bool = false
    /// `/Launch` actions are reported and never followed.
    public let followsLaunchActions: Bool = false
    /// `/EmbeddedFiles` are listed by name and size and never written to disk.
    public let extractsEmbeddedFilesAutomatically: Bool = false
    /// `/URI` and `/GoToR` actions are reported and never resolved.
    public let resolvesExternalReferences: Bool = false
    /// `/OpenAction` is reported and never performed.
    public let performsOpenAction: Bool = false
    /// No API in this package writes to a document that is open for reading.
    public let mutatesSourceDocuments: Bool = false

    public init() {}

    public static let current = PDFBridgeSecurityPolicy()
}
