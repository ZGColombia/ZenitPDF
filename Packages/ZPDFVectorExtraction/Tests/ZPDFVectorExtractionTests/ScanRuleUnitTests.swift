import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Rules the synthetic corpus does not reach, tested directly on the scan state.
///
/// These are unit tests of a rule, not hand-rolled PDF fixtures: no bytes are invented,
/// only the state machine the scanner drives is exercised.
struct ScanRuleUnitTests {

    private func makeState(
        options: VectorExtractionOptions = .standard,
        cropBox: VectorBounds = VectorBounds(minX: 0, minY: 0, maxX: 612, maxY: 792)
    ) -> VectorScanState {
        VectorScanState(
            options: options,
            pageTransform: VectorPageTransform(
                convention: options.pageSpaceConvention,
                mediaBox: cropBox,
                cropBox: cropBox,
                rotation: 0
            ),
            hiddenOptionalContentGroups: []
        )
    }

    @Test("Geometry entirely outside the clip is dropped, and the exclusion is recorded")
    func geometryOutsideTheClipIsDropped() {
        let state = makeState()
        // Install a clip over the lower-left quarter with `re W n`.
        state.appendRectangle(x: 0, y: 0, width: 100, height: 100)
        state.pendingClip = true
        state.paintPath(stroke: false, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.clippingOnly])

