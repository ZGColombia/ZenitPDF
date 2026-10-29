import AppKit
import Foundation
import SwiftUI
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIWorkflows

/// NL-AUTO-04: name every sheet from its title block. The person boxes the sheet number, and
/// optionally the title, on one sheet; the boxes are anchored to the nearest page corner and read
/// on every sheet of that paper size; sheets of another size are read by the labels near their
/// corners (with the on-device model's help on macOS 26 when it is available, NL-AUTO-22). A
/// review lists every reading, editable, before one undoable step names the sheets through the
/// documents feature's `setSheetIdentities` — which never overwrites a name a person typed.
extension ProjectWindowController {

    /// How the review reaches the screen, returning its dismissal. A test injects a capture.
    static var sheetNameReviewPresenter: (@MainActor (SheetNameReviewModel, NSWindow?) -> () -> Void) = { model, window in
        guard let window else { return {} }
        let host = NSHostingController(rootView: SheetNameReviewView(model: model))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled, .resizable]
        // Through the one modal door: recorded, and refused on a visible window in a
        // process with no user (R-039).
        ZenitModalPresenter.beginSheet(panel, on: window, identifier: "automation.sheetNameReview") {}
        return { [weak window, weak panel] in
            guard let window, let panel else { return }
            window.endSheet(panel)
        }
    }

    func beginSheetNaming(for document: ZenitPDFProjectDocument) {
        guard let canvas = canvasController(for: document) else { return }
        // A reading already under way is said, not started twice (L-53).
        guard !SheetNamingRun.reading.contains(document.documentIdentity) else {
            document.core?.status.setActiveToolNote(Self.sheetNamingStartedNote)
            return
        }
        document.core?.status.setActiveToolNote(NSLocalizedString(
            "Drag a box around the sheet number in the title block.",
            comment: "Status note after Name Sheets from Title Block…"
        ))
        beginRegionCapture(
            on: canvas,
            for: document,
            cancelNote: NSLocalizedString("Sheet naming cancelled.", comment: "Status note when sheet naming is cancelled")
        ) { [weak self, weak document, weak canvas] numberRect in
            guard let self, let document, let canvas else { return }
            // The title is optional: Escape on the second box names by number only.
            document.core?.status.setActiveToolNote(NSLocalizedString(
                "Now drag a box around the sheet title, or press Esc to use the number only.",
                comment: "Status note asking for the optional title box"
            ))
            // The second box (or Escape) ends the capture: both handlers go, so a later drag
            // or Escape on the canvas is not read as another title box (L-53).
            canvas.onSnippetRegion = { [weak self, weak document, weak canvas] titleRect in
                canvas?.onSnippetRegion = nil
                canvas?.onSnippetRegionCancelled = nil
                guard let self, let document else { return }
                self.readSheetNames(for: document, numberRect: numberRect, titleRect: titleRect)
            }
            canvas.onSnippetRegionCancelled = { [weak self, weak document, weak canvas] in
                canvas?.onSnippetRegion = nil
                canvas?.onSnippetRegionCancelled = nil
                guard let self, let document else { return }
                self.readSheetNames(for: document, numberRect: numberRect, titleRect: nil)
            }
            canvas.beginSnippetRegion()
        }
    }

    /// "Sheet names are still being read." — Name Sheets chosen again while a reading runs.
    static var sheetNamingStartedNote: String {
        NSLocalizedString(
            "Sheet names are still being read. The review opens when every sheet is read.",
            comment: "Status note when Name Sheets from Title Block is chosen while a reading runs"
        )
    }

    /// The note the moment the boxes are in, before the set's size is known (L-53).
    static var sheetNamingReadingNote: String {
        NSLocalizedString(
            "Reading the sheet names…",
            comment: "Status note while Name Sheets from Title Block starts reading the sheets"
        )
    }

    /// "Reading sheet names: page 2 of 12…" — one per sheet read (L-53).
    static func sheetNamingProgressNote(done: Int, total: Int) -> String {
        String(
            format: NSLocalizedString(
                "Reading sheet names: page %1$lld of %2$lld…",
                comment: "Status note while Name Sheets from Title Block reads the sheets; the page being read, the page count"
            ),
            Int64(done), Int64(total)
        )
    }

    /// "1 sheet named." / "3 sheets named." after the review is accepted.
    static func sheetsNamedNote(_ count: Int) -> String {
        LocalizedPlural.string(
            "%lld sheets named.", count: count,
            one: NSLocalizedString("%lld sheet named.", comment: "Status note after naming one sheet"),
            other: NSLocalizedString("%lld sheets named.", comment: "Status note after naming sheets; the count")
        )
    }

    /// Reads every page and opens the review.
    ///
    /// L-53: nothing was said between the title box and the review. The status line kept asking
    /// for the title box for the minute the sheets took to read, so further drags and Escapes
    /// looked ignored and the flow looked stuck. The reading now says so at once and counts the
    /// pages as it goes, and the note is cleared when the review opens.
    func readSheetNames(for document: ZenitPDFProjectDocument, numberRect: PDFRectValue, titleRect: PDFRectValue?) {
        let identity = document.documentIdentity
        SheetNamingRun.reading.insert(identity)
        document.core?.status.setActiveToolNote(Self.sheetNamingReadingNote)
        Task { @MainActor in
            defer { SheetNamingRun.reading.remove(identity) }
            // Every sheet of the set, each read from its own drawing (NL-DOCS-04).
            let setPages = await document.core?.session.pageDescriptors ?? []
            guard let core = document.core, document.drawing != nil,
                  let currentID = core.document.currentPageID,
                  let current = setPages.first(where: { $0.id.rawValue == currentID }) else {
                document.core?.status.setActiveToolNote(nil)
                return
            }
            func box(_ page: ZPDFContracts.PageDescriptor) -> PDFRectValue {
                let visible = page.visibleBox
                return PDFRectValue(x: visible.origin.x, y: visible.origin.y, width: visible.size.width, height: visible.size.height)
            }
            let template = TitleBlockTemplate(numberRect: numberRect, titleRect: titleRect, pageBox: box(current))
            let reader = TitleBlockReader()
            let classifier = OnDeviceLanguage.titleBlockClassifier()
            var proposals: [SheetNameProposal] = []
            // Proposals are keyed by the sheet's place in the set: a PDF page index repeats
            // across the drawings of a project.
            for (position, page) in setPages.enumerated() {
                core.status.setActiveToolNote(Self.sheetNamingProgressNote(done: position + 1, total: setPages.count))
                guard let drawing = document.loadedDrawing(forPage: page.id.rawValue) else { continue }
                let lines = await PageTextLoader.embeddedLines(source: drawing.rasterSource, pageIndex: page.index)
                if var read = reader.read(template: template, pageIndex: position, pageBox: box(page), lines: lines) {
                    // No text layer in the box — a scanned sheet: read the box itself on this Mac.
                    if read.number == nil,
                       let recognised = await Self.recognisedTitleBlock(template: template, page: page, box: box(page), source: drawing.rasterSource) {
                        read = SheetNameProposal(
                            pageIndex: position, number: recognised.number, title: recognised.title,
                            source: recognised.source, confidence: recognised.confidence
                        )
                    }
                    proposals.append(read)
                } else {
                    proposals.append(await reader.readAutomatically(
                        pageIndex: position, pageBox: box(page), lines: lines, classifier: classifier
                    ))
                }
            }
            let flagged = TitleBlockReader.flaggingDuplicates(proposals)
            let rows = flagged.map { proposal in
                SheetNameReviewRow(
                    pageIndex: proposal.pageIndex,
                    pageLabel: String(format: NSLocalizedString("Page %d", comment: "A page named by its one-based number"), proposal.pageIndex + 1),
                    number: proposal.number ?? "",
                    title: proposal.title ?? "",
                    sourceText: Self.sourceText(proposal),
                    confidence: proposal.confidence
                )
            }
            let pagesByIndex = Dictionary(uniqueKeysWithValues: setPages.enumerated().map { ($0.offset, $0.element.id) })
            let sources = Dictionary(uniqueKeysWithValues: flagged.map { ($0.pageIndex, $0.source) })
            let dismiss = SheetDismissBox()
            let model = SheetNameReviewModel(
                rows: rows,
                onAccept: { outcome in
                    dismiss.dismiss()
                    var identities: [PageID: SheetIdentity?] = [:]
                    for (index, name) in outcome.names {
                        guard let pageID = pagesByIndex[index] else { continue }
                        identities[pageID] = SheetIdentity(
                            number: name.number,
                            title: name.title,
                            source: sources[index] == .templateOCR ? .titleBlockOCR : .titleBlockText
                        )
                    }
                    Task { @MainActor in
                        do {
                            // An automatic reading never overwrites a name a person typed.
                            _ = try await core.commands.perform(.setSheetIdentities(identities, overwriteManual: false))
                            await core.refresh()
                            core.status.setActiveToolNote(Self.sheetsNamedNote(identities.count))
                        } catch {
                            core.status.setActiveToolNote(String(describing: error))
                        }
                    }
                },
                onCancel: { dismiss.dismiss() }
            )
            // The reading is over and the review says what it read: the progress note goes.
            core.status.setActiveToolNote(nil)
            dismiss.dismiss = Self.sheetNameReviewPresenter(model, self.window)
        }
    }

    /// The template read from on-device recognition of the number (and title) boxes, with the
    /// recogniser's confidence folded in; `nil` when nothing is recognised.
    static func recognisedTitleBlock(
        template: TitleBlockTemplate,
        page: ZPDFContracts.PageDescriptor,
        box: PDFRectValue,
        source: PageRasterSource
    ) async -> SheetNameProposal? {
        var recognised: [RegionTextRecognizer.Line] = []
        for anchored in [template.numberRegion] + (template.titleRegion.map { [$0] } ?? []) {
            let region = anchored.resolved(on: box)
            let scale = RegionTextRecognizer.fittedPixelsPerPoint(for: region)
            guard let image = try? await source.renderRegion(
                pageIndex: page.index,
                region: PDFRect(x: region.minX, y: region.minY, width: region.size.width, height: region.size.height),
                pixelsPerPoint: scale
            ) else { continue }
            let lines = await Task.detached(priority: .userInitiated) {
                (try? RegionTextRecognizer.recognize(image: image, region: region)) ?? []
            }.value
            recognised += lines
        }
        guard !recognised.isEmpty,
              let read = TitleBlockReader().read(
                template: template, pageIndex: page.index, pageBox: box,
                lines: recognised.map(\.recognisedTextLine)
              ), let number = read.number
        else { return nil }
        let confidence = Swift.min(read.confidence, recognised.map(\.confidence).min() ?? 0)
        return SheetNameProposal(pageIndex: page.index, number: number, title: read.title, source: .templateOCR, confidence: confidence)
    }

    /// Where a reading came from, in words.
    static func sourceText(_ proposal: SheetNameProposal) -> String {
        guard proposal.number != nil else {
            return NSLocalizedString("Nothing read", comment: "Sheet name source: no text found")
        }
        switch proposal.source {
        case .template:
            return NSLocalizedString("Read in your box", comment: "Sheet name source: read inside the person's box")
        case .keywordAnchor:
            return NSLocalizedString("Read after a title-block label", comment: "Sheet name source: read after a known label")
        case .classified:
            return NSLocalizedString("Judged by its shape", comment: "Sheet name source: text judged a sheet number by its shape")
        case .onDeviceModel:
            return NSLocalizedString("Picked by the on-device model", comment: "Sheet name source: labelled by the on-device language model")
        case .templateOCR:
            return String(
                format: NSLocalizedString("Recognised in your box (%.0f %% sure)", comment: "Sheet name source: read by on-device text recognition; the confidence in percent"),
                proposal.confidence * 100
            )
        }
    }
}

/// The drawings whose sheet names are being read right now (L-53), so a second Name Sheets is
/// refused in words rather than starting a second reading behind the first.
@MainActor
enum SheetNamingRun {
    static var reading: Set<UUID> = []
}
