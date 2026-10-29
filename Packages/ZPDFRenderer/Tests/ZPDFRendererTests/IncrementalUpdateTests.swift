import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFRenderer
import ZPDFRendererScenario

/// The diff, as a behaviour rather than as a timing.
///
/// The benchmark proves the incremental path is fast; these prove it is *correct* — that it
/// notices the right things and, just as importantly, does not notice the wrong ones.
@Suite("Incremental update", .serialized)
struct IncrementalUpdateTests {

    private func scene(_ count: Int, seed: UInt64 = 0x1234) -> (PageDescriptor, [RenderableMarkup]) {
        SceneLibrary.stress(count: count, seed: seed)
    }

    private func viewport(_ page: PageDescriptor, zoom: Double = 1.0) -> RenderViewport {
        RenderViewport.fittingWholePage(page, zoom: zoom, backingScale: 1.0)
    }

    private func renderers() throws -> [any OffscreenMarkupRendering] {
        [CoreGraphicsMarkupRenderer(), try MetalMarkupRenderer()]
    }

    @Test("Re-submitting an unchanged scene rewrites nothing")
    func unchangedSceneIsFree() throws {
        let (page, markups) = scene(2_000)
        for renderer in try renderers() {
            defer { renderer.dispose() }
            let viewport = viewport(page)
            renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
            #expect(renderer.statistics.dirtySlotCount > 0)
            renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport)
            #expect(renderer.statistics.dirtySlotCount == 0, "\(renderer.backend) rewrote an unchanged scene")
            #expect(renderer.statistics.uploadedByteCount == 0)
        }
    }

    @Test("Panning rewrites nothing; a zoom step rewrites only the text and re-bucketed count markers")
    func viewportChanges() throws {
        let (page, markups) = scene(2_000)
        for renderer in try renderers() {
            defer { renderer.dispose() }
            renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page))

            var panned = viewport(page)
            panned.layout.anchor = CGPoint(x: -37, y: 12)
            renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: panned)
            #expect(renderer.statistics.dirtySlotCount == 0, "\(renderer.backend) rebuilt on a pan")

            // A zoom step changes the device font size, and only text is sized in device pixels.
            // On Metal a count marker whose atlas bucket moved with the zoom is also moved into
            // the new bucket's arena (BH-199); before that fix it kept the old tile, stretched,
            // and this bound was `textCount` alone.
            renderer.update(
                page: page,
                markups: markups,
                selection: .empty,
                snapFeedback: nil,
                viewport: viewport(page, zoom: 2.0)
            )
            let textCount = markups.reduce(0) { total, markup in
                if case .textLabel = markup.shape { return total + 1 }
                return total
            }
            let symbolCount = markups.reduce(0) { total, markup in
                if case .countSymbol = markup.shape { return total + 1 }
                return total
            }
            #expect(textCount > 0)
            let bound = renderer.backend == .metal ? textCount + symbolCount : textCount
            #expect(renderer.statistics.dirtySlotCount <= bound,
                    "\(renderer.backend) rebuilt \(renderer.statistics.dirtySlotCount) slots for \(textCount) labels and \(symbolCount) markers")
        }
    }

    @Test("Selection and snap feedback never dirty a geometry slot")
    func overlayNeverDirtiesGeometry() throws {
        let (page, markups) = scene(2_000)
        for renderer in try renderers() {
            defer { renderer.dispose() }
            renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            for step in 0..<20 {
                let id = markups[step * 41 % markups.count].id
                renderer.update(
                    page: page,
                    markups: markups,
                    selection: SelectionSnapshot(selectedIDs: [id], primaryID: id, hoveredID: id),
                    snapFeedback: RenderSnapFeedback(point: PDFPoint(x: Double(step), y: 10)),
                    viewport: viewport(page)
                )
                #expect(renderer.statistics.dirtySlotCount == 0)
                #expect(renderer.statistics.uploadedByteCount == 0)
            }
        }
    }

    @Test("Changing one markup rewrites exactly one slot")
    func oneMarkupOneSlot() throws {
        let (page, markups) = scene(2_000)
        for renderer in try renderers() {
            defer { renderer.dispose() }
            renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            var moved = markups
            moved[1_000].revision = 99
            if case let .polyline(line) = moved[1_000].shape {
                moved[1_000].shape = .polyline(RenderPolyline(
                    points: line.points.map { PDFPoint(x: $0.x + 5, y: $0.y) },
                    isClosed: line.isClosed
                ))
            }
            renderer.update(page: page, markups: moved, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            #expect(renderer.statistics.dirtySlotCount == 1, "\(renderer.backend)")
        }
    }

    @Test("A markup that changes without a revision bump is deliberately not noticed")
    func staleRevisionIsNotNoticed() throws {
        // This is a contract, not an oversight: the producer stamps the revision, and the renderer
        // trusts it. The test exists so that the contract is visible and cannot be broken by
        // accident on the renderer's side.
        let (page, markups) = scene(200)
        let renderer = CoreGraphicsMarkupRenderer()
        defer { renderer.dispose() }
        renderer.update(page: page, markups: markups, selection: .empty, snapFeedback: nil, viewport: viewport(page))
        let before = try renderer.renderOffscreen()

        var mutated = markups
        if case let .polyline(line) = mutated[10].shape {
            mutated[10].shape = .polyline(RenderPolyline(
                points: line.points.map { PDFPoint(x: $0.x + 200, y: $0.y) },
                isClosed: line.isClosed
            ))
        }
        renderer.update(page: page, markups: mutated, selection: .empty, snapFeedback: nil, viewport: viewport(page))
        let after = try renderer.renderOffscreen()
        #expect(before.pixels == after.pixels)
        #expect(renderer.statistics.dirtySlotCount == 0)

        // Bumping the revision makes the same change visible.
        mutated[10].revision += 1
        renderer.update(page: page, markups: mutated, selection: .empty, snapFeedback: nil, viewport: viewport(page))
        let bumped = try renderer.renderOffscreen()
        #expect(bumped.pixels != after.pixels)
    }

    @Test("Adding, removing and reordering markups all resynchronise correctly")
    func topologyChanges() throws {
        let (page, markups) = scene(500)
        for renderer in try renderers() {
            defer { renderer.dispose() }
            let full = Array(markups)
            let withoutOne = Array(markups[0..<250]) + Array(markups[251...])
            let reordered = Array(markups.reversed())

            renderer.update(page: page, markups: full, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            let fullImage = try renderer.renderOffscreen()

            renderer.update(page: page, markups: withoutOne, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            let reducedImage = try renderer.renderOffscreen()
            #expect(reducedImage.pixels != fullImage.pixels, "\(renderer.backend): removing a markup changed nothing")

            renderer.update(page: page, markups: full, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            let restored = try renderer.renderOffscreen()
            #expect(restored.pixels == fullImage.pixels, "\(renderer.backend): restoring a markup did not restore the image")

            // Reordering the caller's array must not change the picture: painter order is by
            // (zIndex, id), which is a property of the markups and not of the array.
            renderer.update(page: page, markups: reordered, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            let reorderedImage = try renderer.renderOffscreen()
            #expect(reorderedImage.pixels == fullImage.pixels, "\(renderer.backend): array order changed the picture")
        }
    }

    @Test("A long sequence of edits leaves the same picture as a fresh renderer")
    func longEditSequence() throws {
        // Slot reuse, dead stamping and compaction all only misbehave after a while, so this runs
        // a hundred edits — additions, removals, moves and hides — and then compares the result
        // against a renderer that saw only the final state.
        let (page, markups) = scene(400)
        var live = markups
        var random = DeterministicRandom(seed: 0xFACE)
        for renderer in try renderers() {
            defer { renderer.dispose() }
            live = markups
            for step in 0..<100 {
                switch step % 4 {
                case 0 where live.count > 50:
                    live.remove(at: random.int(0, live.count - 1))
                case 1:
                    var copy = live[random.int(0, live.count - 1)]
                    copy = RenderableMarkup(
                        id: MarkupID(random.uuid()),
                        revision: 0,
                        zIndex: random.int(0, 500),
                        shape: copy.shape,
                        style: copy.style
                    )
                    live.append(copy)
                case 2:
                    let index = random.int(0, live.count - 1)
                    live[index].revision &+= 1
                    if case let .polyline(line) = live[index].shape {
                        live[index].shape = .polyline(RenderPolyline(
                            points: line.points.map { PDFPoint(x: $0.x + 1, y: $0.y + 1) },
                            isClosed: line.isClosed
                        ))
                    }
                default:
                    let index = random.int(0, live.count - 1)
                    live[index].isHidden.toggle()
                    live[index].revision &+= 1
                }
                renderer.update(page: page, markups: live, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            }
            let evolved = try renderer.renderOffscreen()

            let fresh: any OffscreenMarkupRendering = renderer.backend == .metal
                ? try MetalMarkupRenderer()
                : CoreGraphicsMarkupRenderer()
            defer { fresh.dispose() }
            fresh.update(page: page, markups: live, selection: .empty, snapFeedback: nil, viewport: viewport(page))
            let reference = try fresh.renderOffscreen()
            let result = ImageComparator.compare(evolved, reference)
            #expect(result.matches, "\(renderer.backend) drifted after 100 edits: \(result.summary)")
        }
    }
}
