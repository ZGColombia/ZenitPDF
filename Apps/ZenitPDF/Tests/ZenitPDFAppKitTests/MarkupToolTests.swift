import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIMeasurement
import ZPDFUIPresentation
import ZPDFUIShell
@testable import ZenitPDFAppKit

/// The Text, Callout and Shapes tools, driven through the shipping
/// `PDFCanvasViewController` — the same handlers `CanvasPageView` calls from a real mouse.
///
/// Each tool is asserted on the four things its acceptance criteria ask for:
/// the markup **type** it produces, its **geometry**, its **ledger consequence**, and one
/// `⌘Z`. Survival through save → reopen is the last test in the file.
@MainActor
@Suite(.appTierSerialised)
struct MarkupToolTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    private struct Harness {
        let document: ZenitPDFProjectDocument
        let core: AppCoreEnvironment
        let shell: ProjectShellEnvironment
        let canvas: PDFCanvasViewController
        let directory: URL
    }

    /// A loaded drawing, calibrated 100 pt = 1 m, with the shipping canvas over it.
    ///
    /// Calibrated on purpose: a shape must stay out of the Quantity Ledger because it is a
    /// markup, not because the drawing has no scale.
    private func makeHarness(named name: String) async throws -> Harness {
        let url = try AppTestSupport.writeFixturePDF(named: name)
        let document = try AppTestSupport.makeDocument(opening: url)
        #expect(await wait { document.core != nil && document.shell != nil })
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
        _ = canvas.view
        canvas.onShellCommand = { command in shell.perform(command) }
        return Harness(
            document: document,
            core: core,
            shell: shell,
            canvas: canvas,
            directory: url.deletingLastPathComponent()
        )
    }

    private func markups(_ core: AppCoreEnvironment) async -> [ZPDFContracts.MarkupRecord] {
        await core.session.orderedMarkups
    }

    /// The markup count as the presenters see it — synchronous, so it can be polled.
    ///
    /// Every applied command refreshes the environment from a fresh snapshot, so this
    /// number lands exactly when the canvas and the ledger do.
    private func markupCount(_ core: AppCoreEnvironment) -> Int {
        core.snapshot.markups.count
    }

    /// Arms a shape through the toolbar — the seam, not the presenter — and lets the canvas
    /// pick it up.
    private func arm(_ kind: ZPDFUIPresentation.MarkupKind, _ harness: Harness) {
        if kind == .text {
            harness.shell.perform(.textTool)
        } else if kind == .callout {
            harness.shell.perform(.calloutTool)
        } else {
            harness.shell.toolbar.activateShape(kind)
        }
        harness.canvas.refresh()
        #expect(harness.canvas.armedMode == .markup(kind),
                "\(kind.rawValue) was armed in the toolbar and the canvas did not hear it")
    }

    // MARK: - Shapes

    @Test("Press-drag-release draws each two-point shape, with the geometry it will be drawn from")
    func twoPointShapesCommitOnRelease() async throws {
        let harness = try await makeHarness(named: "Shapes.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        let cases: [(ZPDFUIPresentation.MarkupKind, ZPDFContracts.MarkupKind)] = [
            (.rectangle, .rectangle), (.ellipse, .ellipse), (.line, .line), (.arrow, .arrow)
        ]
        var expected = 0
        for (shown, stored) in cases {
            arm(shown, harness)
            harness.canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 100))
            harness.canvas.handleDragMoved(to: PDFPointValue(x: 300, y: 220))
            harness.canvas.handleDragEnded(at: PDFPointValue(x: 300, y: 220))
            expected += 1
            #expect(await wait { self.markupCount(harness.core) == expected },
                    "\(shown.rawValue): the release must commit the shape")

            let record = try #require(await markups(harness.core).last)
            #expect(record.kind == stored, "\(shown.rawValue) produced a \(record.kind.rawValue)")
            #expect(record.tool == nil, "a shape is a markup, not a measurement")
            switch stored {
            case .rectangle:
                let ring = try #require(record.geometry?.polygons.first?.outer.points)
                #expect(ring.count == 4)
                #expect(ring.map(\.x).min() == 100 && ring.map(\.x).max() == 300)
                #expect(ring.map(\.y).min() == 100 && ring.map(\.y).max() == 220)
            default:
                let points = try #require(record.geometry?.points)
                #expect(points.count == 2)
                #expect(points[0].x == 100 && points[1].x == 300)
            }
            // Reuse Tool is **on** by default since 2026-08-26, so the tool stays armed and
            // the next shape can be drawn without re-picking it. This assertion used to say
            // `.select` and so pinned the behaviour that made every shape a two-step job.
            #expect(harness.shell.toolbar.activeTool == .shapes)
        }

        // The ledger consequence: none of them. "No row in the ledger unless the user gives
        // it a subject" — and the drawing *is* calibrated, so this is about the markup
        // being a markup, not about a missing scale.
        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 0)

        // One ⌘Z takes the last shape back, through the document's own undo manager.
        let undoManager = try #require(harness.document.undoManager)
        #expect(await wait { undoManager.canUndo })
        undoManager.undo()
        #expect(await wait { self.markupCount(harness.core) == expected - 1 },
                "one undo, one shape back")
    }

    @Test("Click-per-vertex draws the poly shapes, finishing on their own terms")
    func polyShapesFinishOnTheirOwnTerms() async throws {
        let harness = try await makeHarness(named: "Poly.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        // Polyline: open, finished with Return.
        arm(.polyline, harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 100), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 200, y: 140), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 260, y: 90), additive: false)
        #expect(harness.core.markup.placedPoints.count == 3,
                "a polyline keeps collecting — it has no completing count")
        #expect(harness.canvas.handle(key: .finish))
        #expect(await wait { self.markupCount(harness.core) == 1 })
        var record = try #require(await markups(harness.core).last)
        #expect(record.kind == .polyline)
        #expect(record.geometry?.points.count == 3)
        #expect(record.geometry?.polygons.isEmpty == true, "a polyline is open, not a ring")

        // Polygon: closes on its first vertex, exactly like an Area.
        arm(.polygon, harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 100, y: 300), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 300), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 300, y: 420), additive: false)
        harness.canvas.handlePointerMove(PDFPointValue(x: 101, y: 301))
        #expect(harness.canvas.firstVertexCloseTarget() != nil,
                "the close ring must be offered on a polygon markup, not only on an Area")
        harness.canvas.handleClick(at: PDFPointValue(x: 101, y: 301), additive: false)
        #expect(await wait { self.markupCount(harness.core) == 2 })
        record = try #require(await markups(harness.core).last)
        #expect(record.kind == .polygon)
        #expect(record.geometry?.polygons.first?.outer.points.count == 3)

        // Cloud: the same collection, a scalloped outline when it is drawn.
        arm(.cloud, harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 300), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 520, y: 300), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 520, y: 400), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 400, y: 400), additive: false)
        #expect(harness.canvas.handleSecondaryClick(),
                "a secondary click finishes a variable-vertex markup, and never opens a menu")
        #expect(await wait { self.markupCount(harness.core) == 3 })
        record = try #require(await markups(harness.core).last)
        #expect(record.kind == .cloud)
        #expect(record.style.lineStyle == .cloud)
        let ring = try #require(record.geometry?.polygons.first?.outer.points.map {
            PDFPointValue(x: $0.x, y: $0.y)
        })
        #expect(ring.count == 4)
        let outline = ZenitMarkupGeometry.cloudOutline(
            ring,
            radius: CanvasSceneBuilder.cloudScallopRadius(of: ring)
        )
        #expect(outline.count > ring.count, "a cloud is drawn scalloped, not as a plain rectangle")

        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 0, "poly shapes are markups too")
    }

    // MARK: - Text

    @Test("Text: a click opens a box with the caret in it, typing shows, Escape commits")
    func textToolPlacesAnEditableBox() async throws {
        let harness = try await makeHarness(named: "Text.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        arm(.text, harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 120, y: 500), additive: false)
        let entry = try #require(harness.canvas.activeTextEntry,
                                 "a click must open an editable box, not select a markup")
        #expect(entry.kind == .text)
        #expect(entry.box.size.width > 0 && entry.box.size.height > 0,
                "the caret needs a box to live in")
        #expect(entry.box.minX == 120)

        harness.canvas.typeIntoTextEntry("Rivning")
        #expect(harness.core.markup.draftText == "Rivning")

        harness.canvas.commitTextEntry()
        #expect(await wait { self.markupCount(harness.core) == 1 })
        let record = try #require(await markups(harness.core).last)
        #expect(record.kind == .text)
        #expect(record.caption == "Rivning", "the typed string is what the markup carries")
        #expect(record.geometry?.points.count == 2, "a text box is stored as its two corners")
        #expect(harness.canvas.activeTextEntry == nil)

        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 0)

        // It draws: a text markup has no outline, and dropping shapeless records is how it
        // used to become invisible the moment it was committed.
        let scene = CanvasSceneBuilder.build(
            records: await markups(harness.core),
            summaries: harness.core.canvas.visibleMarkups,
            pageID: harness.core.canvas.viewport.pageID
        )
        #expect(scene.count == 1)
        #expect(scene[0].text == "Rivning")
        #expect(scene[0].textBox != nil)

        let undoManager = try #require(harness.document.undoManager)
        #expect(await wait { undoManager.canUndo })
        undoManager.undo()
        #expect(await wait { self.markupCount(harness.core) == 0 })
    }

    @Test("Text: a drag defines the box, and empty text discards the markup")
    func textDragDefinesTheBoxAndEmptyTextDiscards() async throws {
        let harness = try await makeHarness(named: "TextEmpty.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        arm(.text, harness)
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 200, y: 600))
        harness.canvas.handleDragMoved(to: PDFPointValue(x: 380, y: 640))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 380, y: 640))
        let entry = try #require(harness.canvas.activeTextEntry)
        #expect(entry.box.size.width == 180 && entry.box.size.height == 40,
                "the drag defines the box the caret sits in")

        // Nothing typed: Escape must leave no markup at all — an invisible empty text box
        // is worse than no text box.
        #expect(harness.canvas.handle(key: .escape))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await markups(harness.core).isEmpty, "empty text discards the markup")
        #expect(harness.canvas.activeTextEntry == nil)
        #expect(harness.core.markup.draftText.isEmpty)
        #expect(harness.core.markup.placedPoints.isEmpty,
                "a discarded text box leaves nothing behind, not even a half-placed box")
    }

    // MARK: - Callout

    @Test("Callout: target point, then box — one leader, one editable string")
    func calloutPlacesATargetAndABox() async throws {
        let harness = try await makeHarness(named: "Callout.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        arm(.callout, harness)
        // Click one: the thing being pointed at.
        harness.canvas.handleClick(at: PDFPointValue(x: 150, y: 200), additive: false)
        #expect(harness.canvas.activeTextEntry == nil, "one click is a target, not yet a box")
        #expect(harness.core.markup.placedPoints.count == 1)
        // Click two: where the box goes.
        harness.canvas.handleClick(at: PDFPointValue(x: 320, y: 320), additive: false)
        let entry = try #require(harness.canvas.activeTextEntry)
        #expect(entry.kind == .callout)
        #expect(entry.target == PDFPointValue(x: 150, y: 200))

        harness.canvas.typeIntoTextEntry("Se detalj 3")
        harness.canvas.commitTextEntry()
        #expect(await wait { self.markupCount(harness.core) == 1 })

        let record = try #require(await markups(harness.core).last)
        #expect(record.kind == .callout)
        #expect(record.caption == "Se detalj 3")
        let points = try #require(record.geometry?.points)
        #expect(points.count == 3, "a callout is a target plus the two corners of its box")
        #expect(points[0].x == 150 && points[0].y == 200)

        // The leader is drawn from the box's edge to the target, with the arrowhead on the
        // target end.
        let scene = CanvasSceneBuilder.build(
            records: await markups(harness.core),
            summaries: harness.core.canvas.visibleMarkups,
            pageID: harness.core.canvas.viewport.pageID
        )
        let shape = try #require(scene.first)
        #expect(shape.kind == .callout)
        #expect(shape.leaderTarget == PDFPointValue(x: 150, y: 200))
        #expect(shape.text == "Se detalj 3")
        let leader = try #require(shape.strokes.first)
        // nl-markup: the head is the callout's stored end (an open arrow), no longer a constant.
        #expect(leader.drawnEndCap == .openArrow)
        #expect(leader.points.last == PDFPointValue(x: 150, y: 200))

        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 0)

        let undoManager = try #require(harness.document.undoManager)
        #expect(await wait { undoManager.canUndo })
        undoManager.undo()
        #expect(await wait { self.markupCount(harness.core) == 0 })
    }

    // MARK: - A subject earns a ledger row

    @Test("A shape with a subject earns its ledger row; the same shape without one does not")
    func aSubjectIsWhatPutsAMarkupInTheLedger() async throws {
        let harness = try await makeHarness(named: "Subject.pdf")
        defer {
            harness.document.close()
            try? FileManager.default.removeItem(at: harness.directory)
        }

        arm(.rectangle, harness)
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 100))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 300, y: 300))
        #expect(await wait { self.markupCount(harness.core) == 1 })
        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 0)

        let record = try #require(await markups(harness.core).first)
        _ = try await harness.core.commands.perform(.editSubject(id: record.id, subject: "Rivning"))
        await harness.core.refresh()
        #expect(harness.core.ledger.rowCount == 1,
                "once the user classifies it, the markup is part of the takeoff")
    }

    // MARK: - Save → reopen

    @Test("Text, callout and shapes survive save → reopen with their kind, geometry and text")
    func markupsHydrateThroughAProjectSave() async throws {
        let harness = try await makeHarness(named: "Hydrate.pdf")
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        arm(.rectangle, harness)
        harness.canvas.handleDragBegan(at: PDFPointValue(x: 100, y: 100))
        harness.canvas.handleDragEnded(at: PDFPointValue(x: 300, y: 220))
        arm(.text, harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 120, y: 500), additive: false)
        harness.canvas.typeIntoTextEntry("Rivning")
        harness.canvas.commitTextEntry()
        arm(.callout, harness)
        harness.canvas.handleClick(at: PDFPointValue(x: 150, y: 200), additive: false)
        harness.canvas.handleClick(at: PDFPointValue(x: 320, y: 320), additive: false)
        harness.canvas.typeIntoTextEntry("Se detalj 3")
        harness.canvas.commitTextEntry()
        #expect(await wait { self.markupCount(harness.core) == 3 })

        let before = await markups(harness.core).map { ($0.kind, $0.comment, $0.geometry) }
        let destination = harness.directory.appendingPathComponent("Markups.zpdfproj")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            harness.document.save(
                to: destination,
                ofType: ZenitAppInfo.projectTypeIdentifier,
                for: .saveAsOperation
            ) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        harness.document.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()

        let reopened = ZenitPDFProjectDocument()
        try reopened.read(from: destination, ofType: ZenitAppInfo.projectTypeIdentifier)
        reopened.startLoadingIfNeeded()
        #expect(await wait { reopened.core != nil && !reopened.isLoading })
        let restored = try #require(reopened.core)
        #expect(reopened.loadFailure == nil)

        let after = await markups(restored)
        #expect(after.count == 3)
        #expect(after.map(\.kind) == before.map(\.0),
                "a reopened project must bring back a rectangle as a rectangle")
        #expect(after.map(\.comment) == before.map(\.1), "the typed strings survive the round trip")
        #expect(after[0].geometry?.polygons.first?.outer.points.count == 4)
        #expect(after[1].geometry?.points.count == 2)
        #expect(after[2].geometry?.points.count == 3)
        // Still not in the ledger after a reopen: hydration must not invent a quantity for
        // a markup that never had one.
        #expect(restored.ledger.rowCount == 0)

        reopened.close()
        await ZenitPDFProjectDocument.drainStorageShutdowns()
    }
}
