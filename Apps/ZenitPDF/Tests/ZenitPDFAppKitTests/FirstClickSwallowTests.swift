import AppKit
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// LT-6, 2026-08-29: the first canvas click after a key event (Escape,
/// Return) or a tool pick kept disappearing — an area became a triangle, a count of four
/// clicks landed three marks. Human-speed clicking means each click's async snap placement
/// usually settles before the next; the live session clicked faster. These reproductions
/// drive the application's own wiring at machine speed, with no settle between clicks,
/// and demand that every click lands.
@MainActor
@Suite(.appTierSerialised)
struct FirstClickSwallowTests {

    private func makeHarness(
        _ name: String
    ) async throws -> (ZenitPDFProjectDocument, ProjectWindowController, AppCoreEnvironment, ProjectShellEnvironment, PDFCanvasViewController) {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let canvas = try #require(controller.canvasController(for: document))
        _ = canvas.view
        canvas.viewDidAppear()
        _ = try await core.commands.calibrate(
            page: try #require(await core.session.firstPageID),
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 1,
            knownLengthUnit: .metre
        )
        await core.refresh()
        return (document, controller, core, shell, canvas)
    }

    @Test("Escape, re-arm, four fast clicks: all four land — none swallowed")
    func escapeThenFastClicksAllLand() async throws {
        let (document, _, core, shell, canvas) = try await makeHarness("Swallow1.pdf")
        defer { document.close() }

        // Half-draw an area, Escape it — the live gesture that preceded every swallow.
        shell.perform(.measureArea)
        canvas.handleClick(at: PDFPointValue(x: 500, y: 500), additive: false)
        canvas.handleClick(at: PDFPointValue(x: 550, y: 500), additive: false)
        _ = canvas.handle(key: .escape)

        // Re-arm and click four corners at machine speed — no settling between clicks,
        // exactly like the live session (and a fast human hand).
        shell.perform(.measureCount)
        for vertex in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 200, y: 100),
            PDFPointValue(x: 200, y: 200),
            PDFPointValue(x: 100, y: 200)
        ] {
            canvas.handleClick(at: vertex, additive: false)
        }
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 4,
                "four clicks placed \(core.measurement.placedPoints.count) marks — a click was swallowed")
    }

    @Test("Return-commit, then four fast clicks of the next area: all four land")
    func commitThenFastClicksAllLand() async throws {
        let (document, _, core, shell, canvas) = try await makeHarness("Swallow2.pdf")
        defer { document.close() }

        shell.perform(.measureArea)
        for vertex in [
            PDFPointValue(x: 500, y: 500),
            PDFPointValue(x: 700, y: 500),
            PDFPointValue(x: 700, y: 700),
            PDFPointValue(x: 500, y: 700)
        ] {
            canvas.handleClick(at: vertex, additive: false)
        }
        await core.measurement.settlePlacements()
        _ = canvas.handle(key: .finish)

        // Immediately draw the next one — the reuse-tool promise — with no pause after
        // Return. Every corner must land in the NEW measurement.
        for vertex in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 300, y: 100),
            PDFPointValue(x: 300, y: 300),
            PDFPointValue(x: 100, y: 300)
        ] {
            canvas.handleClick(at: vertex, additive: false)
        }
        await core.measurement.settlePlacements()
        #expect(core.measurement.placedPoints.count == 4,
                "after Return, four clicks placed \(core.measurement.placedPoints.count) — the commit ate the first")
    }
}
