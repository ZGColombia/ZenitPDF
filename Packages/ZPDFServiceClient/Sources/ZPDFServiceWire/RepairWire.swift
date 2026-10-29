import Foundation

/// Names shared by the client and the repair service.
public enum ZPDFRepairServiceIdentity {
    public static let bundleIdentifier = "com.zenitgroup.zenitpdf.RepairService"
    public static let bundleName = "RepairService"
}

/// The allow-listed XPC interface of the repair service.
///
/// The input document arrives as an inherited read-only descriptor; the output is
/// written into a *writable* descriptor the app opened on a temp file inside its
/// own container. The service stages qpdf's output in its own container temp and
/// streams it into `output` only after qpdf finished cleanly, so the app-side file
/// is either empty or complete — the app then renames it into place atomically.
@objc public protocol ZPDFRepairXPCProtocol {
    /// `requestData` is a JSON-encoded ``RepairWireRequest``; the success reply is
    /// a JSON-encoded ``RepairWireReply``.
    func performOperation(
        _ requestData: Data,
        input: FileHandle,
        output: FileHandle?,
        reply: @escaping @Sendable (Data?, NSError?) -> Void
    )

    func cancelRequest(_ requestID: String)

    func ping(reply: @escaping @Sendable (Int) -> Void)
}

/// The structural operations the repair service performs.
public enum RepairWireOperation: String, Sendable, Codable, Hashable {
    /// Parse-and-report; no output descriptor needed.
    case inspect
    /// Rebuild into a structurally correct copy.
    case repair
    /// Write a decrypted copy using the user-authorised password.
    case decrypt
    /// Write a linearized copy.
    case linearize
    /// Write a flattened, compressed, sanitised and/or encrypted copy (NL-PDF-08, NL-PDF-09).
    /// The request's ``RepairWireRequest/transform`` says which.
    case transform
    /// Write a new document of the pages ``RepairWireRequest/pageIndices`` names, in that order,
    /// keeping their page labels and the document's layer definitions (NL-DOCS-08).
    case extractPages
    /// Write one new document per group of ``RepairWireRequest/pageGroups``, each kept as
    /// ``extractPages`` keeps it, from one parse of the input (Split into Sheets, NL-DOCS-08).
    /// The output is the documents one after another; ``RepairWireReply/partByteCounts`` says
    /// where each ends.
    case extractPageGroups
}

/// What a ``RepairWireOperation/transform`` does. Passwords travel app → service only, like
/// the open password.
public struct RepairWireTransform: Sendable, Codable, Hashable {
    public var flattensAnnotations: Bool
    public var compresses: Bool
    public var sanitizes: Bool
    public var linearizes: Bool
    /// `nil`: no encryption. Otherwise AES-256 with these passwords and permissions.
    public var protection: Protection?
    /// `nil`: every picture byte for byte. Otherwise pictures painted above 1.25 × this
    /// resolution are resampled to it, decoded and re-encoded with ImageIO inside the service
    /// (NL-PDF-08), and the copy is refused unless its linework matches the original's.
    public var pictureTargetDPI: Double?

    public struct Protection: Sendable, Codable, Hashable {
        public var openPassword: String
        public var permissionsPassword: String
        /// 0 none, 1 low resolution, 2 full.
        public var printing: Int
        public var allowsChanges: Bool
        public var allowsCopying: Bool
        public var allowsAnnotating: Bool

        public init(
            openPassword: String,
            permissionsPassword: String,
            printing: Int,
            allowsChanges: Bool,
            allowsCopying: Bool,
            allowsAnnotating: Bool
        ) {
            self.openPassword = openPassword
            self.permissionsPassword = permissionsPassword
            self.printing = printing
            self.allowsChanges = allowsChanges
            self.allowsCopying = allowsCopying
            self.allowsAnnotating = allowsAnnotating
        }
    }

    public init(
        flattensAnnotations: Bool = false,
        compresses: Bool = false,
        sanitizes: Bool = false,
        linearizes: Bool = false,
        protection: Protection? = nil,
        pictureTargetDPI: Double? = nil
    ) {
        self.flattensAnnotations = flattensAnnotations
        self.compresses = compresses
        self.sanitizes = sanitizes
        self.linearizes = linearizes
        self.protection = protection
        self.pictureTargetDPI = pictureTargetDPI
    }
}

