import Foundation

/// Everything this package can refuse to do, as data.
///
/// The `ZPDF` prefix is not decoration: GRDB exports `public typealias PersistenceError
/// = RecordError`, and this package re-exports GRDB types in its own API, so an
/// unprefixed `PersistenceError` would be ambiguous in every file that imports both.
///
/// A `.zpdfproj` is opened from disk, and disk contents are untrusted: a truncated
/// manifest, a database written by a newer build, a geometry blob whose ring count
/// claims four billion points. Every one of those paths returns a case of this enum.
/// Nothing in this package traps, force-unwraps external data, or calls `fatalError`.
public enum ZPDFPersistenceError: Error, Sendable, Equatable {

    // MARK: Package structure

    /// No file or directory at the given path.
    case packageNotFound(path: String)
    /// Something is at the path, but it is not a `.zpdfproj` directory.
    case packageNotADirectory(path: String)
    /// A create was asked to write over an existing item.
    case packageAlreadyExists(path: String)
    /// A required member of the package is missing or unusable.
    case packageMemberMissing(relativePath: String)
    /// The package is structurally present but internally inconsistent.
    case packageMalformed(reason: String)

    // MARK: Manifest and schema

    /// `manifest.json` could not be read or decoded.
    case manifestUnreadable(reason: String)
    /// The manifest declares a package schema this build does not understand.
    ///
    /// This is the refusal that protects a user who opens tomorrow's file with
    /// today's app: the file is left completely untouched.
    case packageSchemaTooNew(found: Int, supported: Int)
    /// The manifest declares a coordinate convention this build cannot interpret.
    ///
    /// `coordinateSystem` exists so that a future coordinate convention is a data
    /// change rather than a silent reinterpretation of old files. Guessing is the one
    /// thing that must not happen: for a takeoff application a silently reinterpreted
    /// coordinate space is a wrong number on an invoice, and it looks like a right one.
    case unsupportedCoordinateSystem(found: String, supported: String)
    /// The database on disk was migrated past the newest migration this build knows.
    case databaseSchemaTooNew(found: String, supported: Int)

    // MARK: Database

    /// The database could not be opened.
    case databaseOpenFailed(path: String, reason: String)
    /// A SQLite error escaped a read or a write.
    case databaseFailure(message: String, resultCode: Int32)
    /// `PRAGMA integrity_check` did not return `ok`.
    case integrityCheckFailed(detail: String)
    /// The database carries a schema object this build's migrations never created —
    /// a trigger, a view, a table or an index written by whoever produced the file.
    ///
    /// `PRAGMA integrity_check` answers "are the b-trees intact", not "did we write
    /// this schema". A `.zpdfproj` is a document, so the schema inside it is an input
    /// like any other and an object we did not create is attacker logic that would run
    /// inside our own transactions.
    case foreignSchemaObject(objectType: String, name: String)
    /// A schema object this build *does* create is present under the right name with
    /// the wrong definition — the shape a tampered append-only audit trigger takes.
    case schemaObjectAltered(objectType: String, name: String)
    /// A WAL checkpoint could not be completed within the busy timeout.
    case walCheckpointFailed(reason: String)
    /// A write was attempted on a package opened read-only.
    case writeOnReadOnlyPackage

    // MARK: Values

    /// A decimal column did not hold a canonical decimal string.
    case malformedDecimalString(String)
    /// A geometry blob failed structural validation.
    case malformedGeometryBlob(GeometryBlobError)

    // MARK: Integrity

    /// The package's contents do not match the hashes the package itself records, and
    /// the evidence says a person or a program changed them outside this application.
    ///
    /// Distinct from ``projectDamaged(detail:)`` on purpose. These two get different
    /// sentences in front of the user, because they call for different actions: a
    /// damaged project is recovered, a modified one is not trusted.
    case projectModifiedOutsideZenit(detail: String)
    /// The package's contents do not match its own integrity record, and the evidence
    /// points at an interrupted session or a bad disk rather than at an editor.
    case projectDamaged(detail: String)

    // MARK: Save pipeline

    /// The domain model did not pass validation, so nothing was written.
    case saveValidationFailed(issues: [ValidationIssue])
    /// The sibling temporary package could not be produced.
    case temporaryPackageWriteFailed(reason: String)
    /// A POSIX call in the durability path failed.
    case posixFailure(operation: String, path: String, errnoValue: Int32)
    /// The atomic swap of the temporary package and the live package failed.
    case atomicReplaceFailed(reason: String, errnoValue: Int32)
    /// The original PDF changed underneath us. It is never rewritten by this package.
    case originalPDFModified(expected: String, found: String)

    // MARK: Recovery

    /// The package carries crash evidence and the caller has not chosen an outcome yet.
    case recoveryDecisionRequired(assessment: RecoveryAssessment)
    /// A recovery source was unusable.
    case recoveryFailed(reason: String)

    // MARK: Limits and cancellation

    /// A bounded read refused an input larger than its cap.
    case inputTooLarge(what: String, byteCount: Int, limit: Int)
    /// The operation observed cancellation and unwound without writing.
    case cancelled
}

