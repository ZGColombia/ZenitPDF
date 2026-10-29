import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// Why the goldens are believed to be right, asserted rather than asserted-about.
@Suite("Golden provenance", .serialized)
struct GoldenProvenanceTests {

    @Test("Every stroke-and-fill scene agrees with the independent coverage oracle")
    func coverageOracle() throws {
        var checked = 0
        for scene in SceneLibrary.goldens
        where ReferenceRasterizer.verifiableScenes.contains(scene.name) {
            let golden = try #require(Goldens.image(named: scene.name))
            let reference = ReferenceRasterizer.rasterize(scene)
            let result = GoldenProvenance.compare(image: golden, reference: reference)
            #expect(result.matches, "\(scene.name): \(result.summary)")
            checked += 1
        }
        #expect(checked == 22, "the oracle covered \(checked) scenes, expected 22")
    }

    @Test("The oracle is not vacuous: it rejects a golden that is off by one shape")
    func oracleRejectsADefect() throws {
        let scene = SceneLibrary.polygonWithHoles(holeCount: 3)
        // A scene with the holes removed is what a broken fill rule would produce.
        let broken = RenderScene(
            name: scene.name,
            purpose: scene.purpose,
            page: scene.page,
            markups: scene.markups.map { markup in
                guard case let .filledPolygon(polygon) = markup.shape else { return markup }
                var copy = markup
                copy.shape = .filledPolygon(RenderPolygon(outer: polygon.outer))
                return copy
            },
            viewport: scene.viewport
        )
        let brokenImage = try Goldens.render(broken, backend: .coreGraphics)
        let reference = ReferenceRasterizer.rasterize(scene)
        let result = GoldenProvenance.compare(image: brokenImage, reference: reference)
        #expect(!result.matches, "the oracle accepted a scene with its holes filled in")
    }

    @Test("Ink area of an axis-aligned rectangle equals its closed-form pixel area")
    func closedFormRectangle() throws {
        // No oracle, no supersampling: a 200 x 150 pt opaque rectangle at 100 % zoom on a
        // backing scale of 2 covers exactly 400 x 300 device pixels, and antialiasing along an
        // axis-aligned edge that lands on a pixel boundary adds nothing.
        let page = SceneIdentity.page()
        let markup = RenderableMarkup(
            id: MarkupID(UUID(uuidString: "F0F0F0F0-0000-0000-0000-000000000001") ?? UUID()),
            shape: .filledPolygon(RenderPolygon(outer: [
                PDFPoint(x: 100, y: 100), PDFPoint(x: 300, y: 100),
                PDFPoint(x: 300, y: 250), PDFPoint(x: 100, y: 250)
            ])),
            style: RenderStyle(stroke: nil, fill: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
        )
        let scene = RenderScene(
            name: "closed-form-rectangle",
            purpose: "",
            page: page,
            markups: [markup],
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 2.0)
        )
        for backend in RendererBackend.allCases {
            let image = try Goldens.render(scene, backend: backend)
            var ink = 0.0
            for index in 0..<(image.width * image.height) {
                ink += Double(image.pixels[index * 4 + 3]) / 255
            }
            let expected = 400.0 * 300.0
            #expect(abs(ink - expected) / expected < 1e-3, "\(backend): ink \(ink), expected \(expected)")
        }
    }

    @Test("Ink area of a hairline equals length times the one-pixel floor")
    func closedFormHairline() throws {
        // A 400 pt horizontal line of nominal width 0.01 pt at 5 % zoom: the geometry is
        // 20 device pixels long, and the width floor paints it exactly one pixel thick, so the
        // ink is 20. This is the assertion that the legibility floor is a *width* decision and
        // has not quietly become a geometry decision.
        let page = SceneIdentity.page()
        let markup = RenderableMarkup(
            id: MarkupID(UUID(uuidString: "F0F0F0F0-0000-0000-0000-000000000002") ?? UUID()),
            shape: .polyline(RenderPolyline(points: [
                PDFPoint(x: 100, y: 400), PDFPoint(x: 500, y: 400)
            ])),
            style: RenderStyle(
                stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                lineWidth: 0.01,
                startCap: .butt,
                endCap: .butt
            )
        )
        let scene = RenderScene(
            name: "closed-form-hairline",
            purpose: "",
            page: page,
            markups: [markup],
            viewport: RenderViewport.fittingWholePage(page, zoom: 0.05, backingScale: 1.0)
        )
        for backend in RendererBackend.allCases {
            let image = try Goldens.render(scene, backend: backend)
            var ink = 0.0
            for index in 0..<(image.width * image.height) {
                ink += Double(image.pixels[index * 4 + 3]) / 255
            }
            #expect(abs(ink - 20.0) < 1.0, "\(backend): ink \(ink), expected 20")
        }
    }

    @Test("A count symbol's ink is the atlas tile's ink, scaled")
    func symbolInkMatchesAtlas() throws {
        // The four scenes the coverage oracle cannot judge are the ones with atlas ink, so the
        // atlas ink itself is pinned here instead: a 64 pt filled circle covers pi/4 of its box.
        let page = SceneIdentity.page()
        let markup = RenderableMarkup(
            id: MarkupID(UUID(uuidString: "F0F0F0F0-0000-0000-0000-000000000003") ?? UUID()),
            shape: .countSymbol(RenderCountSymbol(
                center: PDFPoint(x: 300, y: 400),
                symbol: .filledCircle,
                size: 64
            )),
            style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
        )
        let scene = RenderScene(
            name: "closed-form-circle",
            purpose: "",
            page: page,
            markups: [markup],
            viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
        )
        // The symbol is drawn with an 8 % margin on each side, so the disc's diameter is
        // 64 * 0.84 device pixels and its area is pi/4 of that squared.
        let diameter = 64.0 * (1 - 2 * 0.08)
        let expected = Double.pi * diameter * diameter / 4
        for backend in RendererBackend.allCases {
            let image = try Goldens.render(scene, backend: backend)
            var ink = 0.0
            for index in 0..<(image.width * image.height) {
                ink += Double(image.pixels[index * 4 + 3]) / 255
            }
            #expect(abs(ink - expected) / expected < 0.06, "\(backend): ink \(ink), expected \(expected)")
        }
    }

    @Test("A label's ink is the same on both backends and is not empty")
    func textInkAgrees() throws {
        let page = SceneIdentity.page()
        var inks: [Double] = []
        for backend in RendererBackend.allCases {
            let markup = RenderableMarkup(
                id: MarkupID(UUID(uuidString: "F0F0F0F0-0000-0000-0000-000000000004") ?? UUID()),
                shape: .textLabel(RenderTextLabel(
                    anchorPoint: PDFPoint(x: 100, y: 400),
                    text: "1 284,75 m2",
                    fontName: "Helvetica",
                    fontSize: 24,
                    anchor: .topLeading
                )),
                style: RenderStyle(stroke: RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
            )
            let scene = RenderScene(
                name: "closed-form-text",
                purpose: "",
                page: page,
                markups: [markup],
                viewport: RenderViewport.fittingWholePage(page, zoom: 1.0, backingScale: 1.0)
            )
            let image = try Goldens.render(scene, backend: backend)
            var ink = 0.0
            for index in 0..<(image.width * image.height) {
                ink += Double(image.pixels[index * 4 + 3]) / 255
            }
            inks.append(ink)
        }
        #expect(inks.count == 2)
        #expect(inks[0] > 200, "the label produced almost no ink: \(inks[0])")
        #expect(abs(inks[0] - inks[1]) / inks[0] < 0.02, "backends disagree on text ink: \(inks)")
    }
}
