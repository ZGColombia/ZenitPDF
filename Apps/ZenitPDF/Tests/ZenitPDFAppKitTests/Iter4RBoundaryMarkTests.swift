import AppKit
import Foundation
import Testing
@testable import ZPDFAppCore
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Quality-loop iteration 4 re-fix, area "quantities-core", U-086: every boundary snap target is
/// drawn on the canvas.
///
/// U-086's first fix fed the snap index every visible Project Zone and Scale Region outline and
/// every calibration's picks while the canvas stroked none of them — a candidate from invisible
/// geometry (`QUALITY_BAR` S16). The canvas now draws the snapshot's `PageBoundaryMark`s, the list
/// the snap boundary layer is built from; this test drives the shipping document, window and
/// canvas, renders the page view off screen and compares what it drew with the snap layer.
@MainActor
@Suite("Iteration 4 re-fix quantities-core: boundary marks on the canvas (U-086)", .appTierSerialised)
struct Iter4RBoundaryMarkTests {

    static let zoneColour = ColorRGBA(red: 1, green: 0, blue: 0)
    static let regionColour = ColorRGBA(red: 0, green: 0, blue: 1)

    static func square(_ x: Double, _ y: Double, _ side: Double) -> [PDFPoint] {
        [PDFPoint(x: x, y: y), PDFPoint(x: x + side, y: y), PDFPoint(x: x + side, y: y + side), PDFPoint(x: x, y: y + side)]
    }

