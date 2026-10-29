import AppKit
import Foundation
import Testing
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// LT-9, 2026-08-29: a cutout drawn in the running application could not
/// be committed — Return (twice) and double-click did nothing; the mode sat until Escape.
/// `CutoutInAWindowTests` never caught it because its harness *replaces* `onShellCommand`
/// with its own finisher. This suite keeps the application's own wiring: the real
/// `ProjectWindowController` installs the canvas, and Finish travels the same
/// `performShell → shell.perform(.finishGeometry) → commitActiveMeasurement` road a Return
/// key travels.
@MainActor
@Suite(.appTierSerialised)
struct CutoutCommitLiveWiringTests {

    @Test("Return's finish path commits a cutout through the application's own wiring")
    func finishKeyCommitsACutout() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "CutoutLive.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try AppTestSupport.makeDocument(opening: url)
        let controller = ProjectWindowController(document: document)
        #expect(await AppTestSupport.wait { document.core != nil && document.shell != nil })
        document.addWindowController(controller)
        #expect(await AppTestSupport.wait { controller.canvasController(for: document) != nil })
        let core = try #require(document.core)
        let shell = try #require(document.shell)
        let canvas = try #require(controller.canvasController(for: document))
        // The window is never ordered on screen; the observation the running app gets from
        // its real appearance is started by hand, exactly as CutoutInAWindowTests does.
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

        // The parent area, drawn through the same click path the pointer uses and finished
        // through the same key path Return uses.
        shell.perform(.measureArea)
        for vertex in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 400, y: 100),
            PDFPointValue(x: 400, y: 400),
            PDFPointValue(x: 100, y: 400)
        ] {
            canvas.handleClick(at: vertex, additive: false)
            await core.measurement.settlePlacements()
        }
        #expect(canvas.handle(key: .finish), "Finish must be accepted with four points down")
        var areaCommitted = false
        for _ in 0..<100 {
            if await core.session.orderedMarkups.contains(where: { $0.tool == .area }) {
                areaCommitted = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(areaCommitted, "the parent area never committed through the app wiring")

        // The canvas needs its observation pass to learn the parent list.
        #expect(await AppTestSupport.wait(upTo: 10) {
            canvas.cutoutCandidateCountForTesting > 0
        })

        shell.perform(.cutoutTool)
        for vertex in [
            PDFPointValue(x: 200, y: 200),
            PDFPointValue(x: 300, y: 200),
            PDFPointValue(x: 300, y: 300),
            PDFPointValue(x: 200, y: 300)
        ] {
            canvas.handleClick(at: vertex, additive: false)
            await core.measurement.settlePlacements()
        }
        #expect(core.measurement.canCommit,
                "four placed cutout vertices must be committable")

        // THE defect line: Return in the running app.
        #expect(canvas.handle(key: .finish), "the canvas must accept Finish for a cutout")
        var committed = false
        for _ in 0..<100 {
            let markups = await core.session.orderedMarkups
            if markups.contains(where: { $0.parentMarkupID != nil }) { committed = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(committed, "LT-9: the cutout never committed through the application's own wiring")

        document.close()
    }

    @Test("A doubled first vertex never leaves the tool stuck in silence (LT-9's root)")
    func duplicateVertexNeverSticksSilently() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "CutoutDup.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
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

        // The live gesture, exactly: the first vertex clicked twice (the focus-swallow
        // workaround a person lands on), then the rest of the square.
        shell.perform(.measureArea)
        for vertex in [
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 100, y: 100),
            PDFPointValue(x: 400, y: 100),
            PDFPointValue(x: 400, y: 400),
            PDFPointValue(x: 100, y: 400)
        ] {
            canvas.handleClick(at: vertex, additive: false)
            await core.measurement.settlePlacements()
        }
        let commitable = core.measurement.canCommit
        _ = canvas.handle(key: .finish)
        var committed = false
        for _ in 0..<60 {
            if await core.session.orderedMarkups.contains(where: { $0.tool == .area }) {
                committed = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Either the duplicate is tolerated and the commit lands, or the refusal is SPOKEN.
        // A silent nothing is the defect.
        #expect(committed,
                "canCommit=\(commitable): a doubled first vertex left the tool stuck in silence")
        document.close()
    }
}
