import Foundation
import Testing
import ZPDFAppCore
import ZPDFUIPresentation

/// NL-AUTO-22: the optional on-device language layer sits behind an availability check, always
/// has the rules as its fallback, and only ever names a field.
struct OnDeviceLanguageTests {

    @Test("The rules label title-block text by shape")
    func rules() async {
        let labels = await RuleBasedTitleBlockClassifier().classify([
            "A-101", "PLAN 1", "Skala 1:100", "2026-09-23", "Rev B", "12"
        ])
        #expect(labels == [.sheetNumber, .sheetTitle, .scale, .date, .revision, .other])
    }

    @Test("Asked for the rules, every Mac gets the rules; the model is only ever an optional upgrade")
    func fallback() {
        let rules = OnDeviceLanguage.titleBlockClassifier(preferModel: false)
        #expect(!rules.isModelBacked)
        let chosen = OnDeviceLanguage.titleBlockClassifier()
        switch OnDeviceLanguage.availability {
        case .available: #expect(chosen.isModelBacked)
        case .frameworkMissing, .modelUnavailable: #expect(!chosen.isModelBacked)
        }
    }

    /// A classifier that names the fields it is told to, to prove the reader uses the label and
    /// never anything the classifier could invent.
    struct Scripted: TitleBlockFieldClassifying {
        let answer: [TitleBlockField]
        var isModelBacked: Bool { true }
        func classify(_ texts: [String]) async -> [TitleBlockField] { Array(answer.prefix(texts.count)) }
    }

    @Test("With no label in the title block, the classified sheet number and title are proposed, weakly")
    func classifiedReading() async {
        let box = PDFRectValue(x: 0, y: 0, width: 1191, height: 842)
        let lines = [
            RecognisedTextLine(text: "K-20", boundsInPageSpace: PDFRectValue(x: 1000, y: 60, width: 60, height: 14)),
            RecognisedTextLine(text: "FASAD NORR", boundsInPageSpace: PDFRectValue(x: 1000, y: 100, width: 120, height: 14))
        ]
        let rules = await TitleBlockReader().readAutomatically(
            pageIndex: 0, pageBox: box, lines: lines, classifier: RuleBasedTitleBlockClassifier()
        )
        #expect(rules.number == "K-20" && rules.title == "FASAD NORR")
        #expect(rules.source == .classified && rules.confidence == TitleBlockReader.classifiedConfidence)
        let model = await TitleBlockReader().readAutomatically(
            pageIndex: 0, pageBox: box, lines: lines, classifier: Scripted(answer: [.sheetNumber, .other])
        )
        // Lines reach the classifier top to bottom: "FASAD NORR" first. The text comes from the
        // drawing; the classifier only chose which line is the number.
        #expect(model.number == "FASAD NORR")
        #expect(model.source == .onDeviceModel)
    }
}
