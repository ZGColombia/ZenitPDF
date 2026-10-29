import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// Iteration 2, appcore: strict rate parsing (S-036) and copied drawing ratios across /UserUnit (S-038).
@Suite("Iter2 appcore: rates and copied scales")
struct Iter2AppCoreMiscTests {

    // MARK: S-036

    @Test("A malformed rate, waste or pack size is refused with its line, never read by its prefix")
    func strictRateParsing() {
        // Old output: 12, 120, 5 and 1.5 — `Decimal(string:)` read the prefix.
        #expect(RateLibraryCSV.parseNumber("12-5", decimalComma: false) == nil)
        #expect(RateLibraryCSV.parseNumber("120-150", decimalComma: false) == nil)
        #expect(RateLibraryCSV.parseNumber("5-10", decimalComma: false) == nil)
        #expect(RateLibraryCSV.parseNumber("1.5-", decimalComma: false) == nil)
        // The spellings a person uses still read.
        #expect(RateLibraryCSV.parseNumber("45.5", decimalComma: false) == Decimal(string: "45.5"))
        #expect(RateLibraryCSV.parseNumber("1 234,50", decimalComma: true) == Decimal(string: "1234.50"))
        #expect(RateLibraryCSV.parseNumber("95 kr", decimalComma: true) == 95)
        #expect(RateLibraryCSV.parseNumber("5.", decimalComma: false) == 5)
        #expect(RateLibraryCSV.parseNumber(",5", decimalComma: true) == Decimal(string: "0.5"))

        let list = """
        Name,Unit,Rate,Waste,Pack
        Tile,m2,12-5,,
        Screed,m2,120-150,,
        Board,m2,45.5,5-10,
        Stud,m,18.2,,2-3
        Paint,m2,45.5,10 %,2.5
        """
        let parsed = RateLibraryCSV.parse(list, defaultCurrency: "EUR")
        // Old output: four entries — Tile at 12, Screed at 120, Board at 5 % waste, Stud with a pack of 2.
        #expect(parsed.entries.map(\.name) == ["Paint"])
        #expect(parsed.entries.first?.rate == Decimal(string: "45.5"))
        #expect(parsed.entries.first?.waste == Decimal(string: "0.10"))
        #expect(parsed.entries.first?.packSize == Decimal(string: "2.5"))
        #expect(parsed.rejected.map(\.line) == [2, 3, 4, 5])
    }

    // MARK: S-038

    static let units = ScaleUnitPolicy(length: .metre, area: .squareMetre, volume: .cubicMetre)

    static func page(_ documentID: DocumentID, _ index: Int, userUnit: Double) -> ZPDFContracts.PageDescriptor {
        ZPDFContracts.PageDescriptor(
            id: PageID(UUID()), documentID: documentID, index: index, label: "P\(index)",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 612, height: 792)), userUnit: userUnit
        )
    }

    @Test("A 1:50 copied A (UserUnit 1) → B (UserUnit 2) → C (UserUnit 1) measures on C exactly as on A")
    func copyOfACopiedRatioIsRescaled() async throws {
        let documentID = DocumentID(UUID())
        let a = Self.page(documentID, 0, userUnit: 1)
        let b = Self.page(documentID, 1, userUnit: 2)
        let c = Self.page(documentID, 2, userUnit: 1)
        let session = try TakeoffSession(documentID: documentID, pages: [a, b, c])
        _ = try await session.applyScale(.ratio(numerator: 1, denominator: 50, label: "1:50"), toPages: [a.id])
        _ = try await session.applyScale(.copyOf(page: a.id), toPages: [b.id])
        _ = try await session.applyScale(.copyOf(page: b.id), toPages: [c.id])

        let onA = try #require(await session.scale(onPage: a.id))
        let onB = try #require(await session.scale(onPage: b.id))
        let onC = try #require(await session.scale(onPage: c.id))
        #expect(onB.matrix.a == onA.matrix.a * 2, "B's page unit is twice A's")
        #expect(onB.source == .preset)
        // Old output: C carried B's doubled matrix unchanged (source .inherited), a = 2 × A's.
        // Back through ×2 then ×½ in 38-digit `Decimal`, the last digit may round: equal to 1e-30.
        for (c, a) in [(onC.matrix.a, onA.matrix.a), (onC.matrix.d, onA.matrix.d)] {
            let relative = (c - a) / a
            #expect(relative.magnitude < Decimal(sign: .plus, exponent: -30, significand: 1), "C \(c) vs A \(a)")
        }
        #expect(onC.matrix.b == 0 && onC.matrix.c == 0)
        #expect(onC.source == .preset)
        #expect(onC.label == "1:50")

        // 100 pt on C at 1:50: 100 × 0.0254 / 72 × 50 = 1.763 888… m, the same as on A.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let line = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: documentID, pageID: c.id, kind: .measurement, tool: .length,
            subject: "Wall", author: "t",
            geometry: MeasurementGeometry(pageID: c.id, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 100, y: 0)]),
            createdAt: stamp, modifiedAt: stamp
        )
        _ = try await session.apply(.addMarkup(line))
        let metres = try #require(await session.markup(line.id)?.measurement?[.planLength]?.value)
        let expected = 100.0 * 0.0254 / 72.0 * 50.0
        #expect(abs(NSDecimalNumber(decimal: metres).doubleValue - expected) < 1e-9, "old output: 3.527 777… m")

        // A copied calibration is still marked inherited and carried unchanged.
        _ = try await session.calibrate(page: a.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0),
                                        knownLength: 10, knownLengthUnit: .metre)
        _ = try await session.applyScale(.copyOf(page: a.id), toPages: [b.id])
        let calibrated = try #require(await session.scale(onPage: a.id))
        let copied = try #require(await session.scale(onPage: b.id))
        #expect(copied.source == .inherited)
        #expect(copied.matrix == calibrated.matrix)
    }
}
