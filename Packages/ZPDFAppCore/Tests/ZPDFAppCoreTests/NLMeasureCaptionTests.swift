import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZPDFAppCore

/// NL-MEASURE-09: caption fields, segment lengths, and the caption as a style edit.
@Suite("Measurement caption (NL-MEASURE-09)")
struct NLMeasureCaptionTests {

    static func field(_ field: Shown.Field, _ text: String, _ unit: String) -> MeasurementFieldSummary {
        MeasurementFieldSummary(field: field, quantity: ZPDFUIPresentation.DecimalQuantity(value: 0, dimension: .length), displayText: text, displayUnitSymbol: unit)
    }

    @Test("An area shows its label, the headline and the chosen perimeter: “Area C: 21.34 m² · P 18.60 m”")
    func multiField() {
        let fields = [Self.field(.netArea, "21.34", "m²"), Self.field(.perimeter, "18.60", "m")]
        #expect(MeasurementCaptionText.text(label: "Area C", fields: fields, primary: .netArea, chosen: [.netArea, .perimeter], repetition: nil)
                == "Area C: 21.34 m² · P 18.60 m")
        // No choice: the headline alone, as before this ADR.
        #expect(MeasurementCaptionText.text(label: "Area C", fields: fields, primary: .netArea, chosen: [], repetition: nil) == "Area C: 21.34 m²")
        #expect(MeasurementCaptionText.text(label: "", fields: fields, primary: .netArea, chosen: [], repetition: "×6") == "21.34 m² ×6")
        // A chosen field the markup does not have is left out, not shown empty.
        #expect(MeasurementCaptionText.text(label: "A", fields: fields, primary: .netArea, chosen: [.volume, .perimeter], repetition: nil) == "A: P 18.60 m")
    }

    /// A 3-4-5 polylength at 1 m/pt: 3 + 4 = 7 m total, segments 3 m and 4 m. A 10 × 5 area:
    /// perimeter 30 m, edges 10, 5, 10, 5. A separate X/Y scale (0.1 m/pt across, 0.2 m/pt up):
    /// a 30 pt horizontal edge is 3 m and a 40 pt vertical edge is 8 m.
    @Test("Segment lengths split the stored total on a uniform scale and use both factors on X/Y")
    func segments() throws {
        let page = PageID(UUID())
        let stamp = Date(timeIntervalSince1970: 0)
        var line = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: .measurement, tool: .polylength,
            subject: "", author: "", geometry: MeasurementGeometry(pageID: page, points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 3, y: 0), PDFPoint(x: 3, y: 4)
            ]), createdAt: stamp, modifiedAt: stamp
        )
        line.measurement = MeasurementResult(values: [.planLength: .length(7)])
        let parts = MeasurementCaptionText.segments(of: line, metresPerPoint: (1, 1))
        #expect(parts.map(\.metres) == [3, 4])

        var area = line
        area.tool = .area
        area.geometry = MeasurementGeometry(pageID: page, polygons: [PolygonGeometry(outer: PolygonRing(points: [
            PDFPoint(x: 0, y: 0), PDFPoint(x: 10, y: 0), PDFPoint(x: 10, y: 5), PDFPoint(x: 0, y: 5)
        ]))])
        area.measurement = MeasurementResult(values: [.perimeter: .length(30)])
        #expect(MeasurementCaptionText.segments(of: area, metresPerPoint: nil).map(\.metres) == [10, 5, 10, 5])

        var skewed = line
        skewed.geometry = MeasurementGeometry(pageID: page, points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 30, y: 0), PDFPoint(x: 30, y: 40)])
        let xy = MeasurementCaptionText.segments(of: skewed, metresPerPoint: (0.1, 0.2)).map { NSDecimalNumber(decimal: $0.metres).doubleValue }
        #expect(Swift.abs(xy[0] - 3) < 1e-12 && Swift.abs(xy[1] - 8) < 1e-12)
        #expect(MeasurementCaptionText.offersSegmentLengths(.area))
        #expect(!MeasurementCaptionText.offersSegmentLengths(.count))
    }

    @Test("The caption is a style edit: one undo, values untouched, a default caption is not stored")
    func styleEdit() async throws {
        let documentID = DocumentID(UUID())
        let page = ZPDFContracts.PageDescriptor(id: PageID(UUID()), documentID: documentID, index: 0, label: "A",
                                                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 1000, height: 1000)))
        let session = try TakeoffSession(documentID: documentID, pages: [page])
        _ = try await session.calibrate(page: page.id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 100, knownLengthUnit: .metre)
        let record = NLMeasureParameterEditingTests.square(page.id, tool: .area, parameters: .default)
        _ = try await session.apply(.addMarkup(record))
        let stored = try #require(await session.markup(record.id))
        let before = stored.measurement

        let outcome = try await session.applyBatch(MeasurementCaptionText.commands(on: [stored]) {
            $0.fields = [.netArea, .perimeter]
            $0.showsSegmentLengths = true
            $0.labelOffset = PDFPoint(x: 12, y: -4)
        })
        let captioned = try #require(await session.markup(record.id))
        #expect(captioned.style.measurementCaption == MeasurementCaption(fields: [.netArea, .perimeter], showsSegmentLengths: true, labelOffset: PDFPoint(x: 12, y: -4)))
        #expect(captioned.measurement?.values == before?.values, "a caption changes no value")

        // Back to the default: the caption is removed, not stored empty.
        _ = try await session.applyBatch(MeasurementCaptionText.commands(on: [captioned]) { $0 = MeasurementCaption() })
        #expect(await session.markup(record.id)?.style.measurementCaption == nil)
        _ = try await session.revert(outcome.inverse)
        #expect(await session.markup(record.id)?.style.measurementCaption == nil)
    }
}
