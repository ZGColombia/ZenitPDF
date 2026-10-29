import Foundation
import ZPDFExport
import ZPDFPDFKitBridge

/// File ▸ Export Drawing ▸ Export Marked PDF…, structure-preserving (NL-PDF-05).
///
/// The rebuilt flatten replays every page into a new document, so the drawing set's sheet
/// bookmarks, callout links, page labels and layers do not survive it. This path appends the
/// markup ink to the drawing's own bytes instead — the layered export's writer without the layer
/// — and then has qpdf, in the repair service, rewrite the result once: compact, and with no
/// earlier revision a PDF tool could peel the markups back off.
///
/// It runs only when the result would be the same picture the rebuilt path draws: the drawing
/// opens without a password, no layer is hidden in the Navigator (a rebuilt page applies that
/// visibility; an appended one keeps the file's own), and an arranged set's composed file kept
/// the drawing's layer definitions. Anything else falls back to the rebuilt writer, and the
/// export report says which path ran and why.
extension FlattenedDrawingExport {

    /// Which writer produced the marked file.
    enum MarkedPath: Equatable, Sendable {
        /// Ink appended to the drawing; `rewritten` when qpdf then rewrote it whole.
        case appended(rewritten: Bool)
        /// Pages rebuilt by the flatten writer, for the reason given.
        case rebuilt(reason: String)
    }

    /// Writes the marked shape, structure-preserving when it can.
    static func writeMarked(
        job: Job,
        content: (any FlattenPageContentDrawing)?,
        document: ZenitPDFProjectDocument,
        to url: URL,
        set: DrawingSetOutput? = nil
    ) async throws -> (report: Report, path: MarkedPath) {
        func rebuilt(_ reason: String) throws -> (Report, MarkedPath) {
            (try write(shape: .flattened, job: job, content: content, to: url), .rebuilt(reason: reason))
        }
        guard let drawing = document.drawing else { return try rebuilt("no drawing file") }
        // A project of several drawings: the ink goes onto the composed set, which this export
        // made a moment ago (no password, labels carried), so there is no original to verify.
        let sourceURL = set?.url ?? drawing.url
        // For a set as for the drawing as filed (it5r V-018): the composed file keeps the
        // drawing's own layer defaults at best, so appending onto it would show the layers the
        // Navigator hides — and then clear the note that says so.
        if document.layerVisibility.hasLayers, !document.layerVisibility.matchesDocumentDefault {
            return try rebuilt(NSLocalizedString(
                "layers hidden in the Navigator are applied only when the pages are rebuilt",
                comment: "Marked export: why the structure-preserving path was not used (hidden layers)"
            ))
        }
        // A set PDFKit composed (a turned or renumbered sheet) lost the drawing's layer
        // definitions (`DrawingSetOutput.lostLayerDefinitions`): the appended file would have no
        // layers while its note said they were kept. The rebuilt pages are drawn from the
        // drawing itself, with the project's layer visibility (it5r V-018).
        if let set, set.lostLayerDefinitions {
            return try rebuilt(NSLocalizedString(
                "the drawing's layer definitions could not be carried into the arranged set",
                comment: "Marked export: why the structure-preserving path was not used (the composed set lost /OCProperties)"
            ))
        }
        guard set != nil || document.drawingPassword == nil else {
            return try rebuilt(NSLocalizedString(
                "the drawing is password-protected",
                comment: "Marked export: why the structure-preserving path was not used (encrypted)"
            ))
        }
        let marked = job.pages.filter { !$0.markups.isEmpty }
        guard !marked.isEmpty else {
            return try rebuilt(NSLocalizedString(
                "there are no markups to add",
                comment: "Marked export: why the structure-preserving path was not used (no markups)"
            ))
        }

        // Staged in a private folder on the destination's volume, never beside `url`: a
        // sandboxed save panel grants the chosen file and nothing next to it, so the hidden
        // sibling this used to write was refused and every marked export fell back to the
        // rebuilt pages (V-051).
        var stagingFolder: URL?
        defer { if let stagingFolder { try? FileManager.default.removeItem(at: stagingFolder) } }
        let staging: URL
        let outcome: LayeredExportOutcome
        do {
            let folder = try StagedFileReplacement.stagingDirectory(appropriateFor: url)
            stagingFolder = folder
            staging = folder.appendingPathComponent("zpdf-marked-\(UUID().uuidString).pdf")
            if set == nil {
                let source = try Data(contentsOf: drawing.url, options: .mappedIfSafe)
                try StandardAnnotationExport.verifyBegins(source, with: drawing.digest)
            }
            // Every sheet, not only the marked ones: a sheet whose markups are hidden or kept off
            // paper still carries the annotations an earlier Save Markups into PDF wrote for
            // them, and the exporter leaves those out of every sheet it is given, as the rebuilt
            // pages do — and keeps a colleague's, as the canvas does (L-23).
            outcome = try LayeredMarkupExporter().write(
                source: sourceURL,
                pages: job.pages,
                to: staging,
                options: .init(
                    asSwitchableLayer: false,
                    supersededAnnotationNames: await ZenitAnnotationSupersession.names(for: document)
                ),
                protecting: [sourceURL]
            )
        } catch {
            return try rebuilt(reason(error))
        }

        var rewritten = false
        do {
            _ = try await DocumentCopyTransform.run(
                source: staging, password: nil, output: url, choices: .init(reducesSize: true, downsamplesPictures: false)
            )
            rewritten = true
        } catch {
            // The repair service is unavailable (a test process): the appended file is still the
            // marked drawing, and the report says it can be peeled back.
            try StagedFileReplacement.place(staging, at: url)
        }
        var report = Report()
        report.rejectedMarkupCount = outcome.rejectedMarkupCount
        return (report, .appended(rewritten: rewritten))
    }

    /// Why the appended path could not run, as a sentence: an export refusal's own words, a
    /// system error's description — never the raw error dump the report used to quote (V-051).
    ///
    /// The appended path throws three kinds: `ExportError` (its description), `PDFFlattenError`
    /// (a `LocalizedError` whose description is its own words — before it was one, this read
    /// "The operation couldn't be completed. (ZPDFExport.PDFFlattenError error 1.)"), and the
    /// system's file errors, which the export layer quotes by `localizedDescription` too.
    static func reason(_ error: any Error) -> String {
        if let refusal = error as? ExportError { return refusal.description }
        if let localized = error as? any LocalizedError, let description = localized.errorDescription { return description }
        return error.localizedDescription
    }

    /// What the report says about the path.
    static func markedPathNote(_ path: MarkedPath) -> String {
        switch path {
        case .appended(rewritten: true):
            NSLocalizedString(
                "The drawing's bookmarks, links, page labels and layers are kept.",
                comment: "Marked export note: structure-preserving path, rewritten"
            )
        case .appended(rewritten: false):
            NSLocalizedString(
                "The drawing's bookmarks, links, page labels and layers are kept. The markups were added after the drawing's original bytes, so a PDF tool could take them off again.",
                comment: "Marked export note: structure-preserving path, not rewritten"
            )
        case let .rebuilt(reason):
            String(
                format: NSLocalizedString(
                    "The pages were rebuilt (%@), so the drawing's bookmarks and links are not in the file.",
                    comment: "Marked export note: rebuilt path; the reason"
                ),
                reason
            )
        }
    }
}
