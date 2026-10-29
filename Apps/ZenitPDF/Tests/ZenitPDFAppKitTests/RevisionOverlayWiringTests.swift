import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
import ZPDFAppCore
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFUIPresentation
import ZPDFUIShell
import ZPDFUIWorkflows
@testable import ZenitPDFAppKit

/// Revision Overlay is a compositor now, not a placeholder.
///
/// The mode's own state used to be built and dropped — `RevisionOverlayModel` reached the
/// application as one dispatch line and nothing filled it, and its two outward hooks were on
/// 17.2's dead list. These tests drive the **shipping** window: the real document, the real
/// `ProjectShellEnvironment`, the real `ProjectWindowController.fillCanvasMode`.
@MainActor
@Suite(.appTierSerialised, .serialized)
struct RevisionOverlayWiringTests {

    private func wait(
        upTo seconds: Double = 60,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        await AppTestSupport.wait(upTo: seconds, for: condition)
    }

    private func openWindow(
        on url: URL
    ) async throws -> (document: ZenitPDFProjectDocument, controller: ProjectWindowController) {
        let document = ZenitPDFProjectDocument()
        try document.read(from: url, ofType: UTType.pdf.identifier)
        document.makeWindowControllers()
        let controller = try #require(document.windowControllers.first as? ProjectWindowController)
        #expect(await wait { controller.contentViewController is ProjectWindowLayoutController })
        #expect(await wait { document.core != nil && document.shell != nil })
        controller.window?.layoutIfNeeded()
        await settleWindowLayout(controller, document: document)
        return (document, controller)
    }

