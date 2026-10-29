import Foundation
import ZPDFDesignSystem

/// The four sentences a person needs when something fails, plus the safe way out.
///
/// Zenit's rule for failure copy: say **what happened**, say **why**, say **what to do next**,
/// and offer a **default action that cannot lose work**. A code is never the headline.
public struct ZPDFErrorCopy: Hashable, Sendable {

    /// What happened, in one plain sentence. No mechanism, no code, no blame.
    public var title: String
    /// Why it happened and what the state of the user's work is right now.
    public var message: String
    /// What to do next, concretely.
    public var recovery: String
    /// The safe default action. Never destructive, never "OK".
    public var primaryActionTitle: String
    /// The alternative, when there is a sensible one.
    public var secondaryActionTitle: String?
    /// Drives the glyph tint and the spoken severity. Meaning never rests on colour alone.
    public var severity: ZPDFSeverity
    /// The glyph shown beside the title.
    public var glyph: ZPDFGlyph
    /// Whether the user is stopped until they answer, or can carry on working.
    public var isBlocking: Bool

    /// Creates an error copy entry.
    public init(
        title: String,
        message: String,
        recovery: String,
        primaryActionTitle: String,
        secondaryActionTitle: String? = nil,
        severity: ZPDFSeverity,
        glyph: ZPDFGlyph,
        isBlocking: Bool
    ) {
        self.title = title
        self.message = message
        self.recovery = recovery
        self.primaryActionTitle = primaryActionTitle
        self.secondaryActionTitle = secondaryActionTitle
        self.severity = severity
        self.glyph = glyph
        self.isBlocking = isBlocking
    }
}

/// The single table that turns every ``ZPDFErrorKind`` into ``ZPDFErrorCopy``.
///
/// It is a pure function of the error, which is what makes the copy testable: a unit test walks
/// every case and asserts that all four sentences exist and that none of them leaks jargon.
public enum ZPDFErrorCopyTable {

    /// The resolved copy for one failure, with its subjects substituted in.
    public static func copy(for error: ZPDFUserFacingError) -> ZPDFErrorCopy {
        let subject = error.subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = (subject?.isEmpty == false ? subject! : fallbackSubject(for: error.kind))
        let secondarySubject = error.secondarySubject?.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = (secondarySubject?.isEmpty == false
            ? secondarySubject!
            : fallbackSecondarySubject(for: error.kind))
        return copy(for: error.kind, subject: primary, secondarySubject: secondary)
    }

    /// The resolved copy for one kind, given the nouns to substitute.
    public static func copy(
        for kind: ZPDFErrorKind,
        subject: String,
        secondarySubject: String
    ) -> ZPDFErrorCopy {
        switch kind {

        case .documentUnreadable:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "This drawing could not be opened",
                    comment: "Error title: the PDF is damaged or truncated"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ is incomplete or damaged, so its pages cannot be read. Nothing on disk was changed and no other document was affected.",
                        comment: "Error message: damaged PDF. %@ is the file name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Ask for a fresh copy from whoever sent it, or open the original from the folder it was published to. If you keep a backup of the same sheet, open that instead.",
                    comment: "Error recovery: damaged PDF"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Choose Another File",
                    comment: "Safe default action after a damaged PDF"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Show in Finder",
                    comment: "Secondary action after a damaged PDF"
                ),
                severity: .danger,
                glyph: .symbol(.error),
                isBlocking: kind.isBlocking
            )

