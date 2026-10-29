import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFSnapEngine
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// Iteration-6 app-canvas fixes (iteration-6 findings, items triaged "fix"):
/// W-001, W-002, W-003, W-004, W-005, W-007 and W-014. Every test drives the shipping canvas,
/// its page view or the window controller directly; no window is ordered front and no modal is
/// raised.
@MainActor
@Suite(.appTierSerialised)
struct Iter6AppCanvasTests {

    // MARK: - Shared helpers

    private static func eventually(
        _ seconds: Double = 15, _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private static func near(_ a: PDFPointValue?, _ b: PDFPointValue, within tolerance: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return Swift.abs(a.x - b.x) <= tolerance && Swift.abs(a.y - b.y) <= tolerance
    }

    /// Default snapping without the 36 pt grid (its points would compete everywhere), the page
    /// calibrated 100 pt = 1 m, the vector snap index ready and the canvas at 100 %, so one view
    /// point is one page point and the snap radius is 10 pt.
    private static func snappingHarness(_ name: String, zoom: Double = 1) async throws -> Fix2Harness {
        let harness = try await Fix2Harness.make(name)
        var settings = SnapSettings.default
        settings.enabledKinds.remove(.grid)
        try await harness.core.session.setSnapSettings(settings)
        await harness.core.refresh()
        #expect(
            await AppTestSupport.wait(upTo: 40) { harness.core.status.snapshot.geometryIndexStatus.allowsVectorSnap },
            "the vector snap index never became available"
        )
        harness.core.canvas.setZoom(zoom)
        harness.canvas.refresh()
        await harness.settle()
        return harness
    }

    /// The pointer moves to `point` and the hover resolve for it lands (or settles on none).
    private static func hover(_ harness: Fix2Harness, at point: PDFPointValue) async {
        harness.canvas.handlePointerMove(point)
        _ = await AppTestSupport.wait { harness.core.canvas.viewport.cursorPagePoint == point }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// A click as a hand makes it: the pointer moves there, then presses.
    private static func click(_ harness: Fix2Harness, at point: PDFPointValue) async {
        await hover(harness, at: point)
        harness.canvas.handleClick(at: point, additive: false)
    }

    /// The vertices of the measurement drawn by the test, once the session has it.
    private static func newestRecord(_ harness: Fix2Harness, excluding known: Set<MarkupID>) async -> MarkupRecord? {
        await harness.records().first { !known.contains($0.id) }
    }

    // MARK: - W-001 the hover's snap anchor follows the placement it serves

    /// The fixture rectangle's top edge runs (72, 272)–(372, 272). A Length A (200, 400) →
    /// B (300, 330) is clicked and committed; the pointer then rests at P (301.5, 272.5).
    /// With no anchor the winner is the edge point under P, (301.5, 272) — nearestPointOnSegment,
    /// score 9 + 0.5 × 0.5 = 9.25. Anchored at B, the perpendicular foot (300, 272) scores
    /// 8 + 0.5 × √(1.5² + 0.5²) = 8.79 and wins.
    ///
    /// Old output: the anchor was written on each click and never cleared, so after the commit
    /// the ring was perpendicularProjection at (300, 272) and the next Length's first vertex
    /// was stored there; after Remove Last Point the removed vertex (300, 330) still anchored it.
    @Test("W-001: a finished or removed vertex is no snap anchor for the next point")
    func anchorFollowsThePlacement() async throws {
        let harness = try await Self.snappingHarness("Iter6 Anchor.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let presenter = core.canvas
        let p = PDFPointValue(x: 301.5, y: 272.5)
        let underP = PDFPointValue(x: 301.5, y: 272)
        let foot = PDFPointValue(x: 300, y: 272)

        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.refresh()
        await Self.click(harness, at: PDFPointValue(x: 200, y: 400))
        await Self.click(harness, at: PDFPointValue(x: 300, y: 330))
        #expect(await AppTestSupport.wait { core.snapshot.markups.count == 1 }, "precondition: the Length A→B committed")
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.isEmpty })
        let first = try #require(await harness.records().first)
        if core.measurement.activeKind != .length {
            harness.shell.toolbar.activateMeasurement(.length)
            harness.canvas.refresh()
        }

        await Self.hover(harness, at: p)
        #expect(await AppTestSupport.wait { presenter.snapFeedback != nil }, "precondition: the edge catches the pointer")
        #expect(presenter.snapFeedback?.kind != .perpendicularProjection,
                "the committed Length's end still anchored the hover: \(String(describing: presenter.snapFeedback))")
        #expect(Self.near(presenter.snapFeedback?.pagePoint, underP), "ring at \(String(describing: presenter.snapFeedback))")

