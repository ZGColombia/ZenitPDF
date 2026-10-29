import Foundation
import ZPDFUIPresentation

/// Everything that can go wrong in Zenit that a person has to be told about.
///
/// The kind is the *situation*, not the mechanism. `documentUnreadable` covers a truncated
/// download, a zero-byte file and a corrupt cross-reference table alike, because the person
/// holding the mouse does the same three things in all three cases. Mechanism detail belongs in
/// ``ZPDFUserFacingError/technicalDetail``, which is never the primary message.
public enum ZPDFErrorKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    /// The PDF cannot be parsed: truncated, damaged, or not a PDF at all.
    case documentUnreadable
    /// The PDF is encrypted and needs a password before it can be opened.
    case documentEncrypted
    /// A password was supplied and the document rejected it.
    case documentPasswordRejected
    /// The document opened but forbids the operation the user asked for.
    case documentPermissionsRestricted
    /// Vector Snap was asked for on a page that carries no vector geometry.
    case noVectorContentForSnap
    /// A measurement was attempted on a page with no scale and no Scale Region.
    case scaleMissing
    /// The page's scale was calibrated against a different revision of the drawing.
    case scaleStale
    /// Two quantities cannot be combined because their dimensions differ.
    case incompatibleUnits
    /// The chosen export destination cannot be written to.
    case exportPathNotWritable
    /// The export destination does not have room for the file.
    case exportInsufficientSpace
    /// A previous session ended unexpectedly and recovered work is waiting.
    case projectRecoveryAvailable
    /// An imported tool set failed the import-safety review.
    case toolSetImportRejected
    /// A chosen tool set file is bigger than a tool set is allowed to be, so it was not read.
    /// The limit travels as the secondary subject (IM-146).
    case toolSetFileTooLarge
    /// A chosen file could not be read as a tool set at all (IM-146).
    case toolSetFileUnreadable
    /// A picture that travelled with an imported tool could not be kept; the tool was added
    /// without it (IM-146, BH-320).
    case toolSetPictureNotKept
    /// OCR could not run on the requested pages.
    case ocrUnavailable
    /// The search index is missing or out of date and has to be rebuilt.
    case searchIndexRebuildRequired
    /// Two revisions could not be brought into register well enough to be compared.
    case revisionAlignmentRejected

    /// Stable identity.
    public var id: String { rawValue }

    /// Whether this situation stops the person until they answer (a sheet), or lets them carry
    /// on working (an advisory card).
    ///
    /// A stated property of the situation, so it is testable without localized copy and the
    /// presenter can split blocking from advisory without building every error's full copy on
    /// every access (IM-228). The copy table reads it.
    public var isBlocking: Bool {
        switch self {
        case .documentUnreadable, .documentEncrypted, .documentPasswordRejected, .scaleMissing,
             .exportPathNotWritable, .exportInsufficientSpace, .toolSetImportRejected,
             .revisionAlignmentRejected:
            return true
        case .documentPermissionsRestricted, .noVectorContentForSnap, .scaleStale,
             .incompatibleUnits, .projectRecoveryAvailable, .toolSetFileTooLarge,
             .toolSetFileUnreadable, .toolSetPictureNotKept, .ocrUnavailable,
             .searchIndexRebuildRequired:
            return false
        }
    }
}

/// One failure, ready to be shown to a person.
///
/// The type deliberately carries no error code in its user-visible surface; the person reads
/// plain sentences.
public struct ZPDFUserFacingError: Error, Hashable, Sendable, Identifiable {

    /// Stable identity for the lifetime of the presentation.
    public let id: UUID
    /// What situation this is.
    public var kind: ZPDFErrorKind
    /// The thing the failure is about: a file name, a folder name, a unit name, a page label.
    /// Substituted into the copy when the copy has a place for it.
    public var subject: String?
    /// A second subject, used by the copy that compares two things (units, revisions).
    public var secondarySubject: String?
    /// Mechanism detail for a bug report. Never shown as the primary message, never spoken
    /// first by VoiceOver, and never the only thing on screen.
    public var technicalDetail: String?
    /// When it happened, so a recovery sheet can say how old the recovered work is.
    public var occurredAt: Date

    /// Creates a user-facing error.
    public init(
        id: UUID = UUID(),
        kind: ZPDFErrorKind,
        subject: String? = nil,
        secondarySubject: String? = nil,
        technicalDetail: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.secondarySubject = secondarySubject
        self.technicalDetail = technicalDetail
        self.occurredAt = occurredAt
    }
}
