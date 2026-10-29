import Foundation

/// An opaque, `Sendable` reference to a document the provider holds open.
///
/// The identifier comes from an injected ``HandleIDGenerating``, never from `UUID()`, so
/// a test sees `#1`, `#2`, `#3` and can assert on them.
public struct DocumentHandle: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public var description: String { "PDFDocument#\(rawValue)" }
}

/// A SHA-256 over a document's bytes, plus the byte count it was taken over.
///
/// The hex string is lowercase and 64 characters. This is the identity used by the
/// thumbnail cache and by the manifest field `originalPdfSha256` in spec 6.3.
public struct FileDigest: Sendable, Hashable, Codable, CustomStringConvertible {
    public let sha256: String
    public let byteCount: Int

    public init(sha256: String, byteCount: Int) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    public var description: String { "\(sha256.prefix(12))… (\(byteCount) bytes)" }
}

/// The `%PDF-x.y` version the file declares.
public struct PDFVersion: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: PDFVersion, rhs: PDFVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

/// Whether the document is encrypted, and whether we are past the encryption.
public enum EncryptionState: Sendable, Hashable, Codable {
    /// No `/Encrypt` dictionary.
    case none
    /// Encrypted and still locked: a password is required before content is available.
    case locked
    /// Encrypted, and a password has been accepted for this handle.
    case unlocked

    public var isEncrypted: Bool { self != .none }
    public var isLocked: Bool { self == .locked }
}

/// The permission bits the document's encryption dictionary declares.
///
/// These are advisory in every PDF reader ever written; Zenit PDF honours them in its UI
/// but never relies on them for security.
public struct DocumentPermissions: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let printing = DocumentPermissions(rawValue: 1 << 0)
    public static let highQualityPrinting = DocumentPermissions(rawValue: 1 << 1)
    public static let copying = DocumentPermissions(rawValue: 1 << 2)
    public static let contentAccessibility = DocumentPermissions(rawValue: 1 << 3)
    public static let documentChanges = DocumentPermissions(rawValue: 1 << 4)
    public static let documentAssembly = DocumentPermissions(rawValue: 1 << 5)
    public static let commenting = DocumentPermissions(rawValue: 1 << 6)
    public static let formFieldEntry = DocumentPermissions(rawValue: 1 << 7)

    /// Everything allowed, which is what an unencrypted document reports.
    public static let all: DocumentPermissions = [
        .printing, .highQualityPrinting, .copying, .contentAccessibility,
        .documentChanges, .documentAssembly, .commenting, .formFieldEntry
    ]
}

/// One reason a document is not certainly intact.
public enum IntegrityFinding: Sendable, Hashable, Codable, CustomStringConvertible {
    /// PDFKit and CoreGraphics disagree about how many pages there are, which means at
    /// least one of them repaired the page tree, and they did it differently.
    case pageCountDisagreement(pdfKit: Int, coreGraphics: Int)
    /// CoreGraphics refused the file outright while PDFKit accepted it.
    case coreGraphicsRefusedFile
    /// No `%%EOF` in the trailing window: the file is probably truncated, and any reader
    /// that opened it did so by rebuilding the cross-reference table.
    case missingEndOfFileMarker
    /// A page object exists but reports an empty or non-finite media box.
    case unusablePageBox(pageIndex: Int)
    /// The catalog could not be read even though pages could.
    case catalogUnreadable

    public var description: String {
        switch self {
        case let .pageCountDisagreement(a, b): return "page count disagreement: PDFKit \(a), CoreGraphics \(b)"
        case .coreGraphicsRefusedFile: return "CoreGraphics refused the file"
        case .missingEndOfFileMarker: return "no %%EOF marker"
        case let .unusablePageBox(index): return "page \(index) has an unusable box"
        case .catalogUnreadable: return "catalog unreadable"
        }
    }
}

/// How much the document can be trusted structurally.
///
/// A "damaged" PDF is not a binary. `hostile-truncated` cannot be opened at all and
/// throws; `hostile-cyclic-page-tree` and `hostile-missing-object` *do* open, because
/// every real-world reader repairs them — and that is exactly the case a takeoff app
/// must surface, because the repaired page tree may not be the one the estimator was
/// billed against. Spec 7.4: a malformed PDF may be opened read-only or repaired into a
/// copy; the original is never repaired in place.
public enum DocumentIntegrity: Sendable, Hashable, Codable {
    case intact
    case suspect([IntegrityFinding])

    public var findings: [IntegrityFinding] {
        if case let .suspect(findings) = self { return findings }
        return []
    }
}

