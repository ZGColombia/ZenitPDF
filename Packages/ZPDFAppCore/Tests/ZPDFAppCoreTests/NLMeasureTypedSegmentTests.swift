import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFAppCore

/// NL-MEASURE-18 foundation: the typed-length grammar and its placement through the scale.
@Suite("Typed length while drawing (NL-MEASURE-18)")
struct NLMeasureTypedSegmentTests {

    /// A stand-in for the app's shared parser: either decimal mark.
    static func number(_ text: String) -> Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }

    @Test("Length, and length<angle, in the drawing's unit")
    func grammar() {
        #expect(TypedSegment.parse("4,2", unit: .metre, number: Self.number) == .init(metres: Decimal(string: "4.2")!, angleDegrees: nil))
        #expect(TypedSegment.parse("4.2<90", unit: .metre, number: Self.number) == .init(metres: Decimal(string: "4.2")!, angleDegrees: 90))
        #expect(TypedSegment.parse("4200", unit: .millimetre, number: Self.number)?.metres == Decimal(string: "4.2")!)
        #expect(TypedSegment.parse("", unit: .metre, number: Self.number) == nil)
        #expect(TypedSegment.parse("-3", unit: .metre, number: Self.number) == nil)
        #expect(TypedSegment.parse("4<x", unit: .metre, number: Self.number) == nil)
    }

    /// Separate X/Y at sx = 0.1, sy = 0.2 m/pt. "4 m at 90°" from (0,0) is real (0, 4), which is
    /// page (0, 4 / 0.2) = (0, 20). Toward a pointer at (30, 0), 3 m is page (3 / 0.1, 0) = (30, 0).
    @Test("Placement works in real space, so an anisotropic scale places the right page point")
    func placement() throws {
        let scale = try ScaleTransform.separateXY(
            id: ScaleID(UUID()), metresPerPointX: Decimal(string: "0.1")!, metresPerPointY: Decimal(string: "0.2")!,
            units: .metric, source: .calibrationXY
        )
        let up = try #require(TypedSegment.point(
            from: PDFPoint(x: 0, y: 0), toward: nil,
            entry: .init(metres: 4, angleDegrees: 90), scale: scale
        ))
        #expect(abs(up.x) < 1e-9)
        #expect(abs(up.y - 20) < 1e-9)
        let along = try #require(TypedSegment.point(
            from: PDFPoint(x: 0, y: 0), toward: PDFPoint(x: 30, y: 0),
            entry: .init(metres: 3, angleDegrees: nil), scale: scale
        ))
        #expect(abs(along.x - 30) < 1e-9)
        #expect(abs(along.y) < 1e-9)
        #expect(TypedSegment.point(from: PDFPoint(x: 1, y: 1), toward: PDFPoint(x: 1, y: 1), entry: .init(metres: 3, angleDegrees: nil), scale: scale) == nil)
    }
}