/// What a transform removed or changed, for the report the person reads.
public struct RepairWireTransformSummary: Sendable, Codable, Hashable {
    public var flattenedAnnotationCount: Int
    public var removedJavaScript: Bool
    public var removedEmbeddedFiles: Bool
    public var removedActionCount: Int
    public var removedMetadata: Bool
    public var inputByteCount: Int64
    /// Pictures resampled to the target resolution (NL-PDF-08).
    public var downsampledImageCount: Int
    /// Pictures painted above the target; more than ``downsampledImageCount`` when some could
    /// not be decoded or would not shrink.
    public var offeredImageCount: Int

    public init(
        flattenedAnnotationCount: Int,
        removedJavaScript: Bool,
        removedEmbeddedFiles: Bool,
        removedActionCount: Int,
        removedMetadata: Bool,
        inputByteCount: Int64,
        downsampledImageCount: Int = 0,
        offeredImageCount: Int = 0
    ) {
        self.downsampledImageCount = downsampledImageCount
        self.offeredImageCount = offeredImageCount
        self.flattenedAnnotationCount = flattenedAnnotationCount
        self.removedJavaScript = removedJavaScript
        self.removedEmbeddedFiles = removedEmbeddedFiles
        self.removedActionCount = removedActionCount
        self.removedMetadata = removedMetadata
        self.inputByteCount = inputByteCount
    }
}

public struct RepairWireRequest: Sendable, Codable, Hashable {
    public var requestID: UUID
    public var operation: RepairWireOperation
    /// User-authorised password, or nil. Travels only app → service.
    public var password: String?
    /// Original file name, for error messages only.
    public var fileName: String
    /// Test hook, as in ``GeometryWireRequest/debugDelayMilliseconds``.
    public var debugDelayMilliseconds: Int
    /// The transform, for ``RepairWireOperation/transform``; `nil` for every other operation.
    public var transform: RepairWireTransform?
    /// Zero-based pages, in output order, for ``RepairWireOperation/extractPages``; `nil` for
    /// every other operation.
    public var pageIndices: [Int]?
    /// One group of zero-based pages per document, for
    /// ``RepairWireOperation/extractPageGroups``; `nil` for every other operation.
    public var pageGroups: [[Int]]?

    public init(
        requestID: UUID = UUID(),
        operation: RepairWireOperation,
        password: String? = nil,
        fileName: String = "document.pdf",
        debugDelayMilliseconds: Int = 0,
        transform: RepairWireTransform? = nil,
        pageIndices: [Int]? = nil,
        pageGroups: [[Int]]? = nil
    ) {
        self.pageGroups = pageGroups
        self.requestID = requestID
        self.operation = operation
        self.password = password
        self.fileName = fileName
        self.debugDelayMilliseconds = debugDelayMilliseconds
        self.transform = transform
        self.pageIndices = pageIndices
    }
}

/// What came back: qpdf's report, and for `inspect` the inventory summary.
public struct RepairWireReply: Sendable, Codable, Hashable {
    public var message: String
    public var warnings: [String]
    public var warningCount: Int
    public var pageCount: Int?
    public var isEncrypted: Bool?
    public var isDamaged: Bool?
    /// Bytes the service wrote into the output descriptor (0 for `inspect`).
    public var outputByteCount: Int64
    /// For a transform: what it removed or changed.
    public var transformSummary: RepairWireTransformSummary?
    /// For ``RepairWireOperation/extractPageGroups``: the byte count of each document in the
    /// output, in group order; they add up to ``outputByteCount``.
    public var partByteCounts: [Int64]?

    public init(
        message: String,
        warnings: [String],
        warningCount: Int,
        pageCount: Int? = nil,
        isEncrypted: Bool? = nil,
        isDamaged: Bool? = nil,
        outputByteCount: Int64 = 0,
        transformSummary: RepairWireTransformSummary? = nil,
        partByteCounts: [Int64]? = nil
    ) {
        self.partByteCounts = partByteCounts
        self.transformSummary = transformSummary
        self.message = message
        self.warnings = warnings
        self.warningCount = warningCount
        self.pageCount = pageCount
        self.isEncrypted = isEncrypted
        self.isDamaged = isDamaged
        self.outputByteCount = outputByteCount
    }
}