    /// Waits for the window's launch-time layout churn to finish before anything is measured.
    ///
    /// `ProjectWindowLayoutController.configure(window:)` schedules `finishInitialLayout()` with
    /// `DispatchQueue.main.async`, deliberately: the frame set during `configure` is the window's
    /// final size, but the split panes were positioned against whatever intermediate bounds the
    /// earlier layout passes happened to see, so the stored layout is applied once more on the
    /// next turn of the run loop. A single synchronous `layoutIfNeeded()` therefore returns a
    /// geometry that is about to change.
    ///
    /// This mattered to exactly one assertion — the viewport-restore check below — and it was
    /// invisible for as long as the layout came out of `UserDefaults.standard`. Product code
    /// reached the real preference domain through two default arguments
    /// (`ProjectWindowLayoutController(store:)` → `ProjectWindowLayoutStore(defaults:)`), so this
    /// suite inherited a layout written by earlier test runs, in which the pre-settle and
    /// post-settle geometry happened to coincide and the difference measured zero.
    ///
    /// It does not coincide against the shipped default, and once `ZenitProcessDefaults.layout`
    /// gave the app tier a per-process store the difference appeared: `rectBefore` read a
    /// transient 222.55 × 282.55 pt and `rectAfter` the settled 181.45 × 238.91 pt, three
    /// assertions red, deterministically, with nothing wrong in Revision Overlay at all. Measured
    /// on a settled window, `rectBefore` and `rectAfter` are identical to the last decimal.
    ///
    /// The preference-leak lesson restated: the assertion was never about the code it named.
    private func settleWindowLayout(
        _ controller: ProjectWindowController,
        document: ZenitPDFProjectDocument
    ) async {
        guard let canvas = document.core?.canvas else { return }
        var previous: (Double, Double, Double, Double)?
        var stableRounds = 0
        // Stability, not a sleep: three consecutive identical readings, each after a forced
        // layout pass. A fixed delay would be a guess about this machine.
        _ = await wait(upTo: 10) {
            controller.window?.layoutIfNeeded()
            let rect = canvas.viewport.visiblePageRect
            let now = (rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
            if let previous, previous == now {
                stableRounds += 1
            } else {
                stableRounds = 0
            }
            previous = now
            return stableRounds >= 3
        }
    }

    // MARK: - 1. The mode fills, and leaving gives the canvas back

    @Test("Revision Overlay stacks the document's own revisions, and Escape restores zoom and scroll")
    func overlayFillsAndEscapeRestoresTheViewport() async throws {
        let url = try AppTestSupport.writeFixturePDF(named: "Overlay A-201.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (document, controller) = try await openWindow(on: url)
        defer { document.close() }
        let core = try #require(document.core)
        let shell = try #require(document.shell)

        // A viewport worth restoring — a zoom nobody lands on by accident, and whatever scroll
        // position the real scroll view settles at for it. Read back off the canvas rather than
        // asserted at it: `restore` moves the *view*, so the only rectangle it can be checked
        // against is one the view actually reported.
        core.canvas.setZoom(2.75)
        controller.window?.layoutIfNeeded()
        #expect(await wait(upTo: 10) { core.canvas.viewport.zoom == 2.75 })
        let zoomBefore = core.canvas.viewport.zoom
        let rectBefore = core.canvas.viewport.visiblePageRect

        shell.perform(.revisionOverlay)
        #expect(shell.canvasModes.activeMode == .revisionOverlay)

        // The open drawing becomes the baseline revision, so the stack is never empty. Filling
        // happens through `withObservationTracking`, deferred onto the main actor, exactly as
        // Split Canvas's does — this waits for that, it does not call the fill itself.
        #expect(
            await wait(upTo: 20) { shell.revisionOverlay.layers.count >= 1 },
            "the overlay stack is still empty"
        )
        let model = shell.revisionOverlay
        #expect(model.layers[0].revisionName.isEmpty == false)
        #expect(model.legendEntries.count == model.visibleLayers.count)

        // One revision is not a dead end: the pane says how many there are and how to add
        // another, in one sentence.
        #expect(await wait(upTo: 20) { model.compositeStatus != .idle })
        let message = try #require(model.compositeStatus.message)
        // L-57: the way to add one is the pane's own Add Revision…, which it now offers; the
        // sentence used to name only an Option-drop from Finder.
        #expect(message.contains("Add Revision…"), "the empty state does not say how to add a revision")
        #expect(model.onAddRevision != nil, "the pane offers no Add Revision…")

        // Something moves the canvas while the mode is up, so the restore below is an
        // assertion rather than a statement that nothing happened.
        core.canvas.setZoom(0.5)
        #expect(core.canvas.viewport.zoom == 0.5)

        shell.perform(.cancelTool)
        #expect(shell.canvasModes.activeMode == nil)
        controller.window?.layoutIfNeeded()
        #expect(core.canvas.viewport.zoom == zoomBefore, "Escape did not restore the zoom")

        // Scroll position, to the hundredth of a point. This is the claim — the sheet is
        // where it was, at the zoom it was at.
        let rectAfter = core.canvas.viewport.visiblePageRect
        #expect(abs(rectAfter.minX - rectBefore.minX) < 0.01,
                "Escape left the sheet at x \(rectAfter.minX), not \(rectBefore.minX)")
        #expect(abs(rectAfter.minY - rectBefore.minY) < 0.01,
                "Escape left the sheet at y \(rectAfter.minY), not \(rectBefore.minY)")
        #expect(abs(rectAfter.size.height - rectBefore.size.height) < 0.01)

