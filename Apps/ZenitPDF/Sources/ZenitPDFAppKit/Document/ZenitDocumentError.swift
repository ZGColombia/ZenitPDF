import Darwin
import Foundation
import ZPDFPersistence

/// Failures the application layer raises on its own, in the vocabulary a person reading an alert
/// needs rather than the vocabulary the engine failed in.
///
/// Engine errors (`PDFBridgeError`, `ZPDFPersistenceError`, `DocumentCommandError`) are passed
/// through unwrapped where they already say something useful; this enum covers the cases where the
/// application knows more than the engine did.
public enum ZenitDocumentError: LocalizedError, Sendable, Hashable {

    /// A file whose type is neither PDF nor `.zpdfproj`.
    case unsupportedFileType(String)
    /// A save was asked for before the document finished opening.
    case documentNotReady
    /// Quick PDF Mode cannot save in place: there is no project to save into yet.
    case quickModeRequiresProject
    /// The project package is missing the PDF it says it holds.
    case projectMissingDocument(String)
    /// Measuring was attempted with no scale set.
    case noScale
    /// A chosen save location refused the project package. The detail is the engine's
    /// description, kept out of the headline (UX_COPY_STANDARD: no raw error codes).
    case projectSaveFailed(String, detail: String)
    /// The repair service could not rebuild a copy of a damaged drawing.
    case repairFailed(String, detail: String)
    /// A password-protected drawing was opened and nobody entered its password (LT-38).
    /// The open is refused in words — never a silently blank sheet.
    case passwordRequired(String)
    /// The password entered for a protected drawing did not unlock it (LT-38).
    case wrongPassword(String)
    /// A save ran out of disk space. Not the folder's fault (BH-354, IM-176).
    case projectSaveNoSpace(String)
    /// The drawing inside the project changed on disk under the open takeoff.
    case projectSaveDrawingChanged(String)
    /// The takeoff failed the pre-save validation; the detail names the first issue.
    case projectSaveInvalid(String, detail: String)
    /// The project database refused the write; retrying is the useful advice.
    case projectSaveDatabaseFailed(String, detail: String)
    /// Revert to Saved / a Versions restore cannot reload an open takeoff (BH-355).
    case revertUnavailable
    /// An annotated export changed the bytes of the drawing it exported (BH-374). An
    /// integrity breach, said as one — never "the drawing is still opening".
    case exportChangedSource(String)

    /// The error a failed project save is presented as, chosen by what actually failed.
    ///
    /// Every persistence failure used to become ``projectSaveFailed(_:detail:)``, whose title
    /// and advice blame the location — so a full disk, an externally changed drawing or a
    /// database fault all told the person to "choose a folder you can write to", including
    /// on an autosave where nobody chose a folder (BH-354, IM-176).
    public static func saveFailure(_ error: ZPDFPersistenceError, projectName name: String) -> ZenitDocumentError {
        let detail = String(describing: error)
        switch error {
        case let .posixFailure(_, _, code) where code == ENOSPC || code == EDQUOT:
            return .projectSaveNoSpace(name)
        case let .atomicReplaceFailed(_, code) where code == ENOSPC || code == EDQUOT:
            return .projectSaveNoSpace(name)
        case .originalPDFModified, .projectModifiedOutsideZenit:
            return .projectSaveDrawingChanged(name)
        case let .saveValidationFailed(issues):
            return .projectSaveInvalid(name, detail: issues.first.map { String(describing: $0) } ?? detail)
        case .databaseFailure, .walCheckpointFailed, .databaseOpenFailed, .integrityCheckFailed:
            return .projectSaveDatabaseFailed(name, detail: detail)
        default:
            return .projectSaveFailed(name, detail: detail)
        }
    }