        case .documentEncrypted:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "This drawing needs a password",
                    comment: "Error title: encrypted PDF"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ was protected by its author. Zenit can open it as soon as you supply the password that came with the file. The password is used for this session only and is never written down.",
                        comment: "Error message: encrypted PDF. %@ is the file name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Enter the password that opens the file, or ask the sender for it. If it was shared without one, ask for a copy that is not protected.",
                    comment: "Error recovery: encrypted PDF"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Enter Password",
                    comment: "Safe default action for an encrypted PDF"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Leave It Closed",
                    comment: "Secondary action for an encrypted PDF"
                ),
                severity: .warning,
                glyph: .symbol(.lock),
                isBlocking: kind.isBlocking
            )

        case .documentPasswordRejected:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "That password did not open the drawing",
                    comment: "Error title: wrong PDF password"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ did not accept the password you entered. Passwords are case sensitive, and a document can carry a different password for opening than for editing.",
                        comment: "Error message: wrong PDF password. %@ is the file name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Check for capital letters and a stray space at the end, then try again. If it still will not open, ask the sender which of the two passwords unlocks the file.",
                    comment: "Error recovery: wrong PDF password"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Try Again",
                    comment: "Safe default action after a rejected PDF password"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Leave It Closed",
                    comment: "Secondary action after a rejected PDF password"
                ),
                severity: .warning,
                glyph: .symbol(.lock),
                isBlocking: kind.isBlocking
            )

        case .documentPermissionsRestricted:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "The author of this drawing blocked that action",
                    comment: "Error title: PDF permissions forbid the operation"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ opened normally, but its author set permissions that do not allow this. Your markups and your quantities are unaffected; only this one action is refused.",
                        comment: "Error message: restricted PDF permissions. %@ is the file name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Carry on working in Zenit and publish a new PDF when you are finished, or ask the author for a copy without restrictions.",
                    comment: "Error recovery: restricted PDF permissions"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Continue Working",
                    comment: "Safe default action when PDF permissions block something"
                ),
                severity: .warning,
                glyph: .symbol(.lock),
                isBlocking: kind.isBlocking
            )

        case .noVectorContentForSnap:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "Vector Snap has nothing to hold on to here",
                    comment: "Error title: no vector geometry on the page"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ is a scanned image, so it carries no lines or corners for Zenit to lock on to. Snapping to a picture of a line would hand you a number that only looks exact.",
                        comment: "Error message: no vector content for snapping. %@ is the page label"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Zoom in and place the points by eye, or switch on Grid Snap for a regular spacing. Vector Snap turns itself back on as soon as you reach a page with real linework.",
                    comment: "Error recovery: no vector content for snapping"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Switch to Grid Snap",
                    comment: "Safe default action when Vector Snap is unavailable"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Place Points by Eye",
                    comment: "Secondary action when Vector Snap is unavailable"
                ),
                severity: .info,
                glyph: .measurement(.vectorSnap),
                isBlocking: kind.isBlocking
            )

        case .scaleMissing:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "This page does not have a scale yet",
                    comment: "Error title: no scale set for the page"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ has not been calibrated and no Scale Region covers it, so Zenit cannot turn a distance on screen into a real length. It will not guess a scale for you.",
                        comment: "Error message: missing scale. %@ is the page label"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Calibrate the page against a printed dimension you trust, or draw a Scale Region and give it the scale written in the title block.",
                    comment: "Error recovery: missing scale"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Calibrate This Page",
                    comment: "Safe default action when the page has no scale"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Draw a Scale Region",
                    comment: "Secondary action when the page has no scale"
                ),
                severity: .warning,
                glyph: .measurement(.calibrate),
                isBlocking: kind.isBlocking
            )

        case .scaleStale:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "This page's scale came from an earlier revision",
                    comment: "Error title: scale calibrated against a superseded revision"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The scale on %@ was calibrated against a revision that has since been replaced. Sheets are often re-plotted at a slightly different size, so quantities taken with the old scale can be out.",
                        comment: "Error message: stale scale. %@ is the page label"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Calibrate again against a dimension printed on the current sheet. Zenit keeps every existing measurement and flags the ones that were taken with the old scale.",
                    comment: "Error recovery: stale scale"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Calibrate Against the Current Sheet",
                    comment: "Safe default action for a stale scale"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Review Affected Measurements",
                    comment: "Secondary action for a stale scale"
                ),
                severity: .warning,
                glyph: .measurement(.calibrate),
                isBlocking: kind.isBlocking
            )

        case .incompatibleUnits:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "These two quantities cannot be added together",
                    comment: "Error title: incompatible quantity dimensions"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%1$@ and %2$@ measure different things, so there is no correct way to combine them. A total made from both would be a number with no meaning.",
                        comment: "Error message: incompatible units. %1$@ and %2$@ are the two quantity descriptions"
                    ),
                    subject,
                    secondarySubject
                ),
                recovery: NSLocalizedString(
                    "Total them in separate Quantity Ledger columns, or change one of the measurements so that both describe the same thing.",
                    comment: "Error recovery: incompatible units"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Keep Them in Separate Columns",
                    comment: "Safe default action for incompatible units"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Change a Measurement",
                    comment: "Secondary action for incompatible units"
                ),
                severity: .warning,
                glyph: .symbol(.quantityLedger),
                isBlocking: kind.isBlocking
            )

        case .exportPathNotWritable:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "Zenit cannot save to that location",
                    comment: "Error title: export destination is not writable"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ is read-only, or it is not reachable at the moment. Nothing was written there and your work is exactly as it was.",
                        comment: "Error message: export path not writable. %@ is the folder name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Choose a folder you can write to, such as your Documents folder. If the folder lives on a server or an external disk, check that it is still connected.",
                    comment: "Error recovery: export path not writable"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Choose Another Folder",
                    comment: "Safe default action when the export path is not writable"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Stop the Export",
                    comment: "Secondary action when the export path is not writable"
                ),
                severity: .danger,
                glyph: .symbol(.export),
                isBlocking: kind.isBlocking
            )

        case .exportInsufficientSpace:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "There was not enough room to finish this export",
                    comment: "Error title: destination disk is full"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The disk holding %@ filled up part-way through. Zenit removed the half-written file so that you are not left holding a PDF that opens but is wrong.",
                        comment: "Error message: not enough disk space. %@ is the folder name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Free up space or pick a disk with more room, then export again. Exporting a shorter page range, or leaving out embedded images, also makes the file smaller.",
                    comment: "Error recovery: not enough disk space"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Choose Another Folder",
                    comment: "Safe default action when the disk is full"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Export Fewer Pages",
                    comment: "Secondary action when the disk is full"
                ),
                severity: .danger,
                glyph: .symbol(.export),
                isBlocking: kind.isBlocking
            )

        case .projectRecoveryAvailable:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "Zenit kept your work from the last session",
                    comment: "Error title: crash recovery is available"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The app stopped unexpectedly while %@ was open. Everything up to the last automatic save was kept aside, and the project file on disk was never overwritten.",
                        comment: "Error message: crash recovery available. %@ is the project name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Open the recovered version and check your most recent measurements against the drawing. If anything looks wrong you can discard it and go back to the version that was last saved.",
                    comment: "Error recovery: crash recovery available"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Open the Recovered Work",
                    comment: "Safe default action for crash recovery"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Keep the Saved Version",
                    comment: "Secondary action for crash recovery"
                ),
                severity: .info,
                glyph: .symbol(.undo),
                isBlocking: kind.isBlocking
            )

        case .toolSetImportRejected:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "This tool set was not added to your Tool Library",
                    comment: "Error title: tool set import failed safety review"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ is not in the shape Zenit reads, or it asks to contain more than a tool set is allowed to. Nothing from the file was added, and your existing tools are untouched.",
                        comment: "Error message: rejected tool set import. %@ is the file name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Ask whoever sent it to export the set again from Zenit, then choose the new file.",
                    comment: "Error recovery: rejected tool set import"
                ),
                // "Review What the File Contains" stood here, on a path where no review exists.
                // IM-146.
                primaryActionTitle: NSLocalizedString(
                    "Choose Another File",
                    comment: "Safe default action for a rejected tool set import"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Stop the Import",
                    comment: "Secondary action for a rejected tool set import"
                ),
                severity: .warning,
                glyph: .symbol(.toolLibrary),
                isBlocking: kind.isBlocking
            )

        case .toolSetFileTooLarge:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "This file is too large to be a tool set",
                    comment: "Error title: chosen tool set file exceeds the size limit"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%1$@ is larger than %2$@, the most a tool set file may be, so Zenit did not open it. Nothing was added and your existing tools are untouched.",
                        comment: "Error message: oversize tool set file. %1$@ is the file name, %2$@ the size limit"
                    ),
                    subject,
                    secondarySubject
                ),
                recovery: NSLocalizedString(
                    "Check that you chose a tool set exported from Zenit. A set with a few hundred tools is far smaller than the limit; large pictures are what usually make one grow.",
                    comment: "Error recovery: oversize tool set file"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Choose Another File",
                    comment: "Safe default action for an oversize tool set file"
                ),
                severity: .warning,
                glyph: .symbol(.toolLibrary),
                isBlocking: kind.isBlocking
            )

        case .toolSetFileUnreadable:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "This file is not a tool set",
                    comment: "Error title: chosen file could not be read as a tool set"
                ),
                message: String(
                    format: NSLocalizedString(
                        "%@ could not be read as a Zenit tool set, so there is nothing to review. Nothing was added and your existing tools are untouched.",
                        comment: "Error message: unreadable tool set file. %@ is the file name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Choose a file exported with Export This Set in the Tool Library. If someone sent it to you, ask them to export it again.",
                    comment: "Error recovery: unreadable tool set file"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Choose Another File",
                    comment: "Safe default action for an unreadable tool set file"
                ),
                severity: .warning,
                glyph: .symbol(.toolLibrary),
                isBlocking: kind.isBlocking
            )

        case .toolSetPictureNotKept:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "A tool's picture was not kept",
                    comment: "Error title: an imported tool's picture could not be stored"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The picture %@ could not be stored. The imported tool was added without it.",
                        comment: "Error message: imported tool picture not kept. %@ is the picture's file name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Duplicate the tool into My Tools and choose a picture for the copy in its editor.",
                    comment: "Error recovery: imported tool picture not kept"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Continue Without the Picture",
                    comment: "Safe default action when an imported tool picture was not kept"
                ),
                severity: .info,
                glyph: .symbol(.toolLibrary),
                isBlocking: kind.isBlocking
            )

        case .ocrUnavailable:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "Text recognition could not run on those pages",
                    comment: "Error title: OCR could not start"
                ),
                message: String(
                    format: NSLocalizedString(
                        "Zenit reads scanned pages using your own Mac, and recognition could not start for %@. No page left this machine; recognition never runs anywhere else.",
                        comment: "Error message: OCR unavailable. %@ is the page range description"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Try a shorter page range, or close other heavy apps and run it again. Pages that already carry real text do not need recognition and are skipped anyway.",
                    comment: "Error recovery: OCR unavailable"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Try a Shorter Range",
                    comment: "Safe default action when OCR cannot run"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Search Without Recognition",
                    comment: "Secondary action when OCR cannot run"
                ),
                severity: .warning,
                glyph: .symbol(.search),
                isBlocking: kind.isBlocking
            )

        case .searchIndexRebuildRequired:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "Search results for this project would be incomplete",
                    comment: "Error title: search index must be rebuilt"
                ),
                message: String(
                    format: NSLocalizedString(
                        "The search index for %@ is missing or older than the documents it describes. Zenit would rather tell you that than quietly show you a short list.",
                        comment: "Error message: search index rebuild required. %@ is the project name"
                    ),
                    subject
                ),
                recovery: NSLocalizedString(
                    "Rebuild the index. It runs quietly in the background, you can keep working while it does, and results fill in as each page is covered.",
                    comment: "Error recovery: search index rebuild required"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Rebuild the Index",
                    comment: "Safe default action when the search index is stale"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Search the Open Document Only",
                    comment: "Secondary action when the search index is stale"
                ),
                severity: .info,
                glyph: .symbol(.search),
                isBlocking: kind.isBlocking
            )

        case .revisionAlignmentRejected:
            return ZPDFErrorCopy(
                title: NSLocalizedString(
                    "These two revisions could not be lined up",
                    comment: "Error title: automatic revision alignment failed"
                ),
                message: String(
                    format: NSLocalizedString(
                        "Zenit could not find enough matching detail between %1$@ and %2$@ to lay one over the other. A comparison built on a poor alignment invents differences that are not on the drawing.",
                        comment: "Error message: revision alignment rejected. %1$@ and %2$@ are the two revision names"
                    ),
                    subject,
                    secondarySubject
                ),
                recovery: NSLocalizedString(
                    "Line the sheets up yourself by picking two or three points that appear on both, such as a grid intersection or the corner of the title block. Zenit shows how far off the fit is as you go.",
                    comment: "Error recovery: revision alignment rejected"
                ),
                primaryActionTitle: NSLocalizedString(
                    "Line Them Up by Hand",
                    comment: "Safe default action when revision alignment fails"
                ),
                secondaryActionTitle: NSLocalizedString(
                    "Stop the Comparison",
                    comment: "Secondary action when revision alignment fails"
                ),
                severity: .warning,
                glyph: .symbol(.revisionCompare),
                isBlocking: kind.isBlocking
            )
        }
    }

    /// The noun the copy falls back to when the caller supplied no subject.
    public static func fallbackSubject(for kind: ZPDFErrorKind) -> String {
        switch kind {
        case .documentUnreadable, .documentEncrypted, .documentPasswordRejected,
             .documentPermissionsRestricted:
            return NSLocalizedString("This drawing", comment: "Fallback noun for a document in error copy")
        case .noVectorContentForSnap, .scaleMissing:
            return NSLocalizedString("This page", comment: "Fallback noun for a page in error copy")
        // Substituted mid-sentence, so lower case: "The scale on This page was calibrated…"
        // and "The disk holding The folder you chose…" were the old readings. Finding BH-833.
        case .scaleStale:
            return NSLocalizedString("this page", comment: "Fallback noun for a page, mid-sentence, in error copy")
        case .exportInsufficientSpace:
            return NSLocalizedString("the folder you chose", comment: "Fallback noun for an export folder, mid-sentence, in error copy")
        case .incompatibleUnits:
            return NSLocalizedString("This quantity", comment: "Fallback noun for the first quantity in error copy")
        case .exportPathNotWritable:
            return NSLocalizedString("The folder you chose", comment: "Fallback noun for an export folder in error copy")
        case .projectRecoveryAvailable, .searchIndexRebuildRequired:
            return NSLocalizedString("this project", comment: "Fallback noun for the project in error copy")
        case .toolSetImportRejected, .toolSetFileTooLarge, .toolSetFileUnreadable:
            return NSLocalizedString("This file", comment: "Fallback noun for an imported file in error copy")
        case .toolSetPictureNotKept:
            return NSLocalizedString("of an imported tool", comment: "Fallback noun for an imported tool picture in error copy")
        case .ocrUnavailable:
            return NSLocalizedString("the pages you chose", comment: "Fallback noun for a page range in error copy")
        case .revisionAlignmentRejected:
            return NSLocalizedString("the baseline revision", comment: "Fallback noun for the baseline revision in error copy")
        }
    }

    /// The second noun the copy falls back to, for the two kinds that compare two things.
    public static func fallbackSecondarySubject(for kind: ZPDFErrorKind) -> String {
        switch kind {
        case .incompatibleUnits:
            return NSLocalizedString("the other quantity", comment: "Fallback noun for the second quantity in error copy")
        case .revisionAlignmentRejected:
            return NSLocalizedString("the revision it is compared with", comment: "Fallback noun for the comparison revision in error copy")
        case .toolSetFileTooLarge:
            return ByteCountFormatter.string(
                fromByteCount: Int64(ToolSetImportValidator.Limits.standard.maximumFileByteCount),
                countStyle: .file
            )
        default:
            return fallbackSubject(for: kind)
        }
    }
}

