import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

@Suite("Raster image")
struct RasterImageTests {

    private func checkerboard(width: Int, height: Int) -> RasterImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let on = (x / 3 + y / 3) % 2 == 0
                pixels[offset] = on ? 200 : 20
                pixels[offset + 1] = on ? 60 : 180
                pixels[offset + 2] = on ? 30 : 90
                pixels[offset + 3] = 255
            }
        }
        return RasterImage(width: width, height: height, pixels: pixels)!
    }

    @Test("PNG encoding and decoding round trips byte for byte")
    func pngRoundTrip() throws {
        let original = checkerboard(width: 37, height: 23)
        let data = try #require(original.pngData())
        let decoded = try #require(RasterImage.fromPNG(data))
        #expect(decoded.width == original.width)
        #expect(decoded.height == original.height)
        #expect(decoded.pixels == original.pixels)
    }

    @Test("A malformed size or byte count is rejected rather than trusted")
    func rejectsBadInput() {
        #expect(RasterImage(width: 0, height: 4, pixels: []) == nil)
        #expect(RasterImage(width: 4, height: 4, pixels: [0, 1, 2]) == nil)
        #expect(RasterImage.fromPNG(Data([0, 1, 2, 3])) == nil)
        #expect(RasterImage.fromBGRA(width: 2, height: 2, bytes: [0]) == nil)
    }

    @Test("BGRA readback is swizzled to RGBA")
    func bgraSwizzle() throws {
        let bgra: [UInt8] = [10, 20, 30, 40]
        let image = try #require(RasterImage.fromBGRA(width: 1, height: 1, bytes: bgra))
        #expect(image.pixel(x: 0, y: 0) == (30, 20, 10, 40))
    }

    @Test("Sampling outside the image returns transparent black rather than trapping")
    func outOfBounds() {
        let image = checkerboard(width: 4, height: 4)
        #expect(image.pixel(x: -1, y: 0) == (0, 0, 0, 0))
        #expect(image.pixel(x: 0, y: 99) == (0, 0, 0, 0))
        #expect(image.alpha(x: 99, y: 99) == 0)
    }
}

/// The comparator has to pass a legitimate backend difference and fail a structural one. Both
/// halves are asserted; a comparator that only ever passes is worse than none.
@Suite("Image comparator")
struct ImageComparatorTests {

    private func render(_ scene: RenderScene) throws -> RasterImage {
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        return try scene.render(with: renderer)
    }

    private func mutated(
        _ scene: RenderScene,
        _ transform: ([RenderableMarkup]) -> [RenderableMarkup]
    ) -> RenderScene {
        RenderScene(
            name: scene.name,
            purpose: scene.purpose,
            page: scene.page,
            markups: transform(scene.markups),
            selection: scene.selection,
            snapFeedback: scene.snapFeedback,
            viewport: scene.viewport
        )
    }

    @Test("An image compared with itself matches, with every term at zero")
    func identity() throws {
        let image = try render(SceneLibrary.mixed200())
        let result = ImageComparator.compare(image, image)
        #expect(result.matches)
        #expect(result.maximumChannelDifference == 0)
        #expect(result.maximumTileCoverageDifference == 0)
        #expect(abs(result.inkRatio - 1) < 1e-12)
    }

    @Test("A size mismatch fails immediately and says so")
    func sizeMismatch() throws {
        let a = try render(SceneLibrary.polygonWithHoles(holeCount: 1))
        let b = try render(SceneLibrary.dashesAndCaps(zoom: 0.05, name: "x"))
        let result = ImageComparator.compare(a, b)
        #expect(!result.matches)
        #expect(result.failureReasons.contains { $0.contains("size mismatch") })
    }

    @Test("A single missing markup out of two hundred fails the structural term")
    func missingShapeFails() throws {
        let scene = SceneLibrary.mixed200()
        let full = try render(scene)
        // Drop one filled polygon — a shape occupying well under a per cent of the page.
        let index = try #require(scene.markups.firstIndex { markup in
            if case .filledPolygon = markup.shape { return true }
            return false
        })
        let reduced = try render(mutated(scene) { markups in
            var copy = markups
            copy.remove(at: index)
            return copy
        })
        let result = ImageComparator.compare(full, reduced)
        #expect(!result.matches, "a missing shape passed: \(result.summary)")
        #expect(result.maximumTileCoverageDifference > ImageComparator.tileCoverageTolerance)
    }

    @Test("A hole that is filled in fails, which is the wrong-fill-rule detector")
    func wrongFillRuleFails() throws {
        let withHoles = try render(SceneLibrary.polygonWithHoles(holeCount: 3))
        let scene = SceneLibrary.polygonWithHoles(holeCount: 3)
        let withoutHoles = try render(mutated(scene) { markups in
            markups.map { markup in
                guard case let .filledPolygon(polygon) = markup.shape else { return markup }
                var copy = markup
                copy.shape = .filledPolygon(RenderPolygon(outer: polygon.outer))
                return copy
            }
        })
        let result = ImageComparator.compare(withHoles, withoutHoles)
        #expect(!result.matches, "an ignored fill rule passed: \(result.summary)")
    }

    @Test("A dash pattern at the wrong scale fails")
    func misScaledDashFails() throws {
        let scene = SceneLibrary.dashesAndCaps(zoom: 1.0, name: "d")
        let correct = try render(scene)
        let stretched = try render(mutated(scene) { markups in
            markups.map { markup in
                guard case let .pattern(runs, phase) = markup.style.dash else { return markup }
                var copy = markup
                copy.style.dash = .pattern(runs: runs.map { $0 * 1.25 }, phase: phase)
                return copy
            }
        })
        let result = ImageComparator.compare(correct, stretched)
        #expect(!result.matches, "a mis-scaled dash passed: \(result.summary)")
    }

    @Test("A one-pixel translation of the whole scene fails")
    func translationFails() throws {
        let scene = SceneLibrary.self_touchingForTest()
        let original = try render(scene)
        let shifted = try render(mutated(scene) { markups in
            markups.map { markup in
                guard case let .filledPolygon(polygon) = markup.shape else { return markup }
                var copy = markup
                copy.shape = .filledPolygon(RenderPolygon(
                    outer: polygon.outer.map { PDFPoint(x: $0.x + 3, y: $0.y) },
                    holes: polygon.holes.map { $0.map { PDFPoint(x: $0.x + 3, y: $0.y) } }
                ))
                return copy
            }
        })
        let result = ImageComparator.compare(original, shifted)
        #expect(!result.matches, "a three-point shift passed: \(result.summary)")
    }

    @Test("A uniform small colour shift passes, because that is a legitimate backend difference")
    func smallColourShiftPasses() throws {
        let image = try render(SceneLibrary.polygonWithHoles(holeCount: 2))
        var nudged = image.pixels
        for index in stride(from: 0, to: nudged.count, by: 4) {
            // Two levels out of 255 on every colour channel, alpha untouched.
            for channel in 0..<3 {
                let value = Int(nudged[index + channel])
                nudged[index + channel] = UInt8(Swift.min(255, value + 2))
            }
        }
        let shifted = try #require(
            RasterImage(width: image.width, height: image.height, pixels: nudged)
        )
        let result = ImageComparator.compare(image, shifted)
        #expect(result.matches, "\(result.summary)")
    }
}

extension SceneLibrary {
    /// A stable alias so the comparator tests do not depend on the golden list's ordering.
    static func self_touchingForTest() -> RenderScene { selfTouchingPolygons() }
}
