import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFVectorExtraction
@testable import ZenitPDFAppKit

/// Bug hunt 2, the vector underlay: stale compiles, stale renders, stale hidden sets.
@MainActor
@Suite(.appTierSerialised)
struct Fix2UnderlayTests {

    @Test("BH-345: every compile carries its own revision, so reused positional ids re-upload")
    func compileRevisionMoves() async throws {
        let (page, extraction) = try await VectorUnderlayTests.roofPlanPageAndExtraction()
        let markups = PageUnderlayCompiler.markups(from: extraction, revision: 3)
        // Old: revision 0 always — the arena kept the previous compile's geometry per id.
        #expect(!markups.isEmpty && markups.allSatisfy { $0.revision == 3 })
        let underlay = VectorUnderlay(preference: .metal)
        defer { Task { await underlay.dispose() } }
        guard await underlay.availability.isAvailable else { return }
        await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: [])
        let first = await underlay.compiledRevisionForTesting
        await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: ["X"])
        let second = await underlay.compiledRevisionForTesting
        #expect(first != second)
    }

    @Test("BH-889: an older prepare arriving late is ignored, and a render against another hidden set draws nothing")
    func stalePrepareAndHiddenSetAreRefused() async throws {
        let (page, extraction) = try await VectorUnderlayTests.roofPlanPageAndExtraction()
        let underlay = VectorUnderlay(preference: .metal)
        defer { Task { await underlay.dispose() } }
        guard await underlay.availability.isAvailable else { return }
        await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: ["Walls"], generation: 2)
        await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: [], generation: 1)
        // Old: the last arrival won, whatever order the toggles were made in.
        #expect(await underlay.compiledHiddenLayersForTesting == ["Walls"])
        let plan = try VectorUnderlayTests.plan(page: page, zoom: 1)
        #expect(await underlay.render(page: page, plan: plan, hiddenLayerIDs: []) == nil)
    }

    @Test("BH-350 / IM-175: a superseded underlay request does no GPU work")
    func cancelledRenderDoesNothing() async throws {
        let (page, extraction) = try await VectorUnderlayTests.roofPlanPageAndExtraction()
        let underlay = VectorUnderlay(preference: .metal)
        defer { Task { await underlay.dispose() } }
        guard await underlay.availability.isAvailable else { return }
        await underlay.prepare(page: page, extraction: extraction, hiddenLayerIDs: [])
        let plan = try VectorUnderlayTests.plan(page: page, zoom: 1)
        let before = await underlay.renderCountForTesting
        let task = Task { await underlay.render(page: page, plan: plan) }
        task.cancel()
        let image = await task.value
        // Old: every cancelled request still rendered offscreen and read the pixels back.
        #expect(image == nil)
        #expect(await underlay.renderCountForTesting == before)
        #expect(await underlay.render(page: page, plan: plan) != nil, "an uncancelled render still draws")
    }
}
