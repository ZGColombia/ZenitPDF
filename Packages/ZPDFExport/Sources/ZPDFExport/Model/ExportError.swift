import Foundation
import ZPDFXlsxWriter

/// Everything the export layer can refuse to do.
public enum ExportError: Error, Hashable, Sendable, CustomStringConvertible {
    /// A projection was asked for a column key the report does not contain.
    case unknownColumn(String)
    /// The CSV delimiter is the same character as the decimal separator, the quote character, or
    /// a line terminator. Any of the three produces a file that reads back wrong.
    case delimiterCollides(delimiter: String, with: String)
    /// More rows than the XLSX grid holds.
    case rowLimitExceeded(rows: Int, limit: Int)
    /// `CGContext(url:mediaBox:auxiliaryInfo:)` returned `nil`.
    case pdfContextUnavailable(path: String)
    /// The page is too small to hold even one column of the table at the smallest allowed font.
    case pageTooSmallForTable(usableWidth: Double)
    /// The interchange document is not what it claims to be.
    case malformedInterchange(String)
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// The file is larger than ``ZenitInterchangeImport/maximumByteCount``. Refused *before*
    /// parsing: a reader that has to allocate the whole of an untrusted file to find out it is
    /// too big has already lost.
    case interchangeTooLarge(bytes: Int, limit: Int)
    case fileWriteFailed(path: String, reason: String)
    /// The `.zpdfoverlay` document is not what it claims to be.
    case malformedOverlay(String)
    /// The overlay was measured on a different drawing than the one it is being imported onto
    /// (feature 6). The payload is the whole message: it names both files, both digests and the
    /// difference, because "does not match" leaves the user unable to find the right file.
    case overlaySourceMismatch(String)
    case xlsx(XlsxError)
    /// The layered export (ADR-0013) could not read the drawing well enough to append a layer to
    /// it: encrypted, no cross-reference section, a page count that does not match the request.
    /// The payload is the whole message, because "unreadable" leaves the estimator with a refusal
    /// and no idea which file to fix.
    case layeredSourceUnreadable(String)
    /// The optional-content group could not be recorded in the drawing's document catalog, so the
    /// markups would be burned in rather than switchable. ADR-0013 §2 requires this to be a
    /// failure carrying the reason, never a silent fall back to a flattened file.
    case layeredCatalogUnreachable(String)
    /// The annotated export (NL-PDF-01) could not append annotations to the drawing: encrypted,
    /// no cross-reference section, a sheet that differs from the one measured. The payload is the
    /// whole message.
    case annotationExportRefused(String)
    /// A summary matrix (NL-QTY-09) was asked of projections that are not the two groupings it
    /// is reshaped from. The payload names what was found.
    case summaryMatrixShape(String)

    public var description: String {
        switch self {
        case .unknownColumn(let key):
            "the report has no column with key \"\(key)\""
        case .delimiterCollides(let delimiter, let other):
            "the CSV delimiter \"\(delimiter)\" collides with \"\(other)\""
        case .rowLimitExceeded(let rows, let limit):
            "\(rows) rows exceeds the \(limit)-row limit of the format"
        case .pdfContextUnavailable(let path):
            "Core Graphics could not open a PDF context at \(path)"
        case .pageTooSmallForTable(let width):
            "a usable page width of \(width) pt cannot hold one table column"
        case .malformedInterchange(let detail):
            "the .zpdfjson document is malformed: \(detail)"
        case .unsupportedSchemaVersion(let found, let supported):
            "schema version \(found) is not readable by this build (supports \(supported))"
        case .interchangeTooLarge(let bytes, let limit):
            "the .zpdfjson document is \(bytes) bytes; this build reads at most \(limit)"
        case .fileWriteFailed(let path, let reason):
            "could not write \(path): \(reason)"
        case .malformedOverlay(let detail):
            "the .zpdfoverlay document is malformed: \(detail)"
        case .overlaySourceMismatch(let message):
            message
        case .xlsx(let error):
            error.description
        case .layeredSourceUnreadable(let message):
            message
        case .layeredCatalogUnreachable(let message):
            message
        case .annotationExportRefused(let message):
            message
        case .summaryMatrixShape(let detail):
            "a summary matrix cannot be built: \(detail)"
        }
    }
}
