import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts

/// The ledger's count-symbol legend: symbol name and digest per
/// subject, derived from the placed marks, so a deleted preset cannot blank a legend row.
///
/// | Rule | Test |
/// |---|---|
/// | The legend names each subject's symbol, with its digest and its count | ``theLegendNamesSymbolAndDigestPerSubject()`` |
/// | Marks that are not counts stay out; bare counts appear under the default dot | ``onlyCountsContributeAndBareCountsKeepARow()`` |
/// | Two builds over one takeoff are one legend, in one order | ``theLegendIsDeterministic()`` |
@Suite("Count symbol legend")
struct CountSymbolLegendTests {

    private static let drainDigest = String(repeating: "a", count: 64)

    private static func countRecord(
        subject: String,
        symbol: MarkupSymbol?,
        x: Double = 100
    ) -> MarkupRecord {
        let documentID = DocumentID(UUID())
        let pageID = PageID(UUID())
        return MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .count,
            tool: .count,
            subject: subject,
            geometry: MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: x, y: 100)]),
            symbol: symbol,
            createdAt: Date(timeIntervalSince1970: 1_756_400_000),
            modifiedAt: Date(timeIntervalSince1970: 1_756_400_000)
        )
    }

    private static func makeMarkups() -> [MarkupRecord] {
        let drain = MarkupSymbol(
            artworkDigest: drainDigest,
            kind: .vector,
            builtInGlyph: "filledCircle",
            sizePoints: 12,
            sourceName: "drain-symbol.pdf"
        )
        return [
            countRecord(subject: "Drains", symbol: drain, x: 10),
            countRecord(subject: "Drains", symbol: drain, x: 20),
            countRecord(subject: "Drains", symbol: drain, x: 30),
            countRecord(subject: "Doors", symbol: .builtIn("hollowSquare"), x: 40),
            countRecord(subject: "Doors", symbol: .builtIn("hollowSquare"), x: 50)
        ]
    }

    @Test("The legend names each subject's symbol, with its digest and its count")
    func theLegendNamesSymbolAndDigestPerSubject() {
        let entries = CountSymbolLegend.entries(markups: Self.makeMarkups())
        #expect(entries.count == 2)

        let doors = entries[0]
        #expect(doors.subject == "Doors")
        #expect(doors.artworkDigest == nil)
        #expect(doors.builtInGlyph == "hollowSquare")
        #expect(doors.symbolDisplayName == "Square", "a glyph is named by the picker's word, not its raw value")
        #expect(doors.markCount == 2)
        #expect(doors.staysSharpWhenMagnified)

        let drains = entries[1]
        #expect(drains.subject == "Drains")
        #expect(drains.artworkDigest == Self.drainDigest, "the legend names the digest the marks were placed with")
        #expect(drains.symbolDisplayName == "drain-symbol.pdf", "imported artwork is named by its source")
        #expect(drains.markCount == 3)
        #expect(drains.staysSharpWhenMagnified, "vector artwork keeps crisp edges and the legend can say so")
    }

    @Test("Marks that are not counts stay out; a count with no symbol keeps a row under the default dot")
    func onlyCountsContributeAndBareCountsKeepARow() {
        var markups = Self.makeMarkups()
        // A length measurement with a subject must not appear in a symbol legend.
        var length = Self.countRecord(subject: "Walls", symbol: nil)
        length.kind = .polyline
        length.tool = .length
        markups.append(length)
        // A count placed with no preset has no symbol, and is still a counted quantity.
        markups.append(Self.countRecord(subject: "Walls", symbol: nil))

        let entries = CountSymbolLegend.entries(markups: markups)
        #expect(entries.count == 3)
        let walls = entries.first { $0.subject == "Walls" }
        #expect(walls?.markCount == 1, "the length stayed out; the bare count is one row")
        #expect(walls?.builtInGlyph == CountSymbolCatalogue.defaultGlyphName)
        #expect(walls?.artworkDigest == nil)
    }

    @Test("Two builds over one takeoff are one legend, in one order")
    func theLegendIsDeterministic() {
        let markups = Self.makeMarkups()
        let once = CountSymbolLegend.entries(markups: markups)
        let again = CountSymbolLegend.entries(markups: markups.reversed())
        #expect(once == again, "insertion order must not leak into the legend")
        #expect(once.map(\.subject) == ["Doors", "Drains"])
    }
}
