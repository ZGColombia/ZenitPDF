import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// BH-310, BH-843, BH-844, IM-148, IM-149, IM-150, IM-151 and IM-152: recognition statuses,
/// progress and result grouping tell the truth.
@Suite("Search and OCR, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2SearchOCRTests {

    private func pages(_ count: Int) -> [PageDescriptor] {
        (0..<count).map { index in
            PageDescriptor(
                id: UUID(), index: index, label: "A-\(101 + index)",
                mediaBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
                cropBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
                rotation: .degrees0
            )
        }
    }

    /// Old output: no such status existed; the host reported a skipped page as `.noTextFound`
    /// ("This page was read and nothing legible was found on it", warning glyph), and
    /// progressFraction stopped at 0.6 for 6 read + 4 skipped pages.
    @Test("A page skipped for its text layer says so and counts as done")
    func skippedPagesAreDone() {
        let all = pages(10)
        let model = OCRRunModel(pages: all, preferredLanguages: ["en-US"])
        model.start()
        for (offset, page) in all.enumerated() {
            model.record(OCRPageStatusSummary(
                id: page.id, pageLabel: page.label, pageIndex: page.index,
                status: offset < 4 ? .skippedHasText : .indexed, confidence: offset < 4 ? nil : 0.9
            ))
        }
        #expect(model.progressFraction == 1)
        #expect(model.pagesSkippedForText.count == 4)
        #expect(model.pagesWithoutText.isEmpty)
        let skipped = OCRPageStatus.skippedHasText
        #expect(skipped.displaySeverity == .neutral)
        #expect(skipped.explanation.contains("already carries real text"))
        #expect(skipped.displayName != OCRPageStatus.noTextFound.displayName)
    }

    @Test("Preferred languages seed the selection, matched by code, falling back to US English")
    func languagesFromPreferences() {
        let offered = OCRLanguage.commonLanguages
        #expect(OCRRunModel.defaultLanguageIDs(available: offered, preferred: ["sv-SE", "en-US"]) == ["sv-SE", "en-US"])
        #expect(OCRRunModel.defaultLanguageIDs(available: offered, preferred: ["sv", "de_AT"]) == ["sv-SE", "de-DE"])
        #expect(OCRRunModel.defaultLanguageIDs(available: offered, preferred: ["ja-JP"]) == ["en-US"])
        let model = OCRRunModel(pages: pages(1), preferredLanguages: ["sv-SE", "en-US"])
        #expect(model.selectedLanguageIDs == ["sv-SE", "en-US"])
        let remembered = OCRRunModel(pages: pages(1), selectedLanguageIDs: ["fi-FI"], preferredLanguages: ["sv-SE"])
        #expect(remembered.selectedLanguageIDs == ["fi-FI"], "the host's last-run choice wins")
    }

    /// Old output: "1-3, x7" read pages 1-3 and said nothing about "x7".
    @Test("A page-list fragment that names no page is said back")
    func rejectedFragmentsAreNamed() {
        let model = OCRRunModel(pages: pages(5), preferredLanguages: ["en-US"])
        model.rangeSelection = .custom("")
        model.customRangeText = "1-3, x7, 9, 5-2"
        #expect(model.resolvedPageIndices == IndexSet(0...4))
        #expect(model.rejectedRangeFragments == ["x7", "9"])
        model.rangeSelection = .allPages
        #expect(model.rejectedRangeFragments.isEmpty)
    }

    @Test("Results inserted in any order stay sorted, and a repeat replaces")
    func resultsStaySorted() {
        let all = pages(500)
        let model = OCRRunModel(pages: all, preferredLanguages: ["en-US"])
        for page in all.reversed() {
            model.record(OCRPageStatusSummary(id: page.id, pageLabel: page.label, pageIndex: page.index, status: .indexing))
        }
        for page in all.shuffled() {
            model.record(OCRPageStatusSummary(id: page.id, pageLabel: page.label, pageIndex: page.index, status: .indexed))
        }
        #expect(model.pageResults.count == 500)
        #expect(model.pageResults.map(\.pageIndex) == Array(0..<500))
        #expect(model.pageResults.allSatisfy { $0.status == .indexed })

        // Measurement against the old append-and-re-sort, for the status file.
        let clock = ContinuousClock()
        var old: [OCRPageStatusSummary] = []
        let oldTime = clock.measure {
            for page in all.reversed() {
                old.append(OCRPageStatusSummary(id: page.id, pageLabel: page.label, pageIndex: page.index, status: .indexed))
                old.sort { $0.pageIndex < $1.pageIndex }
            }
        }
        let fresh = OCRRunModel(pages: all, preferredLanguages: ["en-US"])
        let newTime = clock.measure {
            for page in all.reversed() {
                fresh.record(OCRPageStatusSummary(id: page.id, pageLabel: page.label, pageIndex: page.index, status: .indexed))
            }
        }
        print("IM-151 measurement: 500 records, append+sort \(oldTime) vs binary insert \(newTime)")
        #expect(fresh.pageResults.map(\.pageIndex) == old.map(\.pageIndex))
    }

    @Test("Progress says which page and about how long is left; a run can go to the background")
    func estimateAndBackground() {
        let all = pages(40)
        let model = OCRRunModel(pages: all, preferredLanguages: ["en-US"])
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        model.now = { clock }
        #expect(model.onContinueInBackground == nil)
        model.start()
        #expect(model.progressEstimate == nil, "nothing to estimate from yet")
        for page in all.prefix(11) {
            model.record(OCRPageStatusSummary(id: page.id, pageLabel: page.label, pageIndex: page.index, status: .indexed))
        }
        clock = Date(timeIntervalSinceReferenceDate: 44)   // 4 s a page, 29 pages left
        let estimate = model.progressEstimate ?? ""
        #expect(estimate.hasPrefix("Page 12 of 40"))
        #expect(estimate.contains("2") && estimate.contains("left"))

        model.continueInBackground()
        #expect(!model.isInBackground, "no host hook, no background")
        var backgrounded = false
        model.onContinueInBackground = { backgrounded = true }
        model.continueInBackground()
        #expect(backgrounded && model.isInBackground)
        #expect(model.phase == .running, "backgrounding does not cancel")
    }
}

