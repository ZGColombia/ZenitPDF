import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation

/// NL-AUTO-08: a detected room is named from its label.
struct RoomLabelPairingTests {

    static let room: [PDFPoint] = [PDFPoint(x: 0, y: 0), PDFPoint(x: 200, y: 0), PDFPoint(x: 200, y: 150), PDFPoint(x: 0, y: 150)]
    static func line(_ text: String, _ x: Double, _ y: Double) -> RecognisedTextLine {
        RecognisedTextLine(text: text, boundsInPageSpace: PDFRectValue(x: x, y: y, width: 60, height: 10))
    }

    @Test("Name over area: the name, and the printed area for the check")
    func nameOverArea() {
        let label = RoomLabelPairing.label(for: Self.room, lines: [Self.line("Sovrum 2", 70, 80), Self.line("12,3 m²", 70, 66), Self.line("KÖK", 400, 80)])
        #expect(label.name == "Sovrum 2")
        #expect(label.printedSquareMetres == Decimal(string: "12.3"))
    }

    @Test("A one-line label loses its area; an empty room has no name")
    func oneLineAndEmpty() {
        #expect(RoomLabelPairing.label(for: Self.room, lines: [Self.line("WC 3 4,2 m²", 70, 80)]).name == "WC 3")
        let empty = RoomLabelPairing.label(for: Self.room, lines: [Self.line("1:50", 70, 80), Self.line("12", 70, 60)])
        #expect(empty.name == nil && empty.printedSquareMetres == nil)
    }
}
