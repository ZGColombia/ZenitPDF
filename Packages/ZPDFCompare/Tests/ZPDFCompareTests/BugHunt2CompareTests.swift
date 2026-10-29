import CoreGraphics
import Foundation
import Testing
@testable import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFTestingSupport

/// Bug hunt 2 — alignment and the comparator.
struct BugHunt2CompareTests {

    /// Two sheets with *different* media boxes, same drawing.
    private func pair(baseline: FixtureRect, revised: FixtureRect) throws -> RevisionPair {
        let edges = [
            RevisionEdge("h", from: (100, 100), to: (400, 100)),
            RevisionEdge("v", from: (100, 100), to: (100, 500)),
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-compare-bh2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baselineURL = directory.appendingPathComponent("baseline.pdf")
        let revisedURL = directory.appendingPathComponent("revised.pdf")
        try RevisionPDFWriter.data(mediaBox: baseline, edges: edges).write(to: baselineURL, options: .atomic)
        try RevisionPDFWriter.data(mediaBox: revised, edges: edges).write(to: revisedURL, options: .atomic)
        return RevisionPair(
            mediaBox: baseline, baselineEdges: edges, revisedEdges: edges,
            baselineURL: baselineURL, revisedURL: revisedURL, directory: directory
        )
    }

    // MARK: BH-121

    /// Old output: the candidates for a y-up (12, 8) shift were (12, 8) and (−12, −8) only; the
    /// y-down reading (12, −8) that GrayImage needs was never produced.
    @Test("BH-121: Vision's transform is also read in the y-flipped convention")
    func visionReadingsIncludeYFlip() {
        let aligner = VisionAutoAligner(maximumTranslationFraction: 0.1)
        let candidates = aligner.screenedInterpretations(
            of: [CGAffineTransform(translationX: 12, y: 8)], width: 600, height: 800
        ).candidates
        #expect(candidates.contains { abs($0.tx - 12) < 1e-9 && abs($0.ty + 8) < 1e-9 })
        // F·T·F is an involution and preserves the linear part of a pure translation.
        let t = AlignmentTransform(a: 1, b: 0.01, c: -0.02, d: 0.99, tx: 3, ty: 4)
        let twice = VisionAutoAligner.yFlipped(VisionAutoAligner.yFlipped(t, height: 800), height: 800)
        #expect(twice.maximumDeviation(from: t, over: CGRect(x: 0, y: 0, width: 600, height: 800)) < 1e-9)
    }

    // MARK: BH-122

    /// Old output: `CompareFault.pixelBudgetExceeded(requestedPixels: 4_359_744, limit: 1_200_000)`
    /// from rendering the larger revision at the scale fitted to the baseline.
    @Test("BH-122: a larger revision sheet in the stack is rendered within the plan's budget")
    func largerRevisionFitsPlanBudget() async throws {
        let pair = try pair(
            baseline: FixtureRect(llx: 0, lly: 0, urx: 612, ury: 792),
            revised: FixtureRect(llx: 0, lly: 0, urx: 1224, ury: 1584)
        )
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair, includeVector: false)
        defer { Task { await harness.close() } }

        let plan = try OverlayCompositePlan.fit(
            pageBox: try await harness.comparator.pageBox(of: harness.baseline),
            requestedScale: 1.5,
            layerCount: 2,
            maximumPixels: 1_200_000
        )
        #expect(plan.isReduced == false)
        let planned = try await harness.comparator.overlay(
            references: [harness.baseline, harness.revised],
            alignments: [.identity, .identity],
            model: RevisionOverlayModel.testStack(labels: ["baseline", "revised"]),
            plan: plan
        )
        #expect(planned.composite.image.width == plan.pixelWidth)
        #expect(planned.composite.image.height == plan.pixelHeight)
    }

    // MARK: BH-123

    /// Old output: `result.alignment.transform` was a 0.93 centred shrink although the page-box
    /// solution's own conditioning was 0, so every line was reported as changed.
    @Test("BH-123: a page-box match with conditioning 0 does not warp the revision")
    func zeroConditioningPageBoxIsNotApplied() async throws {
        let pair = try pair(
            baseline: FixtureRect(llx: 0, lly: 0, urx: 612, ury: 792),
            revised: FixtureRect(llx: 0, lly: 0, urx: 612, ury: 852)   // a title strip added
        )
        defer { RevisionCorpus.remove(pair.directory) }
        let harness = try await CompareHarness.open(pair, includeVector: false)
        defer { Task { await harness.close() } }

        let result = try await harness.comparator.compare(
            RevisionCompareRequest(
                baseline: harness.baseline,
                revised: harness.revised,
                renderScale: 1,
                alignment: .automatic(AutoAlignmentPlan(usesVisionRegistration: false)),
                includesVectorSignal: false
            )
        )
        #expect(result.alignment.conditioning == 0)
        #expect(result.alignment.provenance == .pageBox)
        #expect(result.alignment.transform.isIdentity(tolerance: 1e-12))
    }
}

