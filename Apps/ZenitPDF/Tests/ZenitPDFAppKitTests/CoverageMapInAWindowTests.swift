import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// The coverage map, end to end in a real window: View-menu flag on the presenter in, tinted
/// regions and an honest percentage badge out, and off means *gone*, not stale.
///
/// The window is real and never ordered on screen.
@MainActor
@Suite(.appTierSerialised)
struct CoverageMapInAWindowTests {

    @MainActor
    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let canvas: PDFCanvasViewController
        let window: NSWindow
        let directory: URL

        func tearDown() {
            window.contentViewController = nil
            document.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeHarness() async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: "coverage-window")
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        await core.refresh()

        let canvas = PDFCanvasViewController(
            core: core,
            rasterSource: document.drawing?.rasterSource,
            toolbar: shell.toolbar
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.contentViewController = canvas
        canvas.viewDidAppear()
        return Harness(
            document: document,
            core: core,
            canvas: canvas,
            window: window,
            directory: url.deletingLastPathComponent()
        )
    }

    private func addAreaMarkup(_ harness: Harness) async throws {
        let core = harness.core
        let pageID = try #require(await core.session.firstPageID)
        let documentID = await core.session.documentID
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let markup = MarkupRecord(
            id: MarkupID(UUID()),
            documentID: documentID,
            pageID: pageID,
            kind: .measurement,
            tool: .area,
            subject: "Coverage fixture",
            style: .default,
            geometry: MeasurementGeometry(
                pageID: pageID,
                polygons: [PolygonGeometry(outer: PolygonRing(points: [
                    PDFPoint(x: 100, y: 100),
                    PDFPoint(x: 300, y: 100),
                    PDFPoint(x: 300, y: 250),
                    PDFPoint(x: 100, y: 250)
                ], isClosed: true))]
            ),
            createdAt: now,
            modifiedAt: now
        )
        _ = try await core.session.apply(.addMarkup(markup))
        await core.refresh()
    }

    @Test("Toggling the map on tints the measured region and names the fraction; off removes it")
    func toggleDrawsAndRemoves() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }
        try await addAreaMarkup(harness)

        #expect(harness.canvas.coverageOverlayForTesting == nil,
                "the map is opt-in: nothing may be drawn before the toggle")

        harness.core.canvas.showsCoverageMap = true
        #expect(await AppTestSupport.wait { harness.canvas.coverageOverlayForTesting != nil },
                "the toggle never reached the page view")
        let overlay = try #require(harness.canvas.coverageOverlayForTesting)
        #expect(!overlay.rings.isEmpty, "a measured area must produce a tinted region")
        #expect(overlay.label.contains("%"),
                "the badge must state the fraction in text — tint alone is colour-only status")

        harness.core.canvas.showsCoverageMap = false
        #expect(await AppTestSupport.wait { harness.canvas.coverageOverlayForTesting == nil },
                "off must remove the overlay, not leave it stale")
    }

    @Test("A page with no measurements shows the map as zero, not as an error")
    func emptyPageIsZero() async throws {
        let harness = try await makeHarness()
        defer { harness.tearDown() }

        harness.core.canvas.showsCoverageMap = true
        #expect(await AppTestSupport.wait { harness.canvas.coverageOverlayForTesting != nil })
        let overlay = try #require(harness.canvas.coverageOverlayForTesting)
        #expect(overlay.rings.isEmpty)
        #expect(overlay.label.contains("0"), "an unmeasured page is honestly 0 %")
    }
}