extension ZPDFPersistenceError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .packageNotFound(path):
            return "No project package at \(path)."
        case let .packageNotADirectory(path):
            return "\(path) is not a .zpdfproj package directory."
        case let .packageAlreadyExists(path):
            return "An item already exists at \(path)."
        case let .packageMemberMissing(relativePath):
            return "The package is missing \(relativePath)."
        case let .packageMalformed(reason):
            return "The package is malformed: \(reason)."
        case let .manifestUnreadable(reason):
            return "manifest.json could not be read: \(reason)."
        case let .unsupportedCoordinateSystem(found, supported):
            return """
                This project declares the coordinate system \(found), which this build \
                of Zenit PDF cannot interpret; it understands \(supported). Opening it \
                would read every coordinate in the project as if it meant something \
                else. The file has not been modified.
                """
        case let .packageSchemaTooNew(found, supported):
            return """
                This project was saved by a newer version of Zenit PDF \
                (package schema \(found); this build understands \(supported)). \
                The file has not been modified.
                """
        case let .databaseSchemaTooNew(found, supported):
            return """
                The project database was migrated by a newer version of Zenit PDF \
                (unknown migration \(found); this build knows \(supported) migrations). \
                The file has not been modified.
                """
        case let .databaseOpenFailed(path, reason):
            return "Could not open the database at \(path): \(reason)."
        case let .databaseFailure(message, resultCode):
            return "SQLite error \(resultCode): \(message)."
        case let .integrityCheckFailed(detail):
            return "Database integrity check failed: \(detail)."
        case let .foreignSchemaObject(objectType, name):
            return """
                This project has been modified outside Zenit PDF: its database contains \
                a \(objectType) named \(name) that Zenit PDF did not create. Opening it \
                for editing would run that \(objectType) inside this application.
                """
        case let .schemaObjectAltered(objectType, name):
            return """
                This project has been modified outside Zenit PDF: the \(objectType) \
                \(name) is not the one Zenit PDF creates. Its definition has been \
                changed.
                """
        case let .projectModifiedOutsideZenit(detail):
            return "This project has been modified outside Zenit PDF: \(detail)."
        case let .projectDamaged(detail):
            return "This project is damaged: \(detail)."
        case let .walCheckpointFailed(reason):
            return "WAL checkpoint failed: \(reason)."
        case .writeOnReadOnlyPackage:
            return "This project is open read-only."
        case let .malformedDecimalString(value):
            return "Not a canonical decimal string: \(value)."
        case let .malformedGeometryBlob(error):
            return "Malformed geometry blob: \(error)."
        case let .saveValidationFailed(issues):
            let list = issues.map(\.description).joined(separator: "; ")
            return "The project did not pass validation, so nothing was saved: \(list)."
        case let .temporaryPackageWriteFailed(reason):
            return "The temporary package could not be written: \(reason)."
        case let .posixFailure(operation, path, code):
            return "\(operation) failed on \(path) with errno \(code)."
        case let .atomicReplaceFailed(reason, code):
            return "Atomic replace failed (\(reason), errno \(code)). The project was left untouched."
        case let .originalPDFModified(expected, found):
            return "The original PDF changed on disk (expected \(expected), found \(found))."
        case let .recoveryDecisionRequired(assessment):
            return "This project needs a recovery decision (\(assessment.summary))."
        case let .recoveryFailed(reason):
            return "Recovery failed: \(reason)."
        case let .inputTooLarge(what, byteCount, limit):
            return "\(what) is \(byteCount) bytes, over the \(limit)-byte limit."
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}

/// One reason a save was refused.
public struct ValidationIssue: Sendable, Hashable, Codable, CustomStringConvertible {
    /// The table, or `manifest`, the problem was found in.
    public let subject: String
    /// A short machine-stable code, so the UI can map an issue to a repair action.
    public let code: String
    /// A human-readable explanation.
    public let detail: String

    public init(subject: String, code: String, detail: String) {
        self.subject = subject
        self.code = code
        self.detail = detail
    }

    public var description: String { "[\(subject)/\(code)] \(detail)" }
}

/// What `NSError` bridging shows a person (IM-007).
///
/// Without this, an engine error that reaches `NSDocument.presentError` or an alert
/// reads "The operation couldn't be completed. (ZPDFPersistence.ZPDFPersistenceError
/// error 18.)" — the sentence written for the case above never appears. The description
/// is the title; the suggestion, where one exists, tells the person what to do.
extension ZPDFPersistenceError: LocalizedError {
    public var errorDescription: String? { description }

    public var recoverySuggestion: String? {
        switch self {
        case .packageSchemaTooNew, .databaseSchemaTooNew, .unsupportedCoordinateSystem:
            return "Update Zenit PDF to open this project."
        case .projectModifiedOutsideZenit, .foreignSchemaObject, .schemaObjectAltered:
            return "Open the project read-only to look at it, or restore a saved version."
        case .projectDamaged, .integrityCheckFailed, .recoveryFailed:
            return "Restore the project from a saved version."
        case .writeOnReadOnlyPackage:
            return "Reopen the project for editing to make changes."
        case .saveValidationFailed:
            return "Correct the listed items and save again."
        case .originalPDFModified:
            return "The original drawing inside the project was changed by another program. "
                + "Restore it from a saved version before saving."
        default:
            return nil
        }
    }
}

extension ZPDFPersistenceError {
    /// The refusal for foreign-key violations found at open (IM-194), or `nil` when there are
    /// none. Foreign keys are enforced on every connection a package opens, so a violation can
    /// only arrive from outside. Shared by the open path and `zenit verify` (V-094).
    public static func foreignKeyRefusal(violationCount: Int) -> ZPDFPersistenceError? {
        violationCount > 0 ? .integrityCheckFailed(detail: "\(violationCount) foreign-key violation(s)") : nil
    }
}
