import Foundation
import Testing
import ZPDFUIPresentation
@testable import ZPDFUIWorkflows

/// Loop iteration 5, area ui-workflows-ledger, V-068: the workflow sheets read correctly for a
/// count of one. The test bundle has no `Plurals.stringsdict`, so the phrases below take
/// ``LocalizedPlural``'s English fallback — the one/other pair `WorkflowPlurals` passes — and the
/// catalogue test checks that the shipped rules say the same.
@Suite("Workflows, loop iteration 5 — count phrases (V-068)", .workflowsTierSerialised)
@MainActor
struct Iter5WorkflowsPluralTests {

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ZPDFUIWorkflows")

    private static let catalogue = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ZPDFUIPresentation/Localization/en.lproj/Plurals.stringsdict")

    /// A literal with an integer conversion followed, within three words, by a counted noun —
    /// "%d differences", "Add %d Areas", "%1$d interior rule lines" — or an "(s)" / "(es)"
    /// workaround. Ordinals and bare numbers ("format %1$d", "Already counted: %d") carry no
    /// noun to agree with.
    private static let offending = try! NSRegularExpression(
        pattern: #"%(\d+\$)?(l{0,2}d|i)\s+(?:[\w-]+\s+){0,3}?(?:rows|groups|rules|markups|items|lines|fields|options|measurements|entries|differences|areas|counts|sheets|words|tools|rooms|pages|categories|images|symbols|matches|changes|files|results|stamps|columns|cells|documents|revisions|layers|points|hits|drawings|marks|scales|presets|findings|warnings|values|regions|tables|labels|annotations|comments|terms|pictures|tags|places|clusters|shapes|misses)\b|\((?:e?s)\)"#,
        options: [.caseInsensitive]
    )

    private static func isOffending(_ literal: String) -> Bool {
        offending.firstMatch(in: literal, range: NSRange(literal.startIndex..., in: literal)) != nil
    }

    /// `text` with every `LocalizedPlural.string(…)` call blanked out: its formats are the
    /// one/other pair of a plural rule, which is exactly where a counted noun belongs.
    private static func outsidePluralCalls(_ text: String) -> String {
        var characters = Array(text)
        let marker = Array("LocalizedPlural.string(")
        var index = 0
        while index + marker.count <= characters.count {
            guard Array(characters[index..<(index + marker.count)]) == marker else { index += 1; continue }
            var end = index + marker.count
            var depth = 1
            while depth > 0, end < characters.count {
                if characters[end] == "(" { depth += 1 } else if characters[end] == ")" { depth -= 1 }
                end += 1
            }
            for position in index..<end where characters[position] != "\n" { characters[position] = " " }
            index = end
        }
        return String(characters)
    }

