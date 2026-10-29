import Foundation
import Testing
@testable import ZPDFUIPresentation

/// Iteration 5, ui-presentation-measure, V-075: the Batch Apply preview a person reads before
/// stamping a whole set is grammatical for every count.
///
/// The plan's sentences resolve against `Bundle.main`, which in a test is the runner, so they take
/// ``LocalizedPlural``'s English fallback; the catalogue test below reads the shipped
/// `Plurals.stringsdict` through a bundle, the way the application does.
@Suite("Iteration 5 batch apply plurals (V-075)")
struct Iter5BatchPluralTests {

    private func plan(included: Int, skipped: Int, outOfScope: Int, noun: BatchItemNoun = .stamp) -> BatchApplyPlan {
        var decisions: [BatchPageDecision] = []
        func add(_ verdict: BatchPageDecision.Verdict) {
            decisions.append(BatchPageDecision(
                id: UUID(), index: decisions.count, label: "A-\(decisions.count + 1)", verdict: verdict,
                anchorPoint: verdict == .included ? PDFPointValue(x: 10, y: 10) : nil
            ))
        }
        for _ in 0..<included { add(.included) }
        for _ in 0..<skipped { add(.skippedAlreadyPresent) }
        for _ in 0..<outOfScope { add(.outOfScope) }
        return BatchApplyPlan(
            scope: .allPages,
            anchor: .corner(.bottomRight, insetX: 36, insetY: 36),
            skipsPagesAlreadyCarrying: true,
            decisions: decisions,
            itemNoun: noun,
            itemName: "Reviewed"
        )
    }

    /// Old output: "This will place 1 stamp(s) on 1 of 1 pages." and "Scope: All pages — 1 of 1 pages."
    @Test("One page: one stamp on one page")
    func singular() {
        let one = plan(included: 1, skipped: 0, outOfScope: 0)
        #expect(one.previewSentence == "This will place 1 stamp on 1 of 1 page.")
        #expect(one.scopeSentence == "Scope: All pages \u{2014} 1 of 1 page.")
        #expect(one.skipSentence == nil)
    }

    @Test("Many pages: stamps on pages")
    func plural() {
        let many = plan(included: 3, skipped: 2, outOfScope: 1)
        #expect(many.previewSentence == "This will place 3 stamps on 3 of 6 pages.")
        #expect(many.skipSentence == "2 pages already carry \u{201C}Reviewed\u{201D} and will be skipped.")
        #expect(many.scopeSentence == "Scope: All pages \u{2014} 5 of 6 pages.")
    }

    /// Old output: "1 page(s) already carry “Reviewed” and will be skipped."
    @Test("One skipped page reads 'page already carries'")
    func singularSkip() {
        let plan = plan(included: 2, skipped: 1, outOfScope: 0)
        #expect(plan.skipSentence == "1 page already carries \u{201C}Reviewed\u{201D} and will be skipped.")
    }

    /// Old output: "All 1 pages in scope already carry “Reviewed”, so nothing will be placed."
    @Test("Every page in scope skipped: 'The 1 page' and 'All 4 pages'")
    func allSkipped() {
        #expect(plan(included: 0, skipped: 1, outOfScope: 2).previewSentence
            == "The 1 page in scope already carries \u{201C}Reviewed\u{201D}, so nothing will be placed.")
        #expect(plan(included: 0, skipped: 4, outOfScope: 0).previewSentence
            == "All 4 pages in scope already carry \u{201C}Reviewed\u{201D}, so nothing will be placed.")
        #expect(plan(included: 0, skipped: 0, outOfScope: 3).previewSentence
            == "No page matches this scope, so nothing will be placed.")
    }

    /// Old output: "Preparing 1 of 1 stamp(s)" and "This will place 1 line(s) of text on …".
    @Test("The progress line and the header-footer noun agree with their counts")
    func progressAndLinesOfText() {
        #expect(BatchItemNoun.stamp.progressDetail(0, of: 1) == "Preparing 0 of 1 stamp")
        #expect(BatchItemNoun.stamp.progressDetail(120, of: 200) == "Preparing 120 of 200 stamps")
        #expect(BatchItemNoun.lineOfText.progressDetail(1, of: 1) == "Preparing 1 of 1 line of text")
        let lines = plan(included: 1, skipped: 0, outOfScope: 1, noun: .lineOfText)
        #expect(lines.previewSentence == "This will place 1 line of text on 1 of 2 pages.")
        #expect(plan(included: 2, skipped: 0, outOfScope: 0, noun: .lineOfText).previewSentence
            == "This will place 2 lines of text on 2 of 2 pages.")
    }

    /// Old output: "“a”, “b” was not excluded: …".
    @Test("The exclusion note says 'were' for two words and 'was' for one")
    func exclusionNote() {
        #expect(SearchExclusionNote.text(for: ["CORRIDOR"])
            == "\u{201C}CORRIDOR\u{201D} was not excluded: put NOT between two words, as in room NOT corridor")
        #expect(SearchExclusionNote.text(for: ["CORRIDOR", "STAIR"])
            == "\u{201C}CORRIDOR\u{201D}, \u{201C}STAIR\u{201D} were not excluded: put NOT between two words, as in room NOT corridor")
    }

    // MARK: - The shipped catalogue

    private static let catalogueURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Localization/en.lproj/Plurals.stringsdict")

    private func catalogueBundle(_ root: URL) throws -> Bundle {
        let lproj = root.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.catalogueURL, to: lproj.appendingPathComponent("Plurals.stringsdict"))
        let info: [String: Any] = ["CFBundleDevelopmentRegion": "en", "CFBundleIdentifier": "iter5.batch.catalogue"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: root))
    }

    @Test("The catalogue carries every new rule, and the two-argument rules keep the name")
    func catalogueRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Iter5BatchPlural-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try catalogueBundle(root)
        // Deliberately wrong fallbacks: every result below must come from the catalogue.
        func one(_ key: String, _ count: Int) -> String {
            LocalizedPlural.string(key, count: count, one: "x", other: "y", bundle: bundle)
        }
        func two(_ key: String, _ count: Int) -> String {
            LocalizedPlural.string(key, count: count, one: "x %2$@", other: "y %2$@", arguments: ["Reviewed"], bundle: bundle)
        }
        #expect(one("%lld stamps", 1) == "1 stamp")
        #expect(one("%lld stamps", 312) == "312 stamps")
        #expect(one("%lld lines of text", 1) == "1 line of text")
        #expect(one("%lld lines of text", 3) == "3 lines of text")
        #expect(one("%lld pages selected in the Navigator.", 1) == "1 page selected in the Navigator.")
        #expect(one("%lld pages selected in the Navigator.", 7) == "7 pages selected in the Navigator.")
        let allSkipped = "All %lld pages in scope already carry \u{201C}%@\u{201D}, so nothing will be placed."
        #expect(two(allSkipped, 1) == "The 1 page in scope already carries \u{201C}Reviewed\u{201D}, so nothing will be placed.")
        #expect(two(allSkipped, 4) == "All 4 pages in scope already carry \u{201C}Reviewed\u{201D}, so nothing will be placed.")
        let skip = "%lld pages already carry \u{201C}%@\u{201D} and will be skipped."
        #expect(two(skip, 1) == "1 page already carries \u{201C}Reviewed\u{201D} and will be skipped.")
        #expect(two(skip, 8) == "8 pages already carry \u{201C}Reviewed\u{201D} and will be skipped.")
        #expect(BatchItemNoun.stamp.phrase(count: 1, bundle: bundle) == "1 stamp")
        #expect(BatchItemNoun.pages(1, bundle: bundle) == "1 page")
    }
}