/// Constructs in the file that a naive reader would act on, and this one never does.
///
/// Presence is reported; nothing here is ever executed, followed, resolved or extracted
/// (spec 7.4, and ``PDFBridgeSecurityPolicy``).
public struct DocumentHazards: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// A document-level `/Names /JavaScript` tree.
    public static let documentJavaScript = DocumentHazards(rawValue: 1 << 0)
    /// A catalog `/OpenAction`.
    public static let openAction = DocumentHazards(rawValue: 1 << 1)
    /// An `/OpenAction` or annotation action of subtype `/JavaScript`.
    public static let javaScriptAction = DocumentHazards(rawValue: 1 << 2)
    /// A `/Launch` action anywhere that was scanned.
    public static let launchAction = DocumentHazards(rawValue: 1 << 3)
    /// A `/Names /EmbeddedFiles` tree.
    public static let embeddedFiles = DocumentHazards(rawValue: 1 << 4)
    /// A `/URI` action.
    public static let externalURIAction = DocumentHazards(rawValue: 1 << 5)
    /// A `/GoToR` action, which names another file.
    public static let remoteGoToAction = DocumentHazards(rawValue: 1 << 6)
    /// An `/AcroForm` dictionary.
    public static let acroForm = DocumentHazards(rawValue: 1 << 7)
    /// An XFA form, which is a whole second document format inside the PDF.
    public static let xfaForm = DocumentHazards(rawValue: 1 << 8)
    /// A document-level additional-actions dictionary (`/AA`).
    public static let documentAdditionalActions = DocumentHazards(rawValue: 1 << 9)
    /// A digital signature: a `/Sig` field carrying a signature value, or a catalog `/Perms`
    /// (certification). Any full rewrite of the file invalidates it; an incremental update keeps
    /// the signed bytes intact. The app warns before a rewrite (nl-pdf bug 8).
    public static let signedDocument = DocumentHazards(rawValue: 1 << 10)
}

/// An embedded file, listed but never written out.
public struct EmbeddedFileEntry: Sendable, Hashable, Codable {
    public let name: String
    /// The declared uncompressed size, when the file states one. Declared, not verified.
    public let declaredByteCount: Int?
    public let mimeType: String?

    public init(name: String, declaredByteCount: Int?, mimeType: String?) {
        self.name = name
        self.declaredByteCount = declaredByteCount
        self.mimeType = mimeType
    }
}

/// The document information dictionary, as far as it is safe to trust it.
public struct DocumentAttributes: Sendable, Hashable, Codable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var creator: String?
    public var producer: String?
    public var keywords: [String]

    public init(
        title: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        creator: String? = nil,
        producer: String? = nil,
        keywords: [String] = []
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.creator = creator
        self.producer = producer
        self.keywords = keywords
    }

    public static let empty = DocumentAttributes()
}

/// Everything known about an open document without touching a single page's content.
public struct DocumentDescriptor: Sendable, Hashable {
    public let handle: DocumentHandle
    public let origin: DocumentOrigin
    public let digest: FileDigest
    public let pageCount: Int
    public let version: PDFVersion
    public let encryption: EncryptionState
    public let permissions: DocumentPermissions
    public let integrity: DocumentIntegrity
    /// Whether the file begins with a `/Linearized` parameter dictionary — "fast web
    /// view". Detected from the first object, not inferred.
    public let isLinearized: Bool
    public let hazards: DocumentHazards
    public let embeddedFiles: [EmbeddedFileEntry]
    public let attributes: DocumentAttributes

    public init(
        handle: DocumentHandle,
        origin: DocumentOrigin,
        digest: FileDigest,
        pageCount: Int,
        version: PDFVersion,
        encryption: EncryptionState,
        permissions: DocumentPermissions,
        integrity: DocumentIntegrity,
        isLinearized: Bool,
        hazards: DocumentHazards,
        embeddedFiles: [EmbeddedFileEntry],
        attributes: DocumentAttributes
    ) {
        self.handle = handle
        self.origin = origin
        self.digest = digest
        self.pageCount = pageCount
        self.version = version
        self.encryption = encryption
        self.permissions = permissions
        self.integrity = integrity
        self.isLinearized = isLinearized
        self.hazards = hazards
        self.embeddedFiles = embeddedFiles
        self.attributes = attributes
    }
}

/// The result of opening a document.
public struct OpenedDocument: Sendable, Hashable {
    public let descriptor: DocumentDescriptor
    public var handle: DocumentHandle { descriptor.handle }

    public init(descriptor: DocumentDescriptor) {
        self.descriptor = descriptor
    }
}
