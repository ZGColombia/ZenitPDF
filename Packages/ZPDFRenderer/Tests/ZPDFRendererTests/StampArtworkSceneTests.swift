import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFRenderer

/// A stamp's artwork, drawn as geometry.
///
/// The claim under test is the one the stamp design makes and the one an estimator can check on
/// a plot: **vector artwork stays vector, so a stamp is sharp at 400 %.** In this pipeline
/// that is a structural property rather than a quality setting — enlarging a stamp
/// multiplies coordinates, and there is no sampled image anywhere for a magnification to
/// find. These tests pin the structure, because the structure is the guarantee.
@Suite("Stamp artwork scene")
struct StampArtworkSceneTests {

    /// A square outline and a triangular fill in unit space: enough shape that a
    /// transform mistake shows up as a wrong point rather than as a plausible one.
    static let artwork = StampArtworkGeometry(
        strokes: [RenderPolyline(
            points: [
                PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0),
                PDFPoint(x: 1, y: 1), PDFPoint(x: 0, y: 1)
            ],
            isClosed: true
        )],
        fills: [RenderPolygon(outer: [
            PDFPoint(x: 0.25, y: 0.25), PDFPoint(x: 0.75, y: 0.25), PDFPoint(x: 0.5, y: 0.75)
        ])]
    )

    static let labels = [
        StampSceneLabel(
            text: "2026-08-25",
            normalizedFrame: PDFRect(x: 0.05, y: 0.55, width: 0.9, height: 0.3)
        ),
        StampSceneLabel(
            text: "Estimator",
            normalizedFrame: PDFRect(x: 0.05, y: 0.15, width: 0.9, height: 0.3)
        )
    ]

    /// The placement's identity. Every shape derives its own from this one.
    static let baseID = MarkupID(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID()
    )

    static func scene(width: Double, height: Double) -> [RenderableMarkup] {
        StampArtworkScene.markups(
            artwork: artwork,
            labels: labels,
            center: PDFPoint(x: 1000, y: 500),
            size: PDFSize(width: width, height: height),
            baseID: baseID
        )
    }

    @Test("A stamp is drawn out of the shapes the renderer already has")
    func stampUsesOrdinaryShapes() {
        let shapes = Self.scene(width: 160, height: 60)
        #expect(shapes.count == 4, "one fill, one stroke, two labels")
        var fills = 0, strokes = 0, texts = 0
        for shape in shapes {
            switch shape.shape {
            case .filledPolygon: fills += 1
            case .polyline: strokes += 1
            case .textLabel: texts += 1
            default: Issue.record("a stamp produced a shape that is not artwork or a label")
            }
        }
        #expect((fills, strokes, texts) == (1, 1, 2))
        // Every piece carries **its own** identity, derived from the placed markup's, and
        // every one of them belongs to that markup. Both halves matter and this assertion
        // used to make only the first one, wrongly: it required one identity for the whole
        // stamp, which the renderer's arenas, bounds map and hit index — one entry per
        // identity — cannot represent, so the Metal backend drew one shape per stamp and
        // nothing noticed, because nothing had ever rendered a stamp. ADR-0011 §2.6.
        #expect(Set(shapes.map(\.id)).count == shapes.count)
        #expect(shapes.allSatisfy { StampArtworkScene.isPart($0.id, of: Self.baseID) })
    }

    @Test("Enlarging a stamp scales its geometry exactly — nothing is sampled")
    func vectorArtworkStaysVector() throws {
        let small = Self.scene(width: 160, height: 60)
        let large = Self.scene(width: 1600, height: 600)

        // The two scenes have the same structure: enlarging produced no extra primitive, no
        // level of detail, no tile — the *only* difference is coordinates. That is what
        // "stays vector" means here, and it is why the stamp is as sharp at 400 % as at 100.
        #expect(small.count == large.count)

        func outline(_ shapes: [RenderableMarkup]) throws -> [PDFPoint] {
            for shape in shapes {
                if case .polyline(let line) = shape.shape { return line.points }
            }
            throw StampSceneTestError.noOutline
        }
        let smallOutline = try outline(small)
        let largeOutline = try outline(large)
        #expect(smallOutline.count == largeOutline.count)

        // Ten times the box is exactly ten times the offset from the anchor, on both axes,
        // for every vertex — an affine map and nothing else.
        for (near, far) in zip(smallOutline, largeOutline) {
            #expect(abs((far.x - 1000) - 10 * (near.x - 1000)) < 1e-9)
            #expect(abs((far.y - 500) - 10 * (near.y - 500)) < 1e-9)
        }

        // The unit box's corners land exactly on the stamp box's corners at both sizes, so
        // the artwork fills the stamp rather than drifting inside it as it grows.
        #expect(smallOutline.contains { abs($0.x - (1000 - 80)) < 1e-9 && abs($0.y - (500 - 30)) < 1e-9 })
        #expect(largeOutline.contains { abs($0.x - (1000 - 800)) < 1e-9 && abs($0.y - (500 - 300)) < 1e-9 })
    }

    @Test("Text scales with the stamp box, so one template is legible at any size")
    func labelsScaleWithTheBox() {
        func fontSizes(_ shapes: [RenderableMarkup]) -> [Double] {
            shapes.compactMap { shape in
                if case .textLabel(let label) = shape.shape { return label.fontSize }
                return nil
            }
        }
        let small = fontSizes(Self.scene(width: 160, height: 60))
        let large = fontSizes(Self.scene(width: 1600, height: 600))
        #expect(small.count == 2)
        #expect(zip(small, large).allSatisfy { abs($1 - 10 * $0) < 1e-9 })
    }

    @Test("Rotation turns the artwork about the stamp's own anchor")
    func rotationIsAboutTheAnchor() {
        let turned = StampArtworkScene.placement(
            center: PDFPoint(x: 100, y: 100),
            size: PDFSize(width: 200, height: 100),
            rotationDegrees: 90
        )
        // Unit (1, 0.5) is the middle of the box's right edge: 100 pt right of the anchor
        // unrotated, and 100 pt above it after a quarter turn counter-clockwise.
        let point = turned(PDFPoint(x: 1, y: 0.5))
        #expect(abs(point.x - 100) < 1e-9)
        #expect(abs(point.y - 200) < 1e-9)
    }

    @Test("A stamp with no artwork still draws its fields")
    func fieldsOnlyStampIsStillDrawn() {
        let shapes = StampArtworkScene.markups(
            artwork: StampArtworkGeometry.empty,
            labels: Self.labels,
            center: PDFPoint(x: 0, y: 0),
            size: PDFSize(width: 160, height: 60),
            baseID: MarkupID(UUID())
        )
        #expect(shapes.count == 2)
        #expect(StampArtworkGeometry.empty.isEmpty)
        #expect(Self.artwork.primitiveCount == 2)
    }

    @Test("An empty resolved field draws nothing rather than an empty box")
    func emptyFieldsAreDropped() {
        let shapes = StampArtworkScene.markups(
            artwork: StampArtworkGeometry.empty,
            labels: [StampSceneLabel(text: "", normalizedFrame: PDFRect(x: 0, y: 0, width: 1, height: 1))],
            center: PDFPoint(x: 0, y: 0),
            size: PDFSize(width: 160, height: 60),
            baseID: MarkupID(UUID())
        )
        #expect(shapes.isEmpty)
    }
}

enum StampSceneTestError: Error { case noOutline }
