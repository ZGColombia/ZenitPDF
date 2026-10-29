import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer

/// Fix round 3 (decided 2026-09-23, BH-167 follow-up, ADR-0011 §2.4): how
/// the stamp colour meets imported artwork once an imported stamp starts in its source colour.
///
/// The geometry here is the importer's output for the content stream
/// `1 0 0 rg 10 10 80 80 re f 1 1 1 rg 40 40 20 20 re f` plus a red outline — a red ink region
/// with no colour of its own, a white knockout carrying white, and a stroke — which
/// `ZPDFPDFKitBridge`'s `Fix3StampColourTests` pins from a real PDF. The stamp colour is the
/// markup's style: red by default (the seal's ink, adopted at import), blue once the person
/// chooses blue.
@Suite("Fix round 3 — the stamp colour and imported artwork")
struct Fix3StampColourSceneTests {

    private static let baseID = MarkupID(
        UUID(uuidString: "F3C00000-0000-4000-8000-000000000167") ?? UUID()
    )
    private static let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
    private static let blue = RGBAColor(red: 0, green: 0, blue: 1, alpha: 1)
    private static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)

    private static func square(_ low: Double, _ high: Double) -> [PDFPoint] {
        [PDFPoint(x: low, y: low), PDFPoint(x: high, y: low),
         PDFPoint(x: high, y: high), PDFPoint(x: low, y: high)]
    }

    /// The red-with-knockout seal as imported: the ink region colourless, the knockout white.
    private static let seal = ArtworkGeometry(
        kind: .vector,
        strokes: [ArtworkContour(points: square(0, 1), isClosed: true, widthFraction: 0.02)],
        regions: [
            ArtworkRegion(outer: square(0, 1)),
            ArtworkRegion(outer: square(0.375, 0.625), color: white)
        ],
        sourceAspectRatio: 1
    )

    private struct Paint: Equatable {
        var fills: [RGBAColor?]
        var strokes: [RGBAColor?]
    }

    private static func paint(_ artwork: ArtworkGeometry, stampColour: RGBAColor) -> Paint {
        let drawn = StampArtworkScene.markups(
            artwork: artwork,
            center: PDFPoint(x: 50, y: 50),
            size: PDFSize(width: 80, height: 80),
            style: RenderStyle(stroke: stampColour, fill: nil),
            baseID: baseID
        )
        var paint = Paint(fills: [], strokes: [])
        for markup in drawn {
            switch markup.shape {
            case .filledPolygon: paint.fills.append(markup.style.fill)
            case .polyline: paint.strokes.append(markup.style.stroke)
            default: break
            }
        }
        return paint
    }

    @Test("By default the seal draws in its own red, knockout white")
    func defaultIsAsDrawn() {
        #expect(Self.paint(Self.seal, stampColour: Self.red) == Paint(
            fills: [Self.red, Self.white],
            strokes: [Self.red]
        ))
    }

    @Test("Choosing blue recolours the ink regions and strokes blue and leaves the knockout white")
    func choosingBlueRecolours() {
        #expect(Self.paint(Self.seal, stampColour: Self.blue) == Paint(
            fills: [Self.blue, Self.white],
            strokes: [Self.blue]
        ))
    }

    @Test("A stamp stored before the ruling (no colour anywhere) still draws in its style colour")
    func oldStampTakesTheStyleColour() {
        let green = RGBAColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        let old = ArtworkGeometry(
            kind: .vector,
            strokes: Self.seal.strokes,
            regions: [ArtworkRegion(outer: Self.square(0, 1))],
            sourceAspectRatio: 1
        )
        #expect(Self.paint(old, stampColour: green) == Paint(fills: [green], strokes: [green]))
    }

    @Test("A multi-ink seal keeps each ink whatever the stamp colour")
    func multiInkKeepsEachInk() {
        let multi = ArtworkGeometry(
            kind: .vector,
            regions: [
                ArtworkRegion(outer: Self.square(0, 0.5), color: Self.red),
                ArtworkRegion(outer: Self.square(0.5, 1), color: Self.blue),
                ArtworkRegion(outer: Self.square(0.2, 0.3), color: Self.white)
            ],
            sourceAspectRatio: 1
        )
        let green = RGBAColor(red: 0, green: 1, blue: 0, alpha: 1)
        #expect(Self.paint(multi, stampColour: green).fills == [Self.red, Self.blue, Self.white])
    }
}