        // A line far outside that clip cannot be seen and must not be a snap candidate.
        state.moveTo(CGPoint(x: 400, y: 400))
        state.lineTo(CGPoint(x: 500, y: 400))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.last?.rule == .entirelyOutsideClip)

        // A line inside it survives, marked as clipped.
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 90, y: 10))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.count == 1)
        #expect(state.primitives[0].clipRelation == .insideClip)
    }

    @Test("Turning the clip exclusion off keeps the geometry and still marks it")
    func clipExclusionIsConfigurable() {
        var options = VectorExtractionOptions.standard
        options.excludesGeometryOutsideClip = false
        let state = makeState(options: options)

        state.appendRectangle(x: 0, y: 0, width: 100, height: 100)
        state.pendingClip = true
        state.paintPath(stroke: false, fill: false, closesPath: false)

        state.moveTo(CGPoint(x: 400, y: 400))
        state.lineTo(CGPoint(x: 500, y: 400))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.count == 1)
        #expect(state.primitives[0].clipRelation == .outsideClip)
    }

    @Test("A path with alpha 0 is invisible paint, not geometry")
    func invisiblePaintIsFiltered() {
        let state = makeState()
        state.state.strokeAlpha = 0
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.invisiblePaint])
    }

    @Test("A path discarded by `n` with no pending clip is recorded as discarded")
    func discardedPathIsRecorded() {
        let state = makeState()
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.paintPath(stroke: false, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.discardedWithoutPainting])
    }

    @Test("Geometry entirely off the sheet is filtered")
    func geometryOffTheSheetIsFiltered() {
        let state = makeState()
        state.moveTo(CGPoint(x: 2_000, y: 2_000))
        state.lineTo(CGPoint(x: 2_100, y: 2_000))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.entirelyOutsideCropBox])
    }

    @Test("A full-bleed backdrop larger than the sheet is filtered whatever its paint")
    func fullBleedBackdropIsFiltered() {
        let state = makeState()
        state.appendRectangle(x: -20, y: -20, width: 652, height: 832)
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.enclosesCropBox])
    }

    @Test("A degenerate subpath is not geometry a person can snap to")
    func degenerateGeometryIsFiltered() {
        let state = makeState()
        state.moveTo(CGPoint(x: 50, y: 50))
        state.lineTo(CGPoint(x: 50, y: 50))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.degenerateGeometry])
    }

    @Test("Hidden optional content produces no candidate at all")
    func hiddenOptionalContentProducesNoCandidate() {
        let state = makeState()
        state.beginMarkedContent(hidesContent: true, layerID: "Sketch")
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.hiddenOptionalContent])

        state.endMarkedContent()
        state.moveTo(CGPoint(x: 10, y: 20))
        state.lineTo(CGPoint(x: 100, y: 20))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.count == 1)
        #expect(state.primitives[0].layerID == nil)
    }

    @Test("A visible marked-content layer is recorded on the primitive")
    func visibleLayerIsRecorded() {
        let state = makeState()
        state.beginMarkedContent(hidesContent: false, layerID: "Structural")
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.count == 1)
        #expect(state.primitives[0].layerID == "Structural")
    }

    @Test("An unbalanced `Q` and an unbalanced `EMC` are survivable, not fatal")
    func unbalancedStateOperatorsAreSurvivable() {
        let state = makeState()
        for _ in 0..<50 { state.restoreState() }
        for _ in 0..<50 { state.endMarkedContent() }
        #expect(state.malformedOperandCount == 100)
        // The hidden-content counter must not have gone negative and started hiding.
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.count == 1)
    }

    @Test("The graphics state stack is bounded against a stream of nothing but `q`")
    func stateStackIsBounded() {
        let state = makeState()
        for _ in 0..<(VectorScanState.maximumStateStackDepth + 100) { state.saveState() }
        #expect(state.stateStackDepth == VectorScanState.maximumStateStackDepth)
        #expect(state.malformedOperandCount == 100)
    }

    @Test("Partial reasons are ordered by severity, never by the order they were tripped")
    func partialReasonsAreOrdered() {
        let state = makeState()
        state.note(.inlineImageSkipped(count: 1))
        state.note(.annotationAppearanceStreamsNotExtracted)
        state.note(.shadingGeometryNotExtracted)
        state.note(.cyclicFormReference)
        state.note(.formNestingDepthExceeded(limit: 32))

        let ranks = state.sortedPartialReasons.map(\.severityRank)
        #expect(ranks == ranks.sorted())
        #expect(state.sortedPartialReasons.first == .formNestingDepthExceeded(limit: 32))
    }

    @Test("Stroke width is transformed into page space by the CTM")
    func strokeWidthFollowsTheCTM() {
        let state = makeState()
        state.state.lineWidth = 2
        state.concatenate(CGAffineTransform(scaleX: 3, y: 3))
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 50, y: 10))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.count == 1)
        #expect(abs(state.primitives[0].strokeWidth - 6) <= 1e-12)

        // Width 0 is PDF's "thinnest renderable line" and must stay 0, not become 0×scale.
        let thin = makeState()
        thin.state.lineWidth = 0
        thin.concatenate(CGAffineTransform(scaleX: 5, y: 5))
        thin.moveTo(CGPoint(x: 1, y: 1))
        thin.lineTo(CGPoint(x: 20, y: 1))
        thin.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(thin.primitives[0].strokeWidth == 0)
    }

    @Test("Mirroring and shearing matrices compose in PDF order")
    func mirrorAndShearComposition() {
        // The `Do` composition rule: a form's /Matrix is applied *before* the CTM in
        // force at the operator. Reversing it is the classic bug, and it is invisible
        // under pure translation — hence a mirror and a shear.
        let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
        let shear = CGAffineTransform(a: 1, b: 0, c: 0.5, d: 1, tx: 0, ty: 0)
        let scale = CGAffineTransform(scaleX: 2, y: 3)

        let state = makeState()
        state.concatenate(scale)      // page `cm`
        state.concatenate(mirror)     // outer form /Matrix
        state.concatenate(shear)      // inner form /Matrix

        let expected = shear.concatenating(mirror).concatenating(scale)
        let point = CGPoint(x: 7, y: 11)
        let byState = state.toPageSpace(point)
        let byHand = point.applying(expected)
        #expect(abs(byState.x - byHand.x) <= 1e-12)
        #expect(abs(byState.y - byHand.y) <= 1e-12)

        // And the reversed order really is different, so the test can fail.
        let reversed = point.applying(scale.concatenating(mirror).concatenating(shear))
        #expect(abs(byHand.x - reversed.x) > 1e-6 || abs(byHand.y - reversed.y) > 1e-6)
    }

    // MARK: - CR-39: marked content is lexical, not graphics state

    private func strokeLine(_ state: VectorScanState, y: Double) {
        state.moveTo(CGPoint(x: 10, y: y))
        state.lineTo(CGPoint(x: 100, y: y))
        state.paintPath(stroke: true, fill: false, closesPath: false)
    }

    @Test("`BDC q … EMC … Q` does not resurrect a hidden section that has ended (CR-39)")
    func hiddenSectionIsNotRestoredByQ() {
        let state = makeState()
        state.beginMarkedContent(hidesContent: true, layerID: "Sketch")
        state.saveState()
        state.endMarkedContent()
        state.restoreState()
        // Old output: `Q` restored hiddenContentDepth 1 and layerID "Sketch" from the saved
        // graphics state; the stroke was dropped (0 primitives, filter .hiddenOptionalContent).
        strokeLine(state, y: 10)
        #expect(state.primitives.count == 1)
        #expect(state.primitives.first?.layerID == nil)
        #expect(state.filterDecisions.isEmpty)
        #expect(state.malformedOperandCount == 0)
    }

    @Test("`q BDC … Q` does not end a hidden section that is still open (CR-39)")
    func hiddenSectionSurvivesQ() {
        let state = makeState()
        state.saveState()
        state.beginMarkedContent(hidesContent: true, layerID: "Sketch")
        state.restoreState()
        // Old output: `Q` restored hiddenContentDepth 0; the stroke inside the still-open
        // hidden section was emitted (1 primitive) and became a snap target.
        strokeLine(state, y: 10)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.map(\.rule) == [.hiddenOptionalContent])

        // `EMC` is what ends it.
        state.endMarkedContent()
        strokeLine(state, y: 20)
        #expect(state.primitives.count == 1)
        #expect(state.primitives.first?.layerID == nil)
    }

    // MARK: - CR-42: the current point after `h` and `re`

    @Test("A segment after `h` begins a new subpath at the closed subpath's start (CR-42)")
    func segmentAfterCloseStartsAtTheSubpathStart() {
        let state = makeState()
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 110, y: 10))
        state.lineTo(CGPoint(x: 110, y: 110))
        state.closeSubpath()
        state.lineTo(CGPoint(x: 60, y: 210))
        state.paintPath(stroke: true, fill: false, closesPath: false)

        // Old output: the `l` after `h` was counted malformed (malformedOperandCount 1) and
        // began a subpath at its own end point, which was degenerate and filtered: 4
        // primitives (the ring and its three lines) and a `.degenerateGeometry` decision.
        #expect(state.malformedOperandCount == 0)
        #expect(state.filterDecisions.isEmpty)
        #expect(state.primitives.count == 5)
        let lines = state.primitives.compactMap { primitive -> VectorLine? in
            if case let .line(line) = primitive.geometry { return line }
            return nil
        }
        #expect(lines.contains(VectorLine(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 210))))
        #expect(state.primitives.filter { $0.kind == .closedSubpath }.count == 1)
    }

    @Test("A segment after `re` begins at the rectangle's `(x, y)` corner (CR-42)")
    func segmentAfterRectangleStartsAtItsCorner() {
        let state = makeState()
        state.appendRectangle(x: 10, y: 10, width: 50, height: 50)
        state.lineTo(CGPoint(x: 100, y: 100))
        state.paintPath(stroke: true, fill: false, closesPath: false)

        // Old output: malformedOperandCount 1, 5 primitives (rectangle + four edges) and one
        // `.degenerateGeometry` decision for the lost segment.
        #expect(state.malformedOperandCount == 0)
        #expect(state.primitives.count == 6)
        let lines = state.primitives.compactMap { primitive -> VectorLine? in
            if case let .line(line) = primitive.geometry { return line }
            return nil
        }
        #expect(lines.contains(VectorLine(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 100))))
    }

    @Test("A segment with no current point at all is still malformed, not invented (CR-42)")
    func segmentWithoutAnyCurrentPointStaysMalformed() {
        let state = makeState()
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        // Painting consumed the path; `l` now has no current point to start from.
        state.lineTo(CGPoint(x: 200, y: 200))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.malformedOperandCount == 1)
        #expect(state.primitives.count == 1)
    }

    // MARK: - CR-51: a form at the `q`-stack cap

    @Test("A form entered at the `q`-stack cap restores the outer state, never a foreign one (CR-51)")
    func formScopeAtTheStateStackCap() {
        let state = makeState()
        for _ in 0..<VectorScanState.maximumStateStackDepth { state.saveState() }
        #expect(state.stateStackDepth == VectorScanState.maximumStateStackDepth)
        // The state in force at the `Do`, set after the last successful `q`.
        state.state.ctm = CGAffineTransform(scaleX: 2, y: 2)
        state.state.lineWidth = 7

        let depth = state.stateStackDepth
        let scope = state.beginFormScope()
        state.concatenate(CGAffineTransform(scaleX: 3, y: 3))
        state.state.lineWidth = 1
        state.saveState() // the form's own unbalanced `q`, refused at the cap like the wrapper's
        state.endFormScope(scope)

        // Before CR-51 the wrapper was `saveState()` — refused at the cap — followed by a
        // bare `restoreState()`, which popped the outer stream's own `q` and left the CTM at
        // identity and the line width at 1.
        #expect(state.state.ctm == CGAffineTransform(scaleX: 2, y: 2))
        #expect(state.state.lineWidth == 7)
        #expect(state.stateStackDepth == depth)
    }

    @Test("Below the cap a form scope is exactly `q … Q`, including what the form unbalanced")
    func formScopeBelowTheCap() {
        let state = makeState()
        state.saveState()
        state.state.ctm = CGAffineTransform(translationX: 5, y: 5)
        let depth = state.stateStackDepth

        let scope = state.beginFormScope()
        state.concatenate(CGAffineTransform(scaleX: 3, y: 3))
        state.saveState()
        state.saveState()
        state.beginMarkedContent(hidesContent: true, layerID: "InForm")
        state.endFormScope(scope)

        #expect(state.state.ctm == CGAffineTransform(translationX: 5, y: 5))
        #expect(state.stateStackDepth == depth)
        #expect(state.markedContentDepth == 0)
        #expect(state.hiddenContentDepth == 0)
        #expect(state.layerID == nil)
    }

    // MARK: - BH-330: `s`, `b`, `b*` close only the current subpath

    @Test("`s` closes only the current subpath, not every open one (BH-330)")
    func closeAndStrokeClosesOnlyTheCurrentSubpath() {
        // PDF 32000-1 Table 60: `s` is "Close and stroke the path. Same effect as h S";
        // 8.5.2.1: `h` "closes the *current* subpath". So in
        //   10 10 m 100 10 l 100 50 l 200 200 m 250 200 l 250 250 l s
        // the first subpath stays an open L (2 line segments) and only the second is
        // closed (2 lines + the closing line (250,250)→(200,200) + one closed-subpath
        // ring): 2 + 4 = 6 primitives.
        //
        // Old output: 8 primitives — both subpaths closed, with a phantom stroked line
        // (100,50)→(10,10) and a phantom ring on the first.
        let state = makeState()
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.lineTo(CGPoint(x: 100, y: 50))
        state.moveTo(CGPoint(x: 200, y: 200))
        state.lineTo(CGPoint(x: 250, y: 200))
        state.lineTo(CGPoint(x: 250, y: 250))
        state.paintPath(stroke: true, fill: false, closesPath: true)

        #expect(state.primitives.count == 6)
        #expect(state.primitives.filter { $0.kind == .closedSubpath }.count == 1)
        let lines = state.primitives.compactMap { primitive -> VectorLine? in
            if case let .line(line) = primitive.geometry { return line }
            return nil
        }
        #expect(!lines.contains(VectorLine(start: CGPoint(x: 100, y: 50), end: CGPoint(x: 10, y: 10))))
        #expect(lines.contains(VectorLine(start: CGPoint(x: 250, y: 250), end: CGPoint(x: 200, y: 200))))
        #expect(state.primitives.filter { $0.subpathIndex == 0 }.count == 2)
        #expect(state.primitives.filter { $0.subpathIndex == 1 }.count == 4)
    }

    @Test("`b` still closes every subpath, because the fill implicitly closes them (Table 60, `f`)")
    func closeFillAndStrokeClosesEverySubpath() {
        // Non-vacuity: the fill side of `b` is `f`, and Table 60 says of `f` that open
        // subpaths "shall be implicitly closed before being filled". Same two subpaths,
        // painted with `b`: both closed → (3 lines + ring) × 2 = 8 primitives.
        let state = makeState()
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 100, y: 10))
        state.lineTo(CGPoint(x: 100, y: 50))
        state.moveTo(CGPoint(x: 200, y: 200))
        state.lineTo(CGPoint(x: 250, y: 200))
        state.lineTo(CGPoint(x: 250, y: 250))
        state.paintPath(stroke: true, fill: true, closesPath: true)
        #expect(state.primitives.count == 8)
        #expect(state.primitives.filter { $0.kind == .closedSubpath }.count == 2)
    }

    // MARK: - BH-331: two disjoint clips leave an empty clip

    @Test("Two disjoint `W n` rectangles make the clip empty, and a stroke inside the second is dropped (BH-331)")
    func disjointClipsMakeTheClipEmpty() {
        // q 0 0 100 100 re W n 200 200 100 100 re W n 250 250 m 280 280 l S Q
        // PDF 32000-1 8.5.4: each `W n` intersects the clip with the new path; the
        // intersection of [0,100]² and [200,300]² is empty, so nothing paints.
        //
        // Old output: `intersection` returned nil, `?? pathBounds` made the clip
        // [200,300]², and the stroke was emitted `.insideClip` at confidence 1.0.
        let state = makeState()
        state.saveState()
        state.appendRectangle(x: 0, y: 0, width: 100, height: 100)
        state.pendingClip = true
        state.paintPath(stroke: false, fill: false, closesPath: false)
        state.appendRectangle(x: 200, y: 200, width: 100, height: 100)
        state.pendingClip = true
        state.paintPath(stroke: false, fill: false, closesPath: false)
        #expect(state.state.clipIsEmpty)

        state.moveTo(CGPoint(x: 250, y: 250))
        state.lineTo(CGPoint(x: 280, y: 280))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.isEmpty)
        #expect(state.filterDecisions.last?.rule == .entirelyOutsideClip)

        // `Q` restores the clip that was in force before the `q`: none.
        state.restoreState()
        #expect(!state.state.clipIsEmpty)
        #expect(state.state.clip == nil)
        state.moveTo(CGPoint(x: 250, y: 250))
        state.lineTo(CGPoint(x: 280, y: 280))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.primitives.count == 1)
        #expect(state.primitives.first?.clipRelation == .unclipped)
    }

    @Test("With the clip exclusion off, geometry under an empty clip is emitted as outside the clip")
    func emptyClipWithExclusionOff() {
        var options = VectorExtractionOptions.standard
        options.excludesGeometryOutsideClip = false
        let state = makeState(options: options)
        state.appendRectangle(x: 0, y: 0, width: 100, height: 100)
        state.pendingClip = true
        state.paintPath(stroke: false, fill: false, closesPath: false)
        state.appendRectangle(x: 200, y: 200, width: 100, height: 100)
        state.pendingClip = true
        state.paintPath(stroke: false, fill: false, closesPath: false)
        state.moveTo(CGPoint(x: 250, y: 250))
        state.lineTo(CGPoint(x: 280, y: 280))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        // Old output: `.insideClip`, confidence 1.0.
        #expect(state.primitives.count == 1)
        #expect(state.primitives.first?.clipRelation == .outsideClip)
        #expect(state.primitives.first?.confidence == VectorConfidence.value(paint: .stroked, clipRelation: .outsideClip))
    }

    // MARK: - BH-866: `h` on a closed subpath is a no-op

    @Test("`h` after `re`, and a second `h`, are legal no-ops, not malformed operands (BH-866)")
    func closeOnAClosedSubpathIsNotMalformed() {
        // PDF 32000-1 8.5.2.1: "If the current subpath is already closed, h shall do
        // nothing." `re` leaves the subpath closed (it is `x y m … h`).
        //
        // Old output: malformedOperandCount 2 (one per `h`), and the page reported
        // `.malformedContentStream(operandFailures: 2)` → `.partial`.
        let state = makeState()
        state.appendRectangle(x: 0, y: 0, width: 100, height: 50)
        state.closeSubpath()
        state.paintPath(stroke: false, fill: true, closesPath: false)
        state.moveTo(CGPoint(x: 200, y: 200))
        state.lineTo(CGPoint(x: 300, y: 200))
        state.lineTo(CGPoint(x: 300, y: 300))
        state.closeSubpath()
        state.closeSubpath()
        state.paintPath(stroke: true, fill: false, closesPath: false)

        #expect(state.malformedOperandCount == 0)
        #expect(state.sortedPartialReasons.isEmpty)
        // Rectangle + 4 edges, triangle ring + 3 edges: 9 primitives, nothing doubled.
        #expect(state.primitives.count == 9)

        // And a segment after the doubled `h` still starts at the subpath's start (CR-42).
        state.moveTo(CGPoint(x: 10, y: 10))
        state.lineTo(CGPoint(x: 20, y: 10))
        state.lineTo(CGPoint(x: 20, y: 20))
        state.closeSubpath()
        state.closeSubpath()
        state.lineTo(CGPoint(x: 50, y: 50))
        state.paintPath(stroke: true, fill: false, closesPath: false)
        #expect(state.malformedOperandCount == 0)
        let lines = state.primitives.compactMap { primitive -> VectorLine? in
            if case let .line(line) = primitive.geometry { return line }
            return nil
        }
        #expect(lines.contains(VectorLine(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 50))))

        // Non-vacuity: `h` with no path at all is still malformed.
        let bare = makeState()
        bare.closeSubpath()
        #expect(bare.malformedOperandCount == 1)
    }
}