    /// Renders the page view's ink over `rect` (view space) and returns the bitmap.
    static func render(_ view: CanvasPageView, _ rect: CGRect) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// How many of 60 samples along the page-space segment `a`–`b` are drawn in `colour`
    /// (within a tolerance for antialiasing): the dashed outline covers about half of them.
    static func inked(_ rep: NSBitmapImageRep, _ rect: CGRect, _ transform: PageDisplayTransform,
                      from a: PDFPoint, to b: PDFPoint, colour: ColorRGBA) -> Int {
        let scale = CGFloat(rep.pixelsWide) / rect.width
        var hits = 0
        for step in 0..<60 {
            let t = (Double(step) + 0.5) / 60
            let page = PDFPointValue(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let view = transform.viewPoint(from: page)
            let x = Int(((view.x - rect.minX) * scale).rounded(.down)), y = Int(((view.y - rect.minY) * scale).rounded(.down))
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { continue }
            var pixel = [Int](repeating: 0, count: 4)
            rep.getPixel(&pixel, atX: x, y: y)
            let want = [colour.red, colour.green, colour.blue].map { Int($0 * 255) }
            guard pixel[3] > 100 else { continue }
            if zip(pixel.prefix(3), want).allSatisfy({ Swift.abs($0 - $1) < 110 }) { hits += 1 }
        }
        return hits
    }

    /// A calibration (300, 1 500) → (700, 1 500), a Scale Region (200, 400)–(600, 800) at the
    /// page scale and a Project Zone (900, 400)–(1 300, 800) on the A1 fixture. The canvas
    /// presenter hands the page view three marks; the off-screen ink pass draws exactly the snap
    /// boundary layer's identities, the zone's edge in red and the region's in blue, and the
    /// session's installed index resolves the pointer 1 pt inside the zone's bottom edge to that
    /// edge as zoneBoundary. Hiding the zone through the command bus takes it off the canvas and
    /// out of the snap layer in the same refresh.
    /// Old output: the page view had no marks, the ink pass drew no outline and no pick, and the
    /// snap layer held three targets nobody could see.
    @Test("U-086 (it4r): the canvas draws exactly the boundary snap targets")
    func drawnMarksAreTheSnapTargets() async throws {
        let harness = try await NLMeasureR2Harness.make("BoundaryMarks.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        let page = harness.page
        let canvas = try #require(harness.controller.canvasController(for: harness.document))
        // What showing the window does: arm the canvas's observation (the window is never
        // ordered in, so a test arms it by hand, as CoverageMapInAWindowTests does).
        canvas.viewDidAppear()
        try await core.commands.calibrate(page: page, first: PDFPoint(x: 300, y: 1_500), second: PDFPoint(x: 700, y: 1_500),
                                          knownLength: 10, knownLengthUnit: .metre)
        let scaleID = try #require(await core.session.scale(onPage: page)?.id)
        let region = ScaleRegionDefinition(
            id: ScaleRegionID(UUID()), pageID: page, name: "Detail", boundary: Self.square(200, 400, 400),
            scaleID: scaleID, priority: 1, colorRGBA: Self.regionColour
        )
        let zone = ProjectZoneDefinition(
            id: ZoneID(UUID()), name: "Level 1", kind: .room, pageID: page,
            boundary: Self.square(900, 400, 400), sortOrder: 0, colorRGBA: Self.zoneColour
        )
        try await core.commands.perform(.setScaleRegions([region]))
        try await core.commands.perform(.setProjectZones([zone]))
        await core.refresh()

        let view = canvas.pageViewForTesting
        #expect(await AppTestSupport.wait { view.boundaryMarks.count == 3 && view.transform != nil })
        let transform = try #require(view.transform)
        let targets = await core.session.snapBoundaries(onPage: page)
        #expect(view.boundaryMarks.map(\.id) == targets.map(\.id))
        #expect(view.boundaryMarks.map(\.snapBoundary) == targets)

        // The rectangle holding every mark, in view space.
        let corners = [PDFPoint(x: 150, y: 350), PDFPoint(x: 1_350, y: 350), PDFPoint(x: 1_350, y: 1_550), PDFPoint(x: 150, y: 1_550)]
            .map { transform.viewPoint(from: PDFPointValue(x: $0.x, y: $0.y)) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).integral

        var rep = try Self.render(view, rect)
        #expect(view.boundaryMarkIDsDrawnInLastPass == targets.map(\.id), "drawn \(view.boundaryMarkIDsDrawnInLastPass) targets \(targets.map(\.id))")
        let zoneInk = Self.inked(rep, rect, transform, from: PDFPoint(x: 900, y: 400), to: PDFPoint(x: 1_300, y: 400), colour: Self.zoneColour)
        let regionInk = Self.inked(rep, rect, transform, from: PDFPoint(x: 200, y: 400), to: PDFPoint(x: 600, y: 400), colour: Self.regionColour)
        #expect(zoneInk >= 10, "the zone's edge is drawn in its colour: \(zoneInk) of 60 samples")
        #expect(regionInk >= 10, "the region's edge is drawn in its colour: \(regionInk) of 60 samples")

        // The drawn zone edge is a target in the installed index.
        await core.session.resetSnapState()
        let layout = PageViewLayout(zoom: 1, backingScale: 2)
        let hit = try await core.session.resolveSnap(pageID: page, pagePoint: PDFPoint(x: 1_100, y: 401), layout: layout).winner
        #expect(hit?.kind == .zoneBoundary && (hit?.position.distance(to: PDFPoint(x: 1_100, y: 400)) ?? .infinity) <= 1e-9,
                "\(String(describing: hit?.kind)) \(String(describing: hit?.position))")

        var hidden = zone
        hidden.isVisible = false
        try await core.commands.perform(.setProjectZones([hidden]))
        await core.refresh()
        #expect(await AppTestSupport.wait { view.boundaryMarks.count == 2 })
        let remaining = await core.session.snapBoundaries(onPage: page)
        rep = try Self.render(view, rect)
        #expect(view.boundaryMarkIDsDrawnInLastPass == remaining.map(\.id))
        #expect(!remaining.contains { $0.id.hasPrefix("zone:") })
        #expect(Self.inked(rep, rect, transform, from: PDFPoint(x: 900, y: 400), to: PDFPoint(x: 1_300, y: 400), colour: Self.zoneColour) == 0,
                "a hidden zone is not drawn")
        await core.session.resetSnapState()
        let after = try await core.session.resolveSnap(pageID: page, pagePoint: PDFPoint(x: 1_100, y: 401), layout: layout).winner
        #expect(after?.kind != .zoneBoundary, "a hidden zone is no target")
    }
}