/// BH-311 and BH-312: Split Canvas page sync and the single-pane layout.
@Suite("Split Canvas, bug hunt 2", .workflowsTierSerialised)
@MainActor
struct BugHunt2SplitCanvasTests {

    private func page(_ index: Int, _ label: String) -> PageDescriptor {
        PageDescriptor(
            id: UUID(), index: index, label: label,
            mediaBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
            cropBox: PDFRectValue(x: 0, y: 0, width: 842, height: 595),
            rotation: .degrees0
        )
    }

    /// Old output: pane 2 read pageLabel "A-104", pageIndex 3, while its pageID stayed B-101,
    /// and an empty pane was given the label "A-104" too.
    @Test("Page sync never writes another document's label over a follower's own page")
    func followerKeepsItsOwnPage() {
        let controller = SplitCanvasController(layout: .grid, syncOptions: .locked)
        let documentA = UUID(), documentB = UUID()
        let a104 = page(3, "A-104")
        let b101 = page(0, "B-101")
        controller.setContent(documentID: documentA, documentTitle: "Rev A", page: page(0, "A-101"), in: .first)
        controller.setContent(documentID: documentB, documentTitle: "Rev B", page: b101, in: .second)
        controller.setPage(a104, in: .first)
        #expect(controller.pane(.second).pageID == b101.id)
        #expect(controller.pane(.second).pageLabel == "B-101", "no lookup, no move — and no foreign label")
        #expect(controller.pane(.second).pageIndex == 0)
        #expect(controller.pane(.third).pageLabel.isEmpty, "an empty pane gets no label")
        #expect(controller.pane(.third).pageID == nil)
    }

    /// Old output: the layout switch sat in the group disabled for `.single`, so a one-pane
    /// split could never gain a pane.
    @Test("The single layout can still switch layout; only sync waits for a second pane")
    func singleLayoutCanGrow() {
        let controller = SplitCanvasController(layout: .single)
        #expect(!controller.syncControlsAreEnabled)
        controller.setLayout(.twoColumns)
        #expect(controller.layout == .twoColumns)
        #expect(controller.syncControlsAreEnabled)
    }
}
