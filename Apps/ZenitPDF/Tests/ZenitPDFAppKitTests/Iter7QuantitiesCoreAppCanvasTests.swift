import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Quality-loop iteration 7, area "quantities-core", on the canvas scene: X-042 (a three-point
/// Arc Length is drawn as the arc it measures) and X-046 (the canvas turns a markup about the
/// record's own style-rotation box, the one the snap index reads). Scene building only — no window.
@MainActor
@Suite(.appTierSerialised)
struct Iter7QuantitiesCoreAppCanvasTests {

    private static let stamp = Date(timeIntervalSince1970: 1_790_000_000)
    private static let page = PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000007d1")!)

    private static func record(_ kind: ZPDFContracts.MarkupKind, tool: MeasurementTool? = nil, points: [PDFPoint],
                               style: MarkupStyle = MarkupStyle()) -> MarkupRecord {
        MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(UUID()), pageID: page, kind: kind, tool: tool,
            style: style, caption: kind == .text || kind == .callout ? "Words" : nil,
            geometry: MeasurementGeometry(pageID: page, points: points),
            createdAt: stamp, modifiedAt: stamp
        )
    }

    /// Arc Length (300, 300) → (350, 350) → (400, 300): drawn as the semicircle about (350, 300)
    /// of r = 50 — every drawn point 50 pt from the centre, the stroke carrying the arc outline,
    /// no dimension ticks — from (300, 300) to (400, 300).
    /// Old output: one dimensioned stroke through the three points, two chords; its midpoint
    /// (350, 350) sat on the arc only by accident and the chord midpoints 14.6 pt inside it.
    @Test("X-042: a three-point Arc Length is drawn as the arc it measures")
    func arcLengthIsDrawnAsItsArc() throws {
        let record = Self.record(.measurement, tool: .arcLength, points: [
            PDFPoint(x: 300, y: 300), PDFPoint(x: 350, y: 350), PDFPoint(x: 400, y: 300)
        ])
        let shape = try #require(CanvasSceneBuilder.build(records: [record], summaries: [], pageID: Self.page.rawValue).first)
        let stroke = try #require(shape.strokes.first)
        #expect(!stroke.dimensioned)
        #expect(stroke.arcOutline == record.drawnPointChain)
        #expect(stroke.points.count > 3, "\(stroke.points.count) points: the arc is flattened finely for the screen")
        #expect(stroke.points.first == PDFPointValue(x: 300, y: 300))
        #expect(stroke.points.last == PDFPointValue(x: 400, y: 300))
        for point in stroke.points {
            let radius = ((point.x - 350) * (point.x - 350) + (point.y - 300) * (point.y - 300)).squareRoot()
            #expect(Swift.abs(radius - 50) <= 1e-9, "(\(point.x), \(point.y)) is \(radius) pt from the centre")
        }
        #expect(stroke.points.allSatisfy { $0.y >= 300 - 1e-9 }, "over the top, as the through point says")
        // A Polylength through the same points is still its two dimensioned chords.
        let polylength = Self.record(.measurement, tool: .polylength, points: [
            PDFPoint(x: 300, y: 300), PDFPoint(x: 350, y: 350), PDFPoint(x: 400, y: 300)
        ])
        let chords = try #require(CanvasSceneBuilder.build(records: [polylength], summaries: [], pageID: Self.page.rawValue).first?.strokes.first)
        #expect(chords.dimensioned && chords.points.count == 3)
    }

    /// The box the canvas turns a markup about is the record's (`MarkupRecord.styleRotationBox`),
    /// for every kind that turns, and nothing for a kind that does not.
    /// Old output: the canvas computed its own copy of the box beside the record's centre.
    @Test("X-046: the canvas turns about the record's style-rotation box")
    func canvasReadsTheRecordsBox() {
        var turned = MarkupStyle()
        turned.rotationDegrees = 30
        for kind in ZPDFContracts.MarkupKind.allCases {
            let record = Self.record(kind, points: [PDFPoint(x: 40, y: 40), PDFPoint(x: 100, y: 100), PDFPoint(x: 220, y: 150)], style: turned)
            let box = CanvasSceneBuilder.rotationBox(of: record)
            if record.turnsWithStyleRotation {
                let expected = record.styleRotationBox.map {
                    PDFRectValue(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height)
                }
                #expect(box == expected, "\(kind)")
            } else {
                #expect(box == nil, "\(kind)")
            }
        }
    }
}