    /// The engine's own words, for the alert's detail line and for Copy (BH-354). Kept out of
    /// the headline (UX_COPY_STANDARD) but no longer thrown away.
    public var failureReason: String? {
        switch self {
        case let .projectSaveFailed(_, detail), let .repairFailed(_, detail),
             let .projectSaveInvalid(_, detail), let .projectSaveDatabaseFailed(_, detail):
            return detail
        default:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let name):
            return String(
                format: NSLocalizedString(
                    "Zenit PDF cannot open “%@”.",
                    comment: "Error title when a file is neither a PDF nor a Zenit project"
                ),
                name
            )
        case .documentNotReady:
            return NSLocalizedString(
                "The drawing is still opening.",
                comment: "Error title when an action needs a document that has not finished loading"
            )
        case .quickModeRequiresProject:
            return NSLocalizedString(
                "This PDF is open for reading and measuring, not as a project.",
                comment: "Error title when saving a PDF opened in Quick PDF Mode"
            )
        case .projectMissingDocument(let name):
            return String(
                format: NSLocalizedString(
                    "The project “%@” does not contain the drawing it refers to.",
                    comment: "Error title when a .zpdfproj package is missing its PDF"
                ),
                name
            )
        case .noScale:
            return NSLocalizedString(
                "This drawing has no scale yet.",
                comment: "Error title when measuring without a calibrated scale"
            )
        case .projectSaveFailed(let name, _):
            return String(
                format: NSLocalizedString(
                    "The project “%@” could not be saved at that location.",
                    comment: "Error title when writing a .zpdfproj package fails; the project name"
                ),
                name
            )
        case .repairFailed(let name, _):
            return String(
                format: NSLocalizedString(
                    "“%@” could not be repaired.",
                    comment: "Error title when the repair service fails; the file name"
                ),
                name
            )
        case .passwordRequired(let name):
            return String(
                format: NSLocalizedString(
                    "“%@” is protected by a password and was not opened.",
                    comment: "Error title when a protected drawing is opened without its password; the file name"
                ),
                name
            )
        case .wrongPassword(let name):
            return String(
                format: NSLocalizedString(
                    "That password did not unlock “%@”, so it was not opened.",
                    comment: "Error title when the entered password is refused; the file name"
                ),
                name
            )
        case .projectSaveNoSpace(let name):
            return String(
                format: NSLocalizedString(
                    "The project “%@” could not be saved: there is not enough free space on the disk.",
                    comment: "Error title when a save fails for lack of disk space; the project name"
                ),
                name
            )
        case .projectSaveDrawingChanged(let name):
            return String(
                format: NSLocalizedString(
                    "The project “%@” could not be saved: the drawing inside it was changed by another app.",
                    comment: "Error title when the project's drawing changed on disk; the project name"
                ),
                name
            )
        case .projectSaveInvalid(let name, _):
            return String(
                format: NSLocalizedString(
                    "The project “%@” could not be saved: part of the takeoff did not pass the save check.",
                    comment: "Error title when pre-save validation fails; the project name"
                ),
                name
            )
        case .projectSaveDatabaseFailed(let name, _):
            return String(
                format: NSLocalizedString(
                    "The project “%@” could not be saved: its database refused the write.",
                    comment: "Error title when the project database write fails; the project name"
                ),
                name
            )
        case .revertUnavailable:
            return NSLocalizedString(
                "This takeoff cannot be reverted to a saved version while it is open.",
                comment: "Error title when Revert to Saved or a Versions restore is refused"
            )
        case .exportChangedSource(let name):
            return String(
                format: NSLocalizedString(
                    "Exporting changed the original drawing “%@”.",
                    comment: "Error title when an annotated export altered the source PDF; the file name"
                ),
                name
            )
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedFileType:
            return NSLocalizedString(
                "Choose a PDF drawing or a Zenit PDF project.",
                comment: "Recovery suggestion for an unsupported file"
            )
        case .documentNotReady:
            return NSLocalizedString(
                "Try again once the pages have appeared.",
                comment: "Recovery suggestion while a document is loading"
            )
        case .quickModeRequiresProject:
            return NSLocalizedString(
                "Choose File ▸ Create Zenit PDF Project… to keep this takeoff.",
                comment: "Recovery suggestion for saving from Quick PDF Mode"
            )
        case .projectMissingDocument:
            return NSLocalizedString(
                "Restore the project from a backup, or open the original drawing directly.",
                comment: "Recovery suggestion for a project missing its PDF"
            )
        case .noScale:
            return NSLocalizedString(
                "Choose Measure ▸ Set Scale… and set a known length.",
                comment: "Recovery suggestion when there is no scale"
            )
        case .projectSaveFailed:
            return NSLocalizedString(
                "Choose a folder you can write to — Documents, for example — and save again. Your takeoff is still open and unchanged.",
                comment: "Recovery suggestion when writing a project package fails"
            )
        case .repairFailed:
            return NSLocalizedString(
                "The file may be damaged beyond rebuilding. Ask for a re-export of the drawing. The original file was not changed.",
                comment: "Recovery suggestion when repair fails"
            )
        case .passwordRequired:
            return NSLocalizedString(
                "Open the drawing again and enter its password to unlock it.",
                comment: "Recovery suggestion when a protected drawing was opened without its password"
            )
        case .wrongPassword:
            return NSLocalizedString(
                "Check the password with whoever issued the drawing, then open it again.",
                comment: "Recovery suggestion when the entered password was refused"
            )
        case .projectSaveNoSpace:
            return NSLocalizedString(
                "Free some space on the disk and save again. Your takeoff is still open and unchanged.",
                comment: "Recovery suggestion when a save fails for lack of disk space"
            )
        case .projectSaveDrawingChanged:
            return NSLocalizedString(
                "Your takeoff is still open. Save it as a new project (File ▸ Save As…) so neither version is lost.",
                comment: "Recovery suggestion when the project's drawing changed on disk"
            )
        case .projectSaveInvalid:
            return NSLocalizedString(
                "Your takeoff is still open and unchanged. The details below name what failed the check.",
                comment: "Recovery suggestion when pre-save validation fails"
            )
        case .projectSaveDatabaseFailed:
            return NSLocalizedString(
                "Try saving again. If it keeps failing, save a copy with File ▸ Save As…. Your takeoff is still open.",
                comment: "Recovery suggestion when the project database write fails"
            )
        case .revertUnavailable:
            return NSLocalizedString(
                "Nothing was changed. Use Undo or the History pane to step back, or close without saving and open the project again.",
                comment: "Recovery suggestion when revert is refused"
            )
        case .exportChangedSource:
            return NSLocalizedString(
                "Do not export again from this drawing. Check the original file against a backup before you use it.",
                comment: "Recovery suggestion when an export altered the source PDF"
            )
        }
    }
}
