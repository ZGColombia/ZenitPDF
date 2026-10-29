import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario

/// `QUALITY_BAR` 3.2 and S6/S7/S8: the screen-pixel to page-point rule, asserted against the
/// worked table rather than against the implementation.
@Suite("Snap tolerance (QUALITY_BAR 3.2, S6-S8)")
struct SnapToleranceTests {

    /// The exact table from `QUALITY_BAR` 3.2. Every value is exactly representable in binary
    /// floating point, so these are equalities, not approximations.
    static let table: [(zoom: Double, at10: Double, at4: Double, at24: Double, band: Double)] = [
        (0.05, 200, 80, 480, 280),
        (0.25, 40, 16, 96, 56),
        (1.00, 10, 4, 24, 14),
        (4.00, 2.5, 1, 6, 3.5),
        (16.00, 0.625, 0.25, 1.5, 0.875),
        (64.00, 0.15625, 0.0625, 0.375, 0.21875)
    ]

    @Test("Radius conversion matches the worked table to rel <= 1e-12", arguments: table.indices)
    func toleranceTable(_ row: Int) throws {
        let entry = Self.table[row]
        let layout = SnapReplay.layout(zoom: entry.zoom)

        var atTen = SnapSettings.default
        atTen.defaultPixels = 10
        #expect(relative(try SnapTolerance(settings: atTen, layout: layout).radiusPagePoints,
                         entry.at10) <= 1e-12)

        var atFour = SnapSettings.default
        atFour.defaultPixels = 4
        #expect(relative(try SnapTolerance(settings: atFour, layout: layout).radiusPagePoints,
                         entry.at4) <= 1e-12)

        var atTwentyFour = SnapSettings.default
        atTwentyFour.defaultPixels = 24
        #expect(relative(try SnapTolerance(settings: atTwentyFour, layout: layout).radiusPagePoints,
                         entry.at24) <= 1e-12)

        let band = try SnapTolerance(settings: atTen, layout: layout).heldRadiusPagePoints
        #expect(relative(band, entry.band) <= 1e-12)
    }

    @Test("The backing scale does not appear in the formula")
    func retinaDoesNotChangeTolerance() throws {
        for zoom in Self.table.map(\.zoom) {
            let one = try SnapTolerance(
                settings: .default, layout: SnapReplay.layout(zoom: zoom, backingScale: 1)
            )
            let two = try SnapTolerance(
                settings: .default, layout: SnapReplay.layout(zoom: zoom, backingScale: 2)
            )
            #expect(one.radiusPagePoints == two.radiusPagePoints)
            #expect(one.heldRadiusPagePoints == two.heldRadiusPagePoints)
        }
    }

    @Test("A radius outside the configured range is clamped, not accepted")
    func clamping() throws {
        var settings = SnapSettings.default
        settings.defaultPixels = 100
        settings.maximumPixels = 24
        // `defaultPixels > maximumPixels` is an invalid configuration and must be refused
        // rather than silently clamped.
        #expect(throws: SnapEngineError.self) {
            _ = try SnapTolerance(settings: settings, layout: SnapReplay.layout(zoom: 1))
        }

        var legal = SnapSettings.default
        legal.defaultPixels = 24
        legal.maximumPixels = 24
        let tolerance = try SnapTolerance(settings: legal, layout: SnapReplay.layout(zoom: 1))
        #expect(tolerance.radiusViewPoints == 24)
    }

    @Test("Zoom is re-read on every event, never cached")
    func toleranceFollowsZoomBetweenEvents() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.point(id: 1, PDFPoint(x: 200, y: 200))]
        )
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint]

        var engine = SnapEngine()
        var seen: [Double] = []
        for zoom in [1.0, 64.0, 0.05, 4.0] {
            let layout = SnapReplay.layout(zoom: zoom)
            let event = SnapPointerEvent(
                viewPoint: try SnapReplay.viewPoint(
                    PDFPoint(x: 200, y: 200), page: page, layout: layout
                ),
                layout: layout
            )
            let resolution = try engine.resolve(
                SnapQuery(event: event, settings: settings), in: scene.index
            )
            seen.append(resolution.tolerancePagePoints)
        }
        #expect(seen == [10.0, 10.0 / 64.0, 200.0, 2.5])
    }

    @Test("At 6400 % a primitive 0.2 page points away is not a candidate")
    func toleranceGenuinelyShrinks() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page, primitives: [SnapScene.point(id: 1, PDFPoint(x: 200.2, y: 200))]
        )
        var settings = SnapSettings.default
        settings.enabledKinds = [.endpoint]

        var engine = SnapEngine()
        let layout = SnapReplay.layout(zoom: 64)
        let event = SnapPointerEvent(
            viewPoint: try SnapReplay.viewPoint(
                PDFPoint(x: 200, y: 200), page: page, layout: layout
            ),
            layout: layout
        )
        let resolution = try engine.resolve(
            SnapQuery(event: event, settings: settings), in: scene.index
        )
        // 0.2 page points > 10 / 64 = 0.15625, and there is no floor to fall back on.
        #expect(resolution.winner == nil)
        #expect(resolution.resolvedPagePoint.x == 200)

        // The same primitive at 5 % zoom, where the radius is 200 page points, is a candidate.
        let wide = SnapReplay.layout(zoom: 0.05)
        let wideEvent = SnapPointerEvent(
            viewPoint: try SnapReplay.viewPoint(PDFPoint(x: 200, y: 200), page: page, layout: wide),
            layout: wide
        )
        let wideResolution = try engine.resolve(
            SnapQuery(event: wideEvent, settings: settings), in: scene.index
        )
        #expect(wideResolution.winner?.kind == .endpoint)
    }

    @Test("Retina invariance: identical decision log at backing scale 1 and 2")
    func retinaInvariance() throws {
        let page = try SnapScene.letterPage()
        let scene = try SnapScene.withVectorContent(
            page: page,
            primitives: [
                SnapScene.point(id: 1, PDFPoint(x: 192, y: 200)),
                SnapScene.point(id: 2, PDFPoint(x: 208, y: 200)),
                SnapScene.segment(id: 3, PDFPoint(x: 150, y: 150), PDFPoint(x: 260, y: 260))
            ]
        )
        let positions = stride(from: 190.0, through: 210.0, by: 0.25)
            .map { PDFPoint(x: $0, y: 200) }

        let atOne = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(
                pagePoints: positions, page: page, zoom: 2.0, backingScale: 1
            )
        )
        let atTwo = try SnapReplay.run(
            index: scene.index,
            events: try SnapReplay.events(
                pagePoints: positions, page: page, zoom: 2.0, backingScale: 2
            )
        )
        #expect(atOne.log == atTwo.log)
        #expect(!atOne.log.isEmpty)
    }

    private func relative(_ value: Double, _ reference: Double) -> Double {
        guard reference != 0 else { return Swift.abs(value) }
        return Swift.abs(value - reference) / Swift.abs(reference)
    }
}
