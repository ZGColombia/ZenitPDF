import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// 1.0.1: a page macOS text recognition could not read says so. The host mapped every skip
/// reason the engine gave to "No text found", so a page Vision threw on, a page that could not
/// be rendered and a page skipped for its real text were all reported as read and blank, with a
/// warning glyph.
@Suite("Read Text from Scanned Pages: a page macOS could not read (1.0.1)", .workflowsTierSerialised)
@MainActor
struct OCRCouldNotBeReadStatusTests {

    private static func pages(_ count: Int) -> [PageDescriptor] {
        (0..<count).map { index in
            PageDescriptor(
                id: UUID(), index: index, label: "A-\(101 + index)",
                mediaBox: PDFRectValue(x: 0, y: 0, width: 1190, height: 842),
                cropBox: PDFRectValue(x: 0, y: 0, width: 1190, height: 842),
                rotation: .degrees0
            )
        }
    }

    /// Old output: `.noTextFound` — "No text found", "This page was read and nothing legible was
    /// found on it".
    @Test("The engine's recognition failure is its own status, not No text found")
    func recognitionFailureHasItsOwnStatus() {
        let status = OCRPageStatus(recognitionSkipReason: "recognitionFailed")
        #expect(status == .couldNotBeRead)
        #expect(status != .noTextFound)
        #expect(status.displayName != OCRPageStatus.noTextFound.displayName)
        #expect(status.explanation.contains("could not be read this time"))
        #expect(status.explanation.contains("Try reading it again"))
        // An earlier run's words stay searchable (BH-205), so the explanation must not say that
        // search cannot find the page's words, nor that it was read.
        #expect(status.explanation.contains("earlier reading found on it stay searchable"))
        #expect(!status.explanation.contains("search cannot find"))
        #expect(!status.explanation.contains("was read"))
        #expect(status.displaySeverity == .danger)
        #expect(status.isDone, "a page that came back counts as done for progress")
    }

    /// Old output for "hasTextLayer" and "notRenderable": `.noTextFound`, "This page was read and
    /// nothing legible was found on it". Nothing produced `.skippedHasText` (BH-310, IM-150).
    @Test("Every engine skip reason maps to the status that says what happened to the page")
    func everySkipReasonMapsToItsStatus() {
        #expect(OCRPageStatus(recognitionSkipReason: nil) == .indexed)
        #expect(OCRPageStatus(recognitionSkipReason: "nothingRecognised") == .noTextFound)
        #expect(OCRPageStatus(recognitionSkipReason: "hasTextLayer") == .skippedHasText)
        #expect(OCRPageStatus(recognitionSkipReason: "notRenderable") == .couldNotBeRead)
        #expect(OCRPageStatus(recognitionSkipReason: "recognitionFailed") == .couldNotBeRead)
    }

    @Test("The sheet shows the page that could not be read on its own row, outside the No text found count")
    func sheetShowsThePage() throws {
        let model = OCRRunModel(pages: Self.pages(2), preferredLanguages: ["en-US"])
        model.rangeSelection = .allPages
        model.start()
        let read = model.pages[0], failed = model.pages[1]
        model.record(OCRPageStatusSummary(
            id: read.id, pageLabel: read.label, pageIndex: read.index,
            status: OCRPageStatus(recognitionSkipReason: nil), confidence: 0.9, recognizedWordCount: 12
        ))
        model.record(OCRPageStatusSummary(
            id: failed.id, pageLabel: failed.label, pageIndex: failed.index,
            status: OCRPageStatus(recognitionSkipReason: "recognitionFailed")
        ))
        #expect(model.completedPageCount == 2)
        #expect(model.progressFraction == 1)
        model.finish()

        let row = try #require(model.pageResults.first { $0.id == failed.id })
        #expect(row.status == .couldNotBeRead)
        #expect(row.accessibilityLabel.contains(OCRPageStatus.couldNotBeRead.displayName))
        #expect(model.pagesWithoutText.isEmpty)
        // Counted on its own, for the sheet's "Could not be read" pill.
        #expect(model.pagesNotRead.map(\.id) == [failed.id])
        #expect(model.phase == .finished)
        // Old: `.wordsFound`, "Recognised words are searchable now", with no word of the failure.
        #expect(model.finishedOutcome == .pagesNotRead)
    }

    @Test("A run whose every page was skipped for its real text says so, and counts them")
    func skippedPagesAreCountedAsSkipped() {
        let model = OCRRunModel(pages: Self.pages(3), preferredLanguages: ["en-US"])
        model.rangeSelection = .allPages
        model.start()
        for page in model.pages {
            model.record(OCRPageStatusSummary(
                id: page.id, pageLabel: page.label, pageIndex: page.index,
                status: OCRPageStatus(recognitionSkipReason: "hasTextLayer")
            ))
        }
        model.finish()

        #expect(model.pagesSkippedForText.count == model.pages.count)
        #expect(model.pagesWithoutText.isEmpty)
        #expect(model.pagesNotRead.isEmpty)
        #expect(model.finishedOutcome == .allPagesSkipped)
    }
}
