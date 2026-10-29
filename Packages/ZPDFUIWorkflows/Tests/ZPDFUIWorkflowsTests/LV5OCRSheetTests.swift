import Foundation
import Testing
import ZPDFDesignSystem
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Live test 5: the recognition sheet's closing line (L-20b), its language names (L-27) and
/// its dismiss action (L-30).
@Suite("Read Text from Scanned Pages sheet, live test 5", .workflowsTierSerialised)
@MainActor
struct LV5OCRSheetTests {

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

    /// Runs the model through Start → per-page reports → finish, as the host does.
    private static func finishedRun(_ statuses: [OCRPageStatus]) -> OCRRunModel {
        let model = OCRRunModel(pages: pages(statuses.count), preferredLanguages: ["en-US"])
        model.rangeSelection = .allPages
        model.start()
        for (page, status) in zip(model.pages, statuses) {
            model.record(OCRPageStatusSummary(
                id: page.id,
                pageLabel: page.label,
                pageIndex: page.index,
                status: status,
                confidence: status == .indexed ? 0.9 : nil,
                recognizedWordCount: status == .indexed ? 12 : 0
            ))
        }
        model.finish()
        return model
    }

    // MARK: - L-20b

    @Test("L-20b: a run where every page found no text says no words were found")
    func noTextAnywhereSaysSo() {
        let model = Self.finishedRun([.noTextFound, .noTextFound])
        #expect(model.phase == .finished)
        // Old: always "Finished. Recognised words are searchable now, and are still a search aid
        // rather than a transcription." — over a run that recognised nothing.
        #expect(model.finishedOutcome == .noWordsFound)
        #expect(model.finishedOutcome.message.contains("No words were found"))
        #expect(!model.finishedOutcome.message.contains("searchable now"))
        #expect(model.finishedOutcome.displaySeverity == .warning)
    }

    @Test("L-20b: a run that read words says they are searchable")
    func wordsFoundSaySearchable() {
        let model = Self.finishedRun([.noTextFound, .indexed])
        #expect(model.finishedOutcome == .wordsFound)
        #expect(model.finishedOutcome.message.hasPrefix("Finished. Recognised words are searchable now"))
        #expect(model.finishedOutcome.displaySeverity == .success)
    }

    @Test("L-20b: a run that skipped every page for its real text says none was read")
    func everyPageSkippedSaysNoneRead() {
        let model = Self.finishedRun([.skippedHasText, .skippedHasText])
        #expect(model.finishedOutcome == .allPagesSkipped)
        #expect(model.finishedOutcome.message.contains("none was read"))
        #expect(!model.finishedOutcome.message.contains("searchable now"))
        // Skipped and empty pages together: nothing was recognised anywhere.
        #expect(Self.finishedRun([.skippedHasText, .noTextFound]).finishedOutcome == .noWordsFound)
    }

    // MARK: - L-27

    @Test("L-27: a recognition identifier whose region is not a region is named by its language")
    func languageNameFallsBackToTheLanguage() {
        let english = Locale(identifier: "en_US")
        // Old: `localizedString(forIdentifier:)` has no name for "vi-VT", so the grid showed the
        // raw code "vi-VT".
        #expect(OCRLanguage.displayName(forIdentifier: "vi-VT", in: english) == "Vietnamese")
        // A real identifier keeps its full name.
        #expect(OCRLanguage.displayName(forIdentifier: "sv-SE", in: english) == "Swedish (Sweden)")
        // Nothing to name: the identifier stands, rather than an empty checkbox.
        #expect(OCRLanguage.displayName(forIdentifier: "xx-YY", in: english) == "xx-YY")
    }

    @Test("L-27: the grid's language names come from the naming function")
    func gridUsesTheNamingFunction() {
        let language = OCRLanguage(id: "vi-VT")
        #expect(language.displayName == OCRLanguage.displayName(forIdentifier: "vi-VT", in: .current))
        #expect(language.displayName != "vi-VT")
    }

    // MARK: - L-30

    @Test("L-30: the sheet has one dismiss action in every phase, and the host adds no Done")
    func oneDismissAction() {
        // Old: the footer's Close plus the host chrome's Done, both ending the sheet.
        #expect(OCRRunSheet.wantsHostDoneButton == false)

        let idle = OCRRunSheet.footerActions(phase: .idle, offersBackground: true)
        #expect(idle == [.close, .startReading])
        let finished = OCRRunSheet.footerActions(phase: .finished, offersBackground: true)
        #expect(finished == [.close, .startReading])
        // While reading: Continue in Background and Stop Reading stay.
        let running = OCRRunSheet.footerActions(phase: .running, offersBackground: true)
        #expect(running == [.close, .continueInBackground, .stopReading])
        let runningNoBackground = OCRRunSheet.footerActions(phase: .running, offersBackground: false)
        #expect(runningNoBackground == [.close, .stopReading])
        let cancelling = OCRRunSheet.footerActions(phase: .cancelling, offersBackground: true)
        #expect(cancelling == [.close, .stopReading])

        let phases: [OCRRunPhase] = [.idle, .running, .cancelling, .finished, .cancelled]
        for phase in phases {
            let actions = OCRRunSheet.footerActions(phase: phase, offersBackground: true)
            #expect(actions.filter { $0 == .close }.count == 1, "\(phase)")
        }
    }
}