        // The visible *width* is allowed to differ by up to one scroller. Measured here it is
        // 8.36 pt at 2.75x — 23 view points, an `NSScroller`. It is a fact about the scroll
        // view's own layout, not about the restore: the sheet had not yet been scrolled when
        // `rectBefore` was read, so no vertical scroller was inset, and by the time it is read
        // again one is. Asserting it exactly would be asserting that AppKit never shows a
        // scroller, which is not a claim Revision Overlay is making.
        #expect(abs(rectAfter.size.width - rectBefore.size.width) < 24,
                "the viewport lost \(rectBefore.size.width - rectAfter.size.width) pt of width")
    }

    // MARK: - 2. Two revisions, and the hooks that were dead

    @Test("A dropped revision joins the stack and arms the two hooks 17.2 listed as dead")
    func droppedRevisionArmsTheCompositorHooks() async throws {
        let first = try AppTestSupport.writeFixturePDF(named: "Overlay A-201.pdf")
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let second = try AppTestSupport.writeFixturePDF(named: "Overlay A-201 Rev B.pdf")
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }

        let (document, _) = try await openWindow(on: first)
        defer { document.close() }
        let shell = try #require(document.shell)

        var added = false
        document.addRevision(fromDroppedFile: second) { added = $0 }
        #expect(await wait(upTo: 30) { added }, "the dropped revision was never registered")
        #expect(document.comparePresenter?.revisions.count == 2)
        #expect(document.revisionPages.count == 2, "the overlay's page references were not kept")

        shell.perform(.revisionOverlay)
        let model = shell.revisionOverlay
        #expect(model.layers.count == 2, "the mode did not open over both revisions")

        // The two hooks. Both were once dead: nothing in the product
        // assigned either. They are what makes a layer edit and a re-fit reach a compositor.
        // Waited for, not read immediately: the fill is deferred onto the main actor so it
        // runs after `enterCanvasMode` has finished building the mode.
        #expect(await wait(upTo: 20) { model.onLayersChange != nil }, "onLayersChange is still dead")
        #expect(model.onAlignmentChange != nil, "onAlignmentChange is still dead")
        #expect(model.onRecomposite != nil, "a failed composite would have no retry route")

        // Two named layers, two named colours: the legend can be read without seeing hue.
        #expect(model.legendEntries.count == 2)
        #expect(Set(model.legendEntries.map(\.colorName)).count == 2)
        #expect(model.hasEnoughLayers)

        // A composite is now attempted. In the shipping bundle it reads its rasters through
        // `GeometryService`; under `swift test` there is no service to reach, so the correct
        // outcome here is a *stated* failure rather than a picture — the one thing it must not
        // do is fall back to parsing the compared document in this process (finding S17-02),
        // and `CompareIsolationTests` in `ZPDFServiceClient` is what pins that down.
        #expect(await wait(upTo: 40) { model.compositeStatus != .rendering && model.compositeStatus != .idle })
        switch model.compositeStatus {
        case .ready:
            #expect(model.composite != nil)
        case let .failed(reason):
            #expect(reason.contains("could not be stacked"), "unexplained failure: \(reason)")
        default:
            Issue.record("the composite neither succeeded nor said why: \(model.compositeStatus)")
        }

        shell.perform(.cancelTool)
        #expect(shell.canvasModes.activeMode == nil)
    }

    // MARK: - 3. The composite the app tier actually produces

    @Test("The app tier's compositor puts a real picture, at a stated scale, into the mode")
    func compositorProducesAPictureForTheMode() async throws {
        let first = try AppTestSupport.writeFixturePDF(named: "Overlay C-101.pdf")
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let second = try AppTestSupport.writeFixturePDF(named: "Overlay C-101 Rev B.pdf")
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }

        // The in-process source, which is what `swift test` is allowed to use and nothing else
        // is: an `.xpc` service cannot be launched outside a host app bundle. The *shipping*
        // path is `ServiceBackedRevisionDocumentSource.automatic()`, built at
        // `ZenitPDFProjectDocument.swift`'s compare setup and asserted there.
        let provider = PDFKitDocumentProvider()
        defer { Task { await provider.closeAll() } }
        let comparator = RevisionComparator(source: InProcessRevisionDocumentSource(provider: provider))
        let a = try await provider.open(fileAt: first)
        let b = try await provider.open(fileAt: second)

        let summaries = [("Current", first, a), ("Rev B", second, b)].map { label, url, opened in
            (
                RevisionSummary(
                    id: UUID(), documentID: UUID(), name: label, revisionLabel: label,
                    author: "", pageCount: 1, isBaseline: label == "Current",
                    colorRGBA: ColorRGBA.Zenit.Dark.cyan, fileName: url.lastPathComponent
                ),
                RevisionPageReference(
                    document: opened.handle, pageIndex: 0, fileURL: url, label: label
                )
            )
        }
        let revisions = summaries.map(\.0)
        let pages = Dictionary(uniqueKeysWithValues: summaries.map { ($0.0.id, $0.1) })

        let model = ZPDFUIWorkflows.RevisionOverlayModel(revisions: revisions)
        let compositor = RevisionOverlayCompositing(
            producer: ComparatorOverlayProducer(comparator: comparator, pages: { pages }),
            model: model,
            requestedScale: { 2 }
        )
        compositor.attach()
        #expect(await wait(upTo: 60) { model.composite != nil },
                "no composite arrived: \(model.compositeStatus)")

        let composite = try #require(model.composite)
        #expect(composite.contributingLayerIDs == revisions.map(\.id))
        #expect(composite.pixelWidth == Int((595.0 * 2).rounded(.up)))
        #expect(composite.pixelHeight == Int((842.0 * 2).rounded(.up)))
        #expect(composite.scale == 2 && composite.requestedScale == 2)
        #expect(composite.isReducedResolution == false)
        #expect(composite.pageBox.size.width == 595 && composite.pageBox.size.height == 842)
        #expect(composite.image.width == composite.pixelWidth)
        #expect(composite.elapsedNanoseconds > 0)

        // Hiding a layer is not cosmetic: it drops out of the picture's own account of itself.
        let previous = composite.id
        model.setVisible(false, forLayer: revisions[1].id)
        #expect(await wait(upTo: 60) { model.composite?.id != previous && model.composite != nil })
        #expect(model.composite?.contributingLayerIDs == [revisions[0].id])

        // And leaving takes the picture with it rather than leaving megabytes behind.
        compositor.detach()
        #expect(model.composite == nil)
        #expect(model.onLayersChange == nil && model.onAlignmentChange == nil)
    }

    // MARK: - 4. The translation into the engine's vocabulary

    @Test("Layer settings reach the engine intact, and Difference composites onto black")
    func engineModelCarriesEverySetting() {
        let a = RevisionSummary(
            id: UUID(), documentID: UUID(), name: "A", revisionLabel: "Rev A", author: "",
            pageCount: 1, colorRGBA: ColorRGBA.Zenit.Dark.cyan, fileName: "a.pdf"
        )
        let b = RevisionSummary(
            id: UUID(), documentID: UUID(), name: "B", revisionLabel: "Rev B", author: "",
            pageCount: 1, colorRGBA: ColorRGBA.Zenit.Dark.green, fileName: "b.pdf"
        )
        let model = ZPDFUIWorkflows.RevisionOverlayModel(revisions: [a, b])
        model.setOpacity(0.35, forLayer: b.id)
        model.setVisible(false, forLayer: b.id)

        let layers = model.layers.sorted { $0.order < $1.order }
        let multiply = RevisionOverlayEngine.engineModel(for: layers, blendMode: .multiply)
        #expect(multiply.layers.map(\.id) == [0, 1])
        #expect(multiply.layers[0].isVisible && !multiply.layers[1].isVisible)
        #expect(multiply.layers[1].opacity == 0.35)
        #expect(multiply.layers.allSatisfy { $0.blendMode == .multiply })
        #expect(multiply.layers[0].color.red == layers[0].colorRGBA.red)
        #expect(multiply.background == .white)
        #expect(multiply.layers[0].label.contains("Rev A"))

        // Difference exists so two identical revisions cancel, and they can only cancel to the
        // ground they were painted on. On white they would cancel to white — and so does blank
        // paper, which is the one reading the mode must never produce.
        let difference = RevisionOverlayEngine.engineModel(for: layers, blendMode: .difference)
        #expect(difference.background == .black)
        #expect(difference.layers.allSatisfy { $0.blendMode == .difference })

        // The bottom sheet is the frame; the manual fit registers every sheet above it.
        let fit = RevisionAlignmentTransform(a: 1, b: 0, c: 0, d: 1, tx: 12, ty: -4)
        let alignments = RevisionOverlayEngine.alignments(count: 3, fit: fit)
        #expect(alignments[0] == .identity)
        #expect(alignments[1].tx == 12 && alignments[1].ty == -4)
        #expect(alignments[2] == alignments[1])
        #expect(RevisionOverlayEngine.alignments(count: 2, fit: nil) == [.identity, .identity])
    }
}
