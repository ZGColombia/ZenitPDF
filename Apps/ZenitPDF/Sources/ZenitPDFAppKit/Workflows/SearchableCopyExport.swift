import AppKit
import Foundation
import ZPDFAppCore
import ZPDFExport
import ZPDFUIPresentation

/// File ▸ Export Drawing ▸ Save Searchable Copy… (NL-PDF-13).
///
/// The words Read Text from Scanned Pages… recognised, written into a copy of the drawing as an
/// invisible text layer (``ZPDFExport/SearchableTextLayerWriter``), so the scan is searchable
/// and selectable in every reader. The copy is the drawing's bytes plus an incremental update;
/// the drawing itself is never written.
@MainActor
enum SearchableCopyExport {

    static let panelIdentifier = "drawing.searchableCopyPanel"
    static let resultNoteID = UUID(uuidString: "0B7E3F6A-2C19-4D8B-A5E4-91C6D2F7B803")!

    /// Why there is nothing to write.
    enum Refusal: LocalizedError, Equatable {
        case nothingRecognised

        var errorDescription: String? {
            NSLocalizedString(
                "No text has been recognised on this drawing yet. Choose Read Text from Scanned Pages… first.",
                comment: "Searchable copy refusal: no OCR tokens"
            )
        }
    }

    /// The save panel's message; in a project of several drawings it names the one drawing the
    /// copy is made of (W-022), as Clean Up Scanned Sheets does (V-053).
    static func panelMessage(for document: ZenitPDFProjectDocument) -> String {
        let base = NSLocalizedString(
            "Save a copy of the drawing whose recognised text any PDF reader can search. The drawing itself is not changed.",
            comment: "Searchable copy save panel message"
        )
        return document.primaryDrawingOnlySentence().map { base + " " + $0 } ?? base
    }

    /// The writer's pages for a set of recognised tokens. Pure.
    static func pages(
        tokens: [Int: [DocumentSearchIndex.RecognisedWord]],
        rotations: [Int: Int]
    ) -> [SearchableTextLayerWriter.Page] {
        tokens.keys.sorted().map { index in
            SearchableTextLayerWriter.Page(
                sourcePageIndex: index,
                rotation: rotations[index] ?? 0,
                tokens: (tokens[index] ?? []).map { .init(text: $0.text, bounds: $0.bounds) }
            )
        }
    }

    /// Writes the searchable copy of the document's drawing to `destination`.
    static func write(for document: ZenitPDFProjectDocument, to destination: URL) async throws -> SearchableTextLayerWriter.Outcome {
        guard let drawing = document.drawing else { throw FlattenedDrawingExport.PreparationFailure.noDocument }
        // Nothing the document is made of — its drawings, its revisions, its own file (V-021).
        try DerivedCopyGuard.refuseIfDocumentFile(destination, document: document)
        guard let index = document.searchIndex else { throw FlattenedDrawingExport.PreparationFailure.noDocument }
        let tokens = try await index.recognisedWords()
        guard tokens.values.contains(where: { !$0.isEmpty }) else { throw Refusal.nothingRecognised }
        var rotations: [Int: Int] = [:]
        for page in drawing.pages { rotations[page.index] = page.rotation.rawValue }
        let source = try Data(contentsOf: drawing.url, options: .mappedIfSafe)
        try StandardAnnotationExport.verifyBegins(source, with: drawing.digest)
        let produced = try SearchableTextLayerWriter().data(source: source, pages: pages(tokens: tokens, rotations: rotations))
        try SaveMarkupsIntoPDF.atomicallyReplace(destination, with: produced.data)
        ExportCompletion.remember(destination, document: document)
        return produced.outcome
    }

    /// The note after the write. `leftOut` is the sentence naming the one drawing written in a
    /// project of several drawings (W-022): the copy is the primary drawing's alone.
    static func resultNote(for outcome: SearchableTextLayerWriter.Outcome, destination: URL, leftOut: String? = nil, now: Date = Date()) -> AppWarning {
        let done = String(
            format: NSLocalizedString(
                "%1$d recognised words on %2$d pages can now be found and selected in any PDF reader. The drawing looks exactly as before.",
                comment: "Searchable copy note; word count, page count"
            ),
            outcome.wordsWritten, outcome.pagesWithText
        )
        return AppWarning(
            id: resultNoteID,
            severity: .info,
            title: String(
                format: NSLocalizedString("Saved “%@”", comment: "Searchable copy headline; the file name"),
                destination.lastPathComponent
            ),
            message: leftOut.map { done + " " + $0 } ?? done,
            source: NSLocalizedString("Export", comment: "Warning source for print and export"),
            isDismissible: true,
            timestamp: now
        )
    }
}

extension SearchableCopyExport {

    /// Whether Read Text from Scanned Pages… has recognised any word on the drawing — the one
    /// thing a searchable copy is made of.
    static func hasRecognisedText(_ document: ZenitPDFProjectDocument) async -> Bool {
        guard let index = document.searchIndex, let tokens = try? await index.recognisedWords() else { return false }
        return tokens.values.contains { !$0.isEmpty }
    }

    /// File ▸ Export Drawing ▸ Save Searchable Copy…: the refusal first when there is nothing to
    /// write, the save panel only when there is (L-52).
    ///
    /// The panel used to come first: a person chose a name and a folder, pressed Save, and only
    /// then read "No text has been recognised on this drawing yet" — with nothing written. The
    /// write still refuses on its own (``write(for:to:)``), for a caller that skips this.
    static func present(for document: ZenitPDFProjectDocument, window: NSWindow?) async {
        guard document.drawing != nil else { return }
        guard await hasRecognisedText(document) else {
            ZenitErrorPresenter.present(Refusal.nothingRecognised, in: window)
            return
        }
        chooseDestination(for: document, window: window)
    }

    /// The save panel, then the write and its note.
    static func chooseDestination(for document: ZenitPDFProjectDocument, window: NSWindow?) {
        guard let drawing = document.drawing else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = SearchableCopyExport.panelMessage(for: document)
        panel.nameFieldStringValue = drawing.url.deletingPathExtension().lastPathComponent
            + " — " + NSLocalizedString("Searchable", comment: "Searchable copy file-name suffix") + ".pdf"
        ZenitModalPresenter.runSavePanel(panel, identifier: SearchableCopyExport.panelIdentifier, sheetedOn: window) { answer in
            guard let url = answer.firstURL else { return }
            Task { @MainActor in
                do {
                    let outcome = try await SearchableCopyExport.write(for: document, to: url)
                    document.core?.document.post(SearchableCopyExport.resultNote(
                        for: outcome, destination: url, leftOut: document.primaryDrawingOnlySentence()
                    ))
                } catch {
                    ZenitErrorPresenter.present(error, in: window)
                }
            }
        }
    }
}

extension ProjectWindowController {

    /// File ▸ Export Drawing ▸ Save Searchable Copy….
    func saveSearchableCopy(for document: ZenitPDFProjectDocument) {
        guard document.drawing != nil, let window else { return }
        Task { @MainActor in await SearchableCopyExport.present(for: document, window: window) }
    }
}