        harness.canvas.handleClick(at: p, additive: false)
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        let stored = try #require(core.measurement.placedPoints.first)
        #expect(Self.near(stored, underP), "first vertex stored at \(stored); the stale foot is \(foot)")
        _ = harness.canvas.handle(key: .escape)
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.isEmpty })

        // Remove Last Point: the removed vertex must not anchor the next one.
        harness.shell.toolbar.activateMeasurement(.polylength)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        await Self.click(harness, at: PDFPointValue(x: 150, y: 450))
        await Self.click(harness, at: PDFPointValue(x: 300, y: 330))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        #expect(harness.canvas.handle(key: .removeLastVertex))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        await Self.hover(harness, at: p)
        #expect(await AppTestSupport.wait { presenter.snapFeedback != nil })
        #expect(presenter.snapFeedback?.kind != .perpendicularProjection,
                "the removed vertex still anchored the hover: \(String(describing: presenter.snapFeedback))")
        #expect(Self.near(presenter.snapFeedback?.pagePoint, underP))
        // The remaining vertex (150, 450) is the anchor now: its foot (150, 272) is out of reach.
        #expect(core.snapshot.markups.map(\.id) == [first.id.rawValue])
    }

    /// The same anchor when the pointer does not move (W-001 re-check). Polylength (150, 450) →
    /// (300, 330) with the pointer resting at P: the ring is the foot (300, 272) dropped from
    /// (300, 330). Remove Last Point then moves the anchor to (150, 450) with no pointer move.
    ///
    /// Old output (the checker's probe on the c1 tree): nothing re-ran the hover resolve, so the
    /// ring stayed perpendicularProjection at (300, 272) with its guide from the removed vertex,
    /// and a click at P stored (300, 272); the presenter's own re-resolve after a ledger-filter
    /// change read the anchor of the last hover, (300, 330), as well.
    @Test("W-001: Remove Last Point under a still pointer re-anchors the hover before the next click")
    func removeLastPointUnderAStillPointer() async throws {
        let harness = try await Self.snappingHarness("Iter6 Still Remove.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let presenter = core.canvas
        let p = PDFPointValue(x: 301.5, y: 272.5)
        let underP = PDFPointValue(x: 301.5, y: 272)
        let foot = PDFPointValue(x: 300, y: 272)
        // A markup far from P, for the ledger filter to hide at the end.
        let far = try await harness.addMarkup(tool: .length) { pageID in
            MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 450, y: 700), PDFPoint(x: 500, y: 700)])
        }

        harness.shell.toolbar.activateMeasurement(.polylength)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        await Self.click(harness, at: PDFPointValue(x: 150, y: 450))
        await Self.click(harness, at: PDFPointValue(x: 300, y: 330))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        await Self.hover(harness, at: p)
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.kind == .perpendicularProjection },
                "precondition: the last vertex (300, 330) anchors the hover: \(String(describing: presenter.snapFeedback))")
        #expect(Self.near(presenter.snapFeedback?.pagePoint, foot))

        // Remove Last Point; the pointer stays where it is.
        #expect(harness.canvas.handle(key: .removeLastVertex))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        #expect(await AppTestSupport.wait(upTo: 5) { presenter.snapFeedback.map { $0.kind != .perpendicularProjection } ?? false },
                "the removed vertex still anchors the ring: \(String(describing: presenter.snapFeedback))")
        #expect(Self.near(presenter.snapFeedback?.pagePoint, underP), "ring at \(String(describing: presenter.snapFeedback))")
        #expect(presenter.viewport.cursorPagePoint == p, "precondition: no pointer move")

        // The presenter's own re-resolve, after the ledger filter hides a markup, reads the
        // current anchor too.
        presenter.setFilterBehavior(.hideNonMatching)
        presenter.setFilterMatches([])
        #expect(await AppTestSupport.wait { presenter.filterHiddenMarkupIDs.contains(far.id.rawValue) },
                "precondition: Hide took the far markup off the sheet")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(presenter.snapFeedback?.kind != .perpendicularProjection,
                "the filter's re-resolve was anchored at the removed vertex: \(String(describing: presenter.snapFeedback))")
        #expect(Self.near(presenter.snapFeedback?.pagePoint, underP))

        // The click at P, with no move before it.
        harness.canvas.handleClick(at: p, additive: false)
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        let stored = try #require(core.measurement.placedPoints.last)
        #expect(Self.near(stored, underP), "vertex stored at \(stored); the stale foot is \(foot)")
    }

    /// A commit by Return under a still pointer (W-001 re-check): the finished Polylength's last
    /// vertex (300, 330) must not anchor the ring, nor the first vertex of the Length armed next,
    /// clicked at P with no pointer move in between.
    ///
    /// Old output (traced from the c1 code): the commit and the tool switch re-ran no hover
    /// resolve, so the ring stayed the foot (300, 272) and the new Length began there.
    @Test("W-001: a commit by Return under a still pointer re-anchors the hover; the next Length starts under the pointer")
    func commitUnderAStillPointer() async throws {
        let harness = try await Self.snappingHarness("Iter6 Still Commit.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let presenter = core.canvas
        let p = PDFPointValue(x: 301.5, y: 272.5)
        let underP = PDFPointValue(x: 301.5, y: 272)
        let foot = PDFPointValue(x: 300, y: 272)

        harness.shell.toolbar.activateMeasurement(.polylength)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        await Self.click(harness, at: PDFPointValue(x: 150, y: 450))
        await Self.click(harness, at: PDFPointValue(x: 300, y: 330))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        await Self.hover(harness, at: p)
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.kind == .perpendicularProjection },
                "precondition: the last vertex (300, 330) anchors the hover: \(String(describing: presenter.snapFeedback))")

        // Return commits; the pointer stays where it is.
        #expect(harness.canvas.handle(key: .finish))
        #expect(await AppTestSupport.wait { core.snapshot.markups.count == 1 }, "precondition: Return committed the Polylength")
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.isEmpty })
        #expect(await AppTestSupport.wait(upTo: 5) { presenter.snapFeedback.map { $0.kind != .perpendicularProjection } ?? false },
                "the committed vertex still anchors the ring: \(String(describing: presenter.snapFeedback))")
        #expect(Self.near(presenter.snapFeedback?.pagePoint, underP), "ring at \(String(describing: presenter.snapFeedback))")

        // A new Length, still under the resting pointer.
        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .length })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(presenter.viewport.cursorPagePoint == p, "precondition: no pointer move")
        harness.canvas.handleClick(at: p, additive: false)
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        let stored = try #require(core.measurement.placedPoints.first)
        #expect(Self.near(stored, underP), "first vertex stored at \(stored); the stale foot is \(foot)")
    }

    // MARK: - W-002 a scroll under a still pointer re-runs the pointer path

    /// 400 %: the snap radius is 10 / 4 = 2.5 pt, and a 60-view-point pan moves the page 15 pt
    /// under the pointer. A vertical Length markup's end sits (0.5, 0.5) from the pointer's page
    /// point C before the pan; after it the markup is 14.5 pt or more away, out of reach.
    ///
    /// Old output (traced from the code): only the loupe followed a scroll, so the presenter's
    /// cursor stayed at C, the ring stayed on the markup's end, and the click — at the page point
    /// now under the pointer — placed the vertex on that end, 15 pt away.
    @Test("W-002: after a scroll the hover follows the page under the pointer, and a click lands there")
    func scrollRerunsThePointerPath() async throws {
        let harness = try await Self.snappingHarness("Iter6 Scroll.pdf", zoom: 4)
        defer { harness.tearDown() }
        let core = harness.core
        let presenter = core.canvas
        let canvas = harness.canvas
        let page = canvas.pageViewForTesting
        let transform = try #require(page.transform)
        let visible = page.visibleRect
        let centreLocal = CGPoint(x: visible.midX, y: visible.midY)
        let c = transform.pagePoint(from: centreLocal)
        let end = PDFPointValue(x: c.x + 0.5, y: c.y + 0.5)
        let marker = try await harness.addMarkup(tool: .length) { pageID in
            MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: end.x, y: end.y), PDFPoint(x: end.x, y: end.y + 80)])
        }
        harness.shell.toolbar.activateMeasurement(.length)
        canvas.refresh()

        // A real hover event, so the page view records where the pointer rests.
        page.mouseMoved(with: harness.mouseEvent(.mouseMoved, atLocal: centreLocal))
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.pagePoint == end }, "precondition: the markup's end catches the pointer")
        let windowPoint = try #require(page.hoverWindowLocation)

        page.onPanBy?(CGSize(width: 60, height: 0))
        let now = try #require(page.transform)
        let under = now.pagePoint(from: page.convert(windowPoint, from: nil))
        #expect(Swift.abs(under.x - c.x) > 10, "precondition: the pan moved the page under the pointer (\(c) → \(under))")
        #expect(await AppTestSupport.wait { Self.near(presenter.viewport.cursorPagePoint, under) },
                "the hover kept the page point of before the scroll: \(String(describing: presenter.viewport.cursorPagePoint)), now under the pointer \(under)")
        #expect(await AppTestSupport.wait { presenter.snapFeedback == nil },
                "the ring stayed on a candidate the pointer left: \(String(describing: presenter.snapFeedback))")

        canvas.handleClick(at: under, additive: false)
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        let stored = try #require(core.measurement.placedPoints.first)
        #expect(Self.near(stored, under), "stored \(stored); the pointer was over \(under), the old candidate \(end)")
        _ = marker
    }

    /// A click whose point is out of reach of the hover's candidate never takes it: the candidate
    /// answered another pointer position (the guard behind W-002). 100 %, so the reach is
    /// (24 + 4) / 1 = 28 pt.
    ///
    /// Old output (traced from the code): `prepareMeasurementInput` handed the machine the hover
    /// candidate whatever the click, and `effectivePoint` returned `snap ?? rawCursor`, so the
    /// vertex was stored at the corner (372, 272), 60 pt from the click.
    @Test("W-002: a candidate out of the click's reach is not taken")
    func farCandidateIsNotTaken() async throws {
        let harness = try await Self.snappingHarness("Iter6 Far Candidate.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let presenter = core.canvas
        let corner = PDFPointValue(x: 372, y: 272)
        harness.shell.toolbar.activateMeasurement(.length)
        harness.canvas.refresh()
        await Self.hover(harness, at: PDFPointValue(x: 375, y: 274))
        #expect(await AppTestSupport.wait { presenter.snapFeedback?.pagePoint == corner }, "precondition: the corner catches the pointer")

        // No pointer move reaches the canvas before this click (a scroll's re-aim still in flight).
        let click = PDFPointValue(x: 372, y: 332)
        harness.canvas.handleClick(at: click, additive: false)
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })
        let stored = try #require(core.measurement.placedPoints.first)
        #expect(Self.near(stored, click), "stored \(stored); the click was at \(click)")
        _ = presenter
    }

    // MARK: - W-003 Select Similar leaves out what the ledger filter hid

    /// Old output: `matches` rejected only `markup.hidden`, so under Hide the filtered-out "Doors"
    /// Length was selected by Select Same Kind and by Select All in Document — and a Delete would
    /// then remove it unseen.
    @Test("W-003: Select Same Kind and Select All in Document skip markups Hide took off the sheet")
    func selectSimilarSkipsFilterHidden() async throws {
        let harness = try await Fix2Harness.make("Iter6 Select Similar.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let walls = try await harness.addMarkup(tool: .length, geometry: { pageID in
            MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 100, y: 500), PDFPoint(x: 300, y: 500)])
        }, subject: "Walls")
        let doors = try await harness.addMarkup(tool: .length, geometry: { pageID in
            MeasurementGeometry(pageID: pageID, points: [PDFPoint(x: 100, y: 600), PDFPoint(x: 300, y: 600)])
        }, subject: "Doors")
        core.ledger.setCanvasFilterBehavior(.hideNonMatching)
        core.ledger.setFilter(LedgerFilterGroup(id: UUID(), rules: [
            LedgerFilterRule(id: UUID(), column: .subject, comparison: .equals, operand: .text("Walls"))
        ]))
        #expect(await AppTestSupport.wait { core.canvas.filterHiddenMarkupIDs == [doors.id.rawValue] })

        core.canvas.select(markupIDs: [walls.id.rawValue], additive: false)
        harness.controller.selectSimilar(.kind, scope: nil, in: harness.document)
        #expect(core.canvas.selectedMarkupIDs == [walls.id.rawValue], "Select Same Kind took a hidden markup: \(core.canvas.selectedMarkupIDs)")
        harness.controller.selectSimilar(.any, scope: .document, in: harness.document)
        #expect(core.canvas.selectedMarkupIDs == [walls.id.rawValue], "Select All in Document took a hidden markup")

        // Cleared, both are on the sheet and both are taken.
        core.ledger.setFilter(LedgerFilterGroup(id: UUID()))
        #expect(await AppTestSupport.wait { core.canvas.filterHiddenMarkupIDs.isEmpty })
        core.canvas.select(markupIDs: [walls.id.rawValue], additive: false)
        harness.controller.selectSimilar(.kind, scope: nil, in: harness.document)
        #expect(core.canvas.selectedMarkupIDs == [walls.id.rawValue, doors.id.rawValue])
    }

    // MARK: - W-004 clicking away from a text box only finishes it

    /// Old output (traced from the code): the press made the page view first responder — which
    /// committed the box — and then carried on as a Text-tool press, so its release opened a
    /// new empty box under the pointer (Reuse Tool is on by default): `activeTextEntry` was
    /// non-nil after the click, and an empty box was replaced on every click, never dismissed.
    @Test("W-004: a press outside an open text box commits it and opens nothing; an empty box is dismissed")
    func clickAwayEndsTheTextBox() async throws {
        let harness = try await Fix2Harness.make("Iter6 Text Click Away.pdf")
        defer { harness.tearDown() }
        let canvas = harness.canvas
        let page = canvas.pageViewForTesting
        let window = try #require(page.window)
        harness.shell.perform(.textTool)
        canvas.refresh()
        #expect(canvas.armedMode == .markup(.text))
        canvas.handleClick(at: PDFPointValue(x: 120, y: 500), additive: false)
        #expect(canvas.activeTextEntry != nil)
        canvas.typeIntoTextEntry("Hello")
        #expect(window.firstResponder === canvas.textEditorForTesting, "precondition: the caret is in the box")

        func pressAndRelease(at point: PDFPointValue) throws {
            let local = try #require(page.transform).viewPoint(from: point)
            page.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: local))
            page.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: local))
        }

        try pressAndRelease(at: PDFPointValue(x: 300, y: 300))
        #expect(await AppTestSupport.wait { harness.core.snapshot.markups.count == 1 }, "the words were not committed")
        #expect(canvas.activeTextEntry == nil, "the click away opened a new box")
        let record = try #require(await harness.records().first)
        #expect(record.kind == .text && record.caption == "Hello")

        // An empty box: the click away dismisses it and leaves nothing.
        if canvas.armedMode != .markup(.text) {
            harness.shell.perform(.textTool)
            canvas.refresh()
        }
        canvas.handleClick(at: PDFPointValue(x: 300, y: 600), additive: false)
        #expect(canvas.activeTextEntry != nil)
        try pressAndRelease(at: PDFPointValue(x: 200, y: 200))
        #expect(canvas.activeTextEntry == nil, "an empty box could not be clicked away")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.core.snapshot.markups.count == 1)
    }

    // MARK: - W-005 a typed length may start with its decimal separator

    /// 100 pt = 1 m. ".5<0" from (100, 300) places (150, 300); ",5<90" then places (150, 350).
    ///
    /// Old output (traced from the code): the leading "." was not claimed (`handle` returned
    /// false and the key beeped), the entry began at "5", and Return placed (600, 300) — 5 m.
    @Test("W-005: a leading decimal separator starts a typed length: \".5\" is half a metre")
    func leadingSeparatorStartsTheEntry() async throws {
        let harness = try await Fix2Harness.make("Iter6 Typed Separator.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        harness.shell.toolbar.activateMeasurement(.polylength)
        canvas.refresh()
        #expect(await AppTestSupport.wait { core.measurement.activeKind == .polylength })
        // Nothing placed: a separator is not claimed, as a digit is not.
        #expect(canvas.handle(key: .typed(".")) == false)
        canvas.placeTypedMeasurementPoint(PDFPointValue(x: 100, y: 300))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 1 })

        for character in ".5<0" { #expect(canvas.handle(key: .typed(character)), "\(character) was not claimed") }
        #expect(canvas.typedEntry == ".5<0")
        #expect(canvas.handle(key: .finish))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 2 })
        let second = try #require(core.measurement.placedPoints.last)
        #expect(Self.near(second, PDFPointValue(x: 150, y: 300), within: 1e-9), "placed \(second)")

        for character in ",5<90" { #expect(canvas.handle(key: .typed(character))) }
        #expect(canvas.handle(key: .finish))
        #expect(await AppTestSupport.wait { core.measurement.placedPoints.count == 3 })
        let third = try #require(core.measurement.placedPoints.last)
        #expect(Self.near(third, PDFPointValue(x: 150, y: 350), within: 1e-9), "placed \(third)")
    }

    // MARK: - W-007 a markup drag released off the sheet ends on its edge

    /// Old output (traced from the code): `mouseUp` sent `onDragEnded` only on the page or with a
    /// measurement anchor, so the Pen stroke and the rectangle were left in progress
    /// (`placedPoints` non-empty, no markup) — the next press threw the stroke away, and the next
    /// click finished the rectangle from the old anchor.
    @Test("W-007: a Pen stroke and a rectangle released off the page commit on the sheet edge")
    func markupDragReleasedOffThePage() async throws {
        let harness = try await Fix2Harness.make("Iter6 Drag Off Page.pdf")
        defer { harness.tearDown() }
        let core = harness.core
        let canvas = harness.canvas
        let page = canvas.pageViewForTesting
        let transform = try #require(page.transform)
        let frame = transform.pageFrame
        func local(_ point: PDFPointValue) -> CGPoint { transform.viewPoint(from: point) }
        let outside = CGPoint(x: frame.maxX + 40, y: local(PDFPointValue(x: 300, y: 540)).y)
        let edge = transform.pagePoint(from: CGPoint(x: frame.maxX, y: outside.y))

        harness.shell.toolbar.activateShape(.freehand)
        canvas.refresh()
        #expect(canvas.armedMode == .markup(.freehand))
        page.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: local(PDFPointValue(x: 200, y: 500))))
        page.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: local(PDFPointValue(x: 250, y: 520))))
        page.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: local(PDFPointValue(x: 300, y: 540))))
        page.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: outside))
        #expect(await AppTestSupport.wait { core.snapshot.markups.count == 1 }, "the stroke released off the page was lost")
        #expect(core.markup.placedPoints.isEmpty, "the stroke was left in progress: \(core.markup.placedPoints)")
        let stroke = try #require(await harness.records().first)
        let strokeEnd = try #require(stroke.geometry?.points.last)
        #expect(Self.near(PDFPointValue(x: strokeEnd.x, y: strokeEnd.y), edge, within: 1e-6), "stroke ends at \(strokeEnd); the edge is \(edge)")

        harness.shell.toolbar.activateShape(.rectangle)
        canvas.refresh()
        #expect(canvas.armedMode == .markup(.rectangle))
        page.mouseDown(with: harness.mouseEvent(.leftMouseDown, atLocal: local(PDFPointValue(x: 200, y: 300))))
        page.mouseDragged(with: harness.mouseEvent(.leftMouseDragged, atLocal: local(PDFPointValue(x: 260, y: 360))))
        page.mouseUp(with: harness.mouseEvent(.leftMouseUp, atLocal: outside))
        #expect(await AppTestSupport.wait { core.snapshot.markups.count == 2 }, "the rectangle released off the page was not committed")
        #expect(core.markup.placedPoints.isEmpty, "the rectangle was left on its anchor: \(core.markup.placedPoints)")
        let known: Set<MarkupID> = [stroke.id]
        let rectangle = try #require(await Self.newestRecord(harness, excluding: known))
        // A rectangle is stored as one closed ring of its four corners.
        let xs = rectangle.geometry?.polygons.first?.outer.points.map(\.x) ?? []
        #expect(xs.count == 4, "rectangle stored as \(String(describing: rectangle.geometry))")
        #expect(Swift.abs((xs.max() ?? 0) - edge.x) < 1e-6, "rectangle reaches x \(xs.max() ?? 0); the edge is \(edge.x)")
        #expect(Swift.abs((xs.min() ?? 0) - 200) < 1e-6, "the press corner moved: \(xs)")
    }

    // MARK: - W-014 the fence and Scale Region notes read for one and for many

    /// Old output: "Closed by 1 fence line(s).", "1 fence line(s) removed." and
    /// "1 Scale Regions proposed in the warning tray.".
    @Test("W-014: fence-line and Scale Region status notes have one and other forms")
    func notesPluralise() throws {
        let one = [ProposedClosure(start: PDFPoint(x: 0, y: 0), end: PDFPoint(x: 10, y: 0))]
        let two = one + [ProposedClosure(start: PDFPoint(x: 0, y: 10), end: PDFPoint(x: 10, y: 10))]
        #expect(PDFCanvasViewController.fenceNote(one, appendedTo: "Traced.") == "Traced. Closed by 1 fence line.")
        #expect(PDFCanvasViewController.fenceNote(two, appendedTo: "Traced.") == "Traced. Closed by 2 fence lines.")
        #expect(PDFCanvasViewController.fenceNote([], appendedTo: "Traced.") == "Traced.")
        #expect(ProjectWindowController.fenceLinesClearedNote(0) == "This page has no fence lines.")
        #expect(ProjectWindowController.fenceLinesClearedNote(1) == "1 fence line removed.")
        #expect(ProjectWindowController.fenceLinesClearedNote(3) == "3 fence lines removed.")
        #expect(ProjectWindowController.scaleRegionsFoundNote(1) == "1 Scale Region proposed in the warning tray.")
        #expect(ProjectWindowController.scaleRegionsFoundNote(2) == "2 Scale Regions proposed in the warning tray.")

        // The shipped catalogue carries the three keys with the same two forms, in every
        // language (sv mirrors English: the product is English only).
        let localization = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/ZPDFUIPresentation/Localization")
        let expected: [String: (one: String, other: String)] = [
            "Closed by %lld fence lines.": ("Closed by %lld fence line.", "Closed by %lld fence lines."),
            "%lld fence lines removed.": ("%lld fence line removed.", "%lld fence lines removed."),
            "%lld Scale Regions proposed in the warning tray.": (
                "%lld Scale Region proposed in the warning tray.", "%lld Scale Regions proposed in the warning tray."
            )
        ]
        for language in ["en", "sv"] {
            let url = localization.appendingPathComponent("\(language).lproj/Plurals.stringsdict")
            let data = try Data(contentsOf: url)
            let catalogue = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            for (key, forms) in expected {
                let entry = try #require(catalogue[key] as? [String: Any], "\(language) lacks \(key)")
                let rule = try #require(entry["count"] as? [String: Any])
                #expect(rule["one"] as? String == forms.one, "\(language) \(key)")
                #expect(rule["other"] as? String == forms.other, "\(language) \(key)")
            }
        }
    }
}