    @Test("V-068: no ZPDFUIWorkflows format pairs a bare count with a noun, or writes (s)")
    func noBareCountFormatsRemain() throws {
        // The guard recognises what it is for, and leaves ordinals alone.
        #expect(Self.isOffending("Add %d Areas"))
        #expect(Self.isOffending("%1$d interior rule line(s) and"))
        #expect(Self.isOffending("%1$d differences to review"))
        #expect(Self.isOffending("%d of the tools described"))
        #expect(!Self.isOffending("tool set format %1$d. This version"))
        #expect(!Self.isOffending("Already counted: %d — left unticked"))
        #expect(!Self.isOffending("Nothing was placed. The preview counted %d, but none could be placed. Preview again to see what the pages hold now."))

        let literal = try NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        var offenders: [String] = []
        var scanned = 0
        let enumerator = FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            scanned += 1
            let text = Self.outsidePluralCalls(try String(contentsOf: url, encoding: .utf8))
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let line = String(line)
                for match in literal.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    if Self.isOffending(String(line[range])) {
                        offenders.append("\(url.lastPathComponent):\(number + 1): \(line[range])")
                    }
                }
            }
        }
        #expect(scanned > 50, "the scan found the package's sources")
        // Old output: 30-odd offenders — "Add %d Areas", "%1$d differences to review, %2$d
        // accepted", "%d cell(s) could not be read" …
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    @Test("V-068: the phrases read in the singular for one")
    func singularPhrases() {
        #expect(WorkflowPlurals.addAreas(1) == "Add 1 Area")
        #expect(WorkflowPlurals.addAreas(3) == "Add 3 Areas")
        #expect(WorkflowPlurals.addCounts(1) == "Add 1 Count")
        #expect(WorkflowPlurals.nameSheets(1) == "Name 1 Sheet")
        #expect(WorkflowPlurals.addReadRows(1) == "Add 1 Read Row")
        #expect(WorkflowPlurals.importTools(1) == "Import 1 Tool")
        #expect(WorkflowPlurals.words(1) == "1 word")
        #expect(WorkflowPlurals.unreadCells(1) == "1 cell could not be read. It stays empty \u{2014} nothing is filled in for you.")
        #expect(WorkflowPlurals.unreadCells(4) == "4 cells could not be read. They stay empty \u{2014} nothing is filled in for you.")
        #expect(WorkflowPlurals.cellsFailingNumberClaim(1).hasPrefix("1 cell in a number column does not read as a number."))
        #expect(WorkflowPlurals.linesWithoutPositions(1).hasPrefix("1 recognised line in this region carries no page position, so it"))
        #expect(WorkflowPlurals.droppedTools(1).hasSuffix("The reason is listed below."))
    }

    @Test("V-068: the sentences built from pieces read in the singular for one")
    func singularSentences() throws {
        // Revision alignment: "Mark 3 matching points …" and "over 1 point" never "1 points".
        #expect(RevisionAlignmentProblem.notEnoughPoints(needed: 3, given: 1).message
            == "Mark 3 matching points on both sheets. You have marked 1.")

        // The tool set summary. Old output: "1 tools, 1 categories, 0 images".
        let raw = """
        {"schemaVersion": 1, "name": "One", "presets": [
          {"name": "Wall", "category": "Walls", "markupType": "measurement", "measurementTool": "length", "color": "#00AAFF"}]}
        """
        guard case let .success(review) = ToolSetImportValidator().review(data: Data(raw.utf8), fileName: "One.zpdftools") else {
            Issue.record("expected a review"); return
        }
        #expect(review.summaryLine == "1 tool, 1 category, 0 images")

        // The room review. Old output: "1 rooms found; 1 ticked."
        #expect(WorkflowPlurals.roomsFound(1) == "1 room found")
        #expect(WorkflowPlurals.differencesToReview(1) == "1 difference to review")
        #expect(WorkflowPlurals.differencesAllHidden(1) == "1 difference found, hidden by the change filter")
        #expect(WorkflowPlurals.needALook(1) == "1 needs a look before it is accepted.")
        #expect(WorkflowPlurals.orphanTags(1) == "1 tag with no symbol beside it is marked on the sheet.")
        #expect(WorkflowPlurals.contestedPlaces(1) == "1 place matches more than one type")
        #expect(WorkflowPlurals.stillNeedAPick(1) == "1 still needs a pick.")
        #expect(WorkflowPlurals.pages(1) == "1 page")
    }

    /// The fallback pairs and the shipped rules must agree, or the app and the tests read two
    /// different sentences.
    @Test("V-068: every WorkflowPlurals rule is in the catalogue with the same one and other")
    func catalogueMatchesTheFallback() throws {
        let data = try Data(contentsOf: Self.catalogue)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]])
        let source = try String(
            contentsOf: Self.sources.appendingPathComponent("Support/WorkflowPlurals.swift"), encoding: .utf8
        )
        let call = try NSRegularExpression(
            pattern: #"LocalizedPlural\.string\(\s*"((?:[^"\\]|\\.)*)", count: count,\s*one: NSLocalizedString\("((?:[^"\\]|\\.)*)"[^\n]*\n\s*other: NSLocalizedString\("((?:[^"\\]|\\.)*)""#
        )
        let matches = call.matches(in: source, range: NSRange(source.startIndex..., in: source))
        #expect(matches.count >= 30)
        for match in matches {
            func group(_ index: Int) -> String {
                String(source[Range(match.range(at: index), in: source)!]).replacingOccurrences(of: #"\""#, with: "\"")
            }
            let key = group(1), one = group(2), other = group(3)
            #expect(key == other, "the key is the English plural: \(key)")
            let entry = try #require(plist[key], "missing from Plurals.stringsdict: \(key)")
            let forms = try #require(entry["count"] as? [String: Any])
            #expect(forms["one"] as? String == one, "\(key) [one]")
            #expect(forms["other"] as? String == other, "\(key) [other]")
        }
    }
}
