import Foundation
import Observation
import ZPDFUIPresentation

/// Runs the artwork import conversation: choose a file, see what is in it, choose a page,
/// read what the import will actually produce, and only then commit.
///
/// # Why this is a model and not four `@State` properties on the sheet
///
/// The flow has three states a person can be in (nothing chosen, a PDF chosen and not yet
/// imported, a compile in flight) and two ways out of each. Held as view state it is provable
/// only by clicking, and screen control is off in this project — so the whole conversation
/// lives here, is driven by a test against a fake handler, and the view does nothing but show
/// what this says and call what this exposes.
///
/// # What it fixes
///
/// Two import gaps that were documented rather than handled:
///
/// - **A multi-page PDF imported page 1 silently.** The button's help text said so, which is
///   not the same as handling it. A PDF is now inspected first
///   (``ArtworkImportChoice/inspectPDF(url:)``) and its pages offered.
/// - **How imported vector artwork takes colour** (ADR-0011 §2.4) was told only in an ADR.
///   ``ArtworkVectorLimits/singleInkNotice`` is on the sheet, above the Import button,
///   before they commit — which is why the sheet appears even for a one-page PDF, where there
///   is no page to choose.
@MainActor
@Observable
public final class ArtworkImportCoordinator {

    /// A PDF that has been inspected and is waiting for the person to press Import.
    public struct PendingPDF: Hashable, Sendable, Identifiable {
        /// The chosen file.
        public var url: URL
        /// What the inspection found.
        public var summary: ArtworkSourceSummary
        public var id: URL { url }
        /// Whether the sheet shows a page chooser.
        public var offersPageChoice: Bool { summary.offersPageChoice }
    }

    /// The compiler and store, installed by the host. `nil` leaves every entry point inert,
    /// which is what a preview and a document with no project package get.
    public var importArtwork: ArtworkImportHandler?

    /// Receives the descriptor a successful import produced. The preset editor points its
    /// draft at it.
    public var onImported: (@MainActor (StampArtworkDescriptor) -> Void)?

    /// The PDF awaiting confirmation, or `nil` when no import sheet is open.
    public private(set) var pendingPDF: PendingPDF?

    /// The page the sheet's chooser is showing, **one-based**, because that is how a person
    /// and every other page control in this product counts pages. Converted to the importer's
    /// zero-based index in exactly one place, ``confirm()``.
    public var pageNumber: Int = 1

    /// Whether a probe or a compile is in flight, so a button cannot be pressed twice.
    public private(set) var isBusy = false

    /// The importer's own refusal sentence, with its number in it, or `nil`.
    public private(set) var refusal: String?

    /// Whether the host installed a handler at all. The Artwork row is read-only when not.
    public var isAvailable: Bool { importArtwork != nil }

    public init() {}

    /// Clears a refusal the person has read.
    public func clearRefusal() { refusal = nil }

    /// Records a refusal raised before the importer was reached — a file chooser that failed,
    /// a document that closed. It reads the same way as the importer's own.
    public func report(refusal reason: String) { refusal = reason }

    // MARK: - PDF

    /// A PDF was chosen. Inspects it and opens the import sheet; imports nothing yet.
    ///
    /// A refusal here is the file's, not the page's: too large, encrypted, unreadable. It is
    /// shown in the editor's Artwork row rather than in a sheet that never opened.
    public func choosePDF(at url: URL) async {
        guard let importArtwork, !isBusy else { return }
        refusal = nil
        isBusy = true
        let outcome = await importArtwork(.inspectPDF(url: url))
        isBusy = false
        switch outcome {
        case let .inspected(summary):
            pageNumber = 1
            pendingPDF = PendingPDF(url: url, summary: summary)
        case let .refused(reason):
            pendingPDF = nil
            refusal = reason
        case .imported:
            // An inspection that imported something is a handler that answered a different
            // question. Nothing is adopted on the strength of it; the person presses the
            // button again and gets the sheet.
            pendingPDF = nil
            refusal = NSLocalizedString(
                "That file could not be inspected before importing.",
                comment: "Artwork import refusal when the inspection answered with an import"
            )
        }
    }

    /// The person pressed Import on the PDF sheet. Compiles the chosen page.
    ///
    /// The one place a one-based page number becomes a zero-based page index. The sheet is
    /// dismissed on success and on refusal alike: a refusal that leaves the sheet open with
    /// the same page selected invites the same press.
    public func confirm() async {
        guard let importArtwork, let pending = pendingPDF, !isBusy else { return }
        let index = max(0, min(pending.summary.pageCount - 1, pageNumber - 1))
        isBusy = true
        let outcome = await importArtwork(.pdfPage(url: pending.url, pageIndex: index))
        isBusy = false
        pendingPDF = nil
        adopt(outcome)
    }

    /// The person cancelled the PDF sheet. Nothing was compiled and nothing was stored.
    public func cancel() {
        pendingPDF = nil
    }

    // MARK: - Image

    /// An image was chosen. There is no page to choose and the colour limit does not apply to
    /// a mosaic, which keeps its own colours, so this commits directly.
    public func chooseImage(at url: URL) async {
        guard let importArtwork, !isBusy else { return }
        refusal = nil
        isBusy = true
        let outcome = await importArtwork(.image(url: url))
        isBusy = false
        adopt(outcome)
    }

    // MARK: - Shared

    private func adopt(_ outcome: ArtworkImportOutcome) {
        switch outcome {
        case let .imported(descriptor):
            refusal = nil
            onImported?(descriptor)
        case let .refused(reason):
            refusal = reason
        case .inspected:
            refusal = NSLocalizedString(
                "That file was inspected but not imported.",
                comment: "Artwork import refusal when the import answered with an inspection"
            )
        }
    }

    /// The sheet's title line: the file's name and how many pages it has.
    public var pendingTitle: String {
        guard let pending = pendingPDF else { return "" }
        if pending.summary.offersPageChoice {
            return String(
                format: NSLocalizedString(
                    "%1$@ — %2$@",
                    comment: "Artwork import sheet heading. 1: file name, 2: the page count as '12 pages'"
                ),
                pending.summary.fileName,
                WorkflowPlurals.pages(pending.summary.pageCount)
            )
        }
        return String(
            format: NSLocalizedString(
                "%@ — 1 page",
                comment: "Artwork import sheet heading for a single-page PDF. %@ is the file name"
            ),
            pending.summary.fileName
        )
    }
}
