import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-AUTO-09: printed room areas against measured ones. Every expected value is by hand.
struct PrintedAreaCheckTests {

    static func label(_ text: String, _ x: Double, _ y: Double) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: 60, height: 10))
    }

    static let square: [PDFPoint] = [PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 200, y: 200), PDFPoint(x: 0, y: 200)]

    @Test("Notations in both languages and in square feet")
    func parse() {
        let areas = PrintedAreaCheck.printedAreas(in: [
            Self.label("Sovrum 12,3 m²", 0, 0), Self.label("WC 3.4 m2", 0, 20),
            Self.label("Kök 9 kvm", 0, 40), Self.label("OFFICE 132 SF", 0, 60), Self.label("1:100", 0, 80)
        ])
        #expect(areas.map(\.squareMetres) == [
            Decimal(string: "12.3")!, Decimal(string: "3.4")!, 9,
            // 132 × 0.09290304 = 12.26320128
            Decimal(string: "12.26320128")!
        ])
    }

    @Test("A mis-calibrated room warns, a correct one agrees, an unlabelled one is silent")
    func check() {
        let wrong = MarkupID(UUID()), right = MarkupID(UUID()), silent = MarkupID(UUID())
        let far = Self.square.map { PDFPoint(x: $0.x + 1000, y: $0.y) }
        let other = Self.square.map { PDFPoint(x: $0.x + 500, y: $0.y) }
        let findings = PrintedAreaCheck.check(
            rooms: [
                // Printed 12,3; measured 12,9: 0.6 / 12.3 = 4.9 % > 3 %.
                PrintedAreaCheck.Room(markupID: wrong, ring: Self.square, measuredSquareMetres: Decimal(string: "12.9")!),
                // Printed 20; measured 20,4: 2 % ≤ 3 %.
                PrintedAreaCheck.Room(markupID: right, ring: other, measuredSquareMetres: Decimal(string: "20.4")!),
                PrintedAreaCheck.Room(markupID: silent, ring: far, measuredSquareMetres: 7)
            ],
            lines: [Self.label("Sovrum 12,3 m²", 70, 95), Self.label("Vardagsrum 20 m²", 570, 95)]
        )
        #expect(findings.count == 2)
        let bad = findings.first { $0.markupID == wrong }
        #expect(bad?.agrees == false)
        #expect(bad?.relativeDifference == Decimal(string: "0.6")! / Decimal(string: "12.3")!)
        #expect(findings.first { $0.markupID == right }?.agrees == true)
        #expect(!findings.contains { $0.markupID == silent })
    }

    @Test("Two different areas printed in one room say nothing")
    func ambiguousRoom() {
        let findings = PrintedAreaCheck.check(
            rooms: [PrintedAreaCheck.Room(markupID: MarkupID(UUID()), ring: Self.square, measuredSquareMetres: 12)],
            lines: [Self.label("12,3 m²", 20, 20), Self.label("8,1 m²", 20, 120)]
        )
        #expect(findings.isEmpty)
    }
}