/// The copy table, spoken through Foundation's error protocol (R-119).
///
/// Every shipping failure goes through the application's one modal-safe presenter, which hands
/// the error to AppKit's `presentError`. AppKit reads an error through its `NSError` bridge, and
/// without this conformance that bridge knew nothing about the copy table: an oversized tool set
/// file was announced as "The operation couldn't be completed.
/// (ZPDFUIWorkflows.ZPDFUserFacingError error 1.)".
///
/// AppKit's alert prints ``errorDescription`` as its headline and ``recoverySuggestion`` as the
/// text beneath, and never prints ``failureReason``. The recovery suggestion therefore carries
/// the *why* and then the *what next*, so the alert still says all three things the copy rule
/// asks for; ``failureReason`` carries the *why* alone for readers that do show it.
extension ZPDFUserFacingError: LocalizedError {

    /// What happened: the copy's title.
    public var errorDescription: String? { ZPDFErrorCopyTable.copy(for: self).title }

    /// Why it happened and where the person's work stands: the copy's message.
    public var failureReason: String? { ZPDFErrorCopyTable.copy(for: self).message }

    /// Why, then what to do next, as the one paragraph an alert shows under its headline.
    public var recoverySuggestion: String? {
        let copy = ZPDFErrorCopyTable.copy(for: self)
        return copy.message + "\n\n" + copy.recovery
    }
}