/// Bug hunt 2 — set matching and the shape grid.
struct BugHunt2SetMatchingTests {

    private let a1 = CGSize(width: 2384, height: 1684)
    private let a3 = CGSize(width: 1191, height: 842)

    /// Old output: old "1"/"2"/"3" paired with new "1"/"2"/"3" as `.exactLabel`
    /// (`isGuess == false`) although the labels were synthesised ordinals and a sheet had been
    /// inserted at the front.
    @Test("BH-124: synthesised ordinal labels and empty labels are never label evidence")
    func ordinalLabelsAreNotEvidence() throws {
        let old = (0..<3).map { SetSheet(index: $0, label: "\($0 + 1)", sizeInPoints: a1, labelIsExplicit: false) }
        let new = (0..<4).map { SetSheet(index: $0, label: "\($0 + 1)", sizeInPoints: a1, labelIsExplicit: false) }
        let matching = try SheetMatcher.match(old: old, new: new)
        #expect(matching.pairs.allSatisfy { $0.basis == .positionFallback })
        #expect(!matching.pairs.contains { $0.basis == .exactLabel })

        let emptyOld = [SetSheet(index: 0, label: "", sizeInPoints: a1)]
        let emptyNew = [SetSheet(index: 0, label: "  ", sizeInPoints: a1)]
        let empty = try SheetMatcher.match(old: emptyOld, new: emptyNew)
        #expect(empty.pairs.map(\.basis) == [.positionFallback])
    }

    @Test("BH-124: an archive without labelIsExplicit decodes as explicit")
    func legacyArchiveDecodes() throws {
        let json = #"{"index":2,"label":"A-101","sizeInPoints":[10,20]}"#
        let sheet = try JSONDecoder().decode(SetSheet.self, from: Data(json.utf8))
        #expect(sheet.labelIsExplicit)
        let round = try JSONDecoder().decode(SetSheet.self, from: try JSONEncoder().encode(
            SetSheet(index: 1, label: "7", sizeInPoints: a3, labelIsExplicit: false)))
        #expect(!round.labelIsExplicit)
    }

    /// Old output: pairs (P2, P1'), (P3, P2'); P1 removed, P3' added.
    @Test("BH-125: an unmatched inserted sheet of another size does not shift later positional pairs")
    func insertedSheetDoesNotShiftFallback() throws {
        // Duplicate labels force every sheet into the positional fallback.
        let old = (0..<3).map { SetSheet(index: $0, label: "X", sizeInPoints: a1) }
        let new = [SetSheet(index: 0, label: "X", sizeInPoints: a3)]
            + (1...3).map { SetSheet(index: $0, label: "X", sizeInPoints: a1) }
        let matching = try SheetMatcher.match(old: old, new: new)
        #expect(matching.pairs.map { [$0.old, $0.new] } == [[0, 1], [1, 2], [2, 3]])
        #expect(matching.addedInNew == [0])
        #expect(matching.removedFromOld.isEmpty)
    }

    /// Old output: `Int((1.3e21 / 144).rounded(.down))` — "Double value cannot be converted to
    /// Int because the result would be greater than Int.max", a trap.
    @Test("BH-126: the shape grid tolerates huge and non-finite anchors")
    func shapeGridClampsAnchors() {
        func shape(_ id: UInt64, _ anchor: CGPoint) -> VectorDiffEngine.Shape {
            VectorDiffEngine.Shape(
                id: id, kind: .lineSegment, vertices: [anchor, anchor], bounds: .zero,
                anchor: anchor, strokeWidth: 1, confidence: 1
            )
        }
        let shapes = [
            shape(0, CGPoint(x: 1.3e21, y: -1.3e21)),
            shape(1, CGPoint(x: Double.nan, y: 5)),
            shape(2, CGPoint(x: 10, y: 10)),
        ]
        let grid = VectorDiffEngine.ShapeGrid(shapes: shapes, cellSize: 144)
        #expect(grid.candidates(near: CGPoint(x: 10, y: 10), radius: 1).contains(2))
        #expect(grid.candidates(near: CGPoint(x: 1.3e21, y: -1.3e21), radius: 1).contains(0))
        _ = grid.candidates(near: CGPoint(x: Double.infinity, y: 0), radius: .infinity)
    }
}
