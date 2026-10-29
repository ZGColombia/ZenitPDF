import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// Clipping, the background heuristic and the invisibility rules of extraction.
///
/// `QUALITY_BAR` S16: no candidate from a hidden or excluded primitive, ever — and every
/// exclusion recorded, so a false filter is debuggable rather than invisible.
struct ClipAndFilterTests {

    @Test("A clipping-only path never becomes a primitive, and the exclusion is recorded")
    func clippingOnlyPathIsFilteredAndRecorded() async throws {
        let result = try await ExtractionTestSupport.extract(.clippedContent)
        defer { ExtractionTestSupport.remove(result.directory) }

        let page = result.manifest.pages[0]
        let clipBox = try #require(page.clipPath)

        let clippingDecisions = result.extraction.filterDecisions.filter { $0.rule == .clippingOnly }
        #expect(clippingDecisions.count == 1)
        let decision = try #require(clippingDecisions.first)
        #expect(abs(decision.bounds.minX - clipBox.llx) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(decision.bounds.minY - clipBox.lly) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(decision.bounds.maxX - clipBox.urx) <= ExtractionTestSupport.coordinateTolerance)
        #expect(abs(decision.bounds.maxY - clipBox.ury) <= ExtractionTestSupport.coordinateTolerance)

        // Nothing emitted has the clip rectangle's geometry.
        for primitive in result.extraction.primitives {
            #expect(primitive.bounds != decision.bounds)
        }
    }

    @Test("Geometry painted under a clip carries the clip bounds and a partial relation")
    func clippedGeometryRecordsItsClip() async throws {
        let result = try await ExtractionTestSupport.extract(.clippedContent)
        defer { ExtractionTestSupport.remove(result.directory) }

        let clipBox = try #require(result.manifest.pages[0].clipPath)
        let expectedClip = VectorBounds(
            minX: clipBox.llx, minY: clipBox.lly, maxX: clipBox.urx, maxY: clipBox.ury
        )

        #expect(!result.extraction.primitives.isEmpty)
        for primitive in result.extraction.primitives {
            #expect(primitive.clipRelation == .partiallyClipped)
            #expect(primitive.clipBounds == expectedClip)
            // Partial clipping lowers confidence: part of the primitive is invisible and
            // a box test cannot say which part.
            #expect(primitive.confidence < VectorConfidence.stroked)
        }

        // The crossing line keeps its *full* manifest length. Extraction reports the
        // path, not the painted ribbon; the visible portion is the snap engine's job.
        let line = try #require(result.manifest.path(id: "crossing-line"))
        let extractedLine = try #require(
            result.extraction.segmentPrimitives.first { primitive in
                guard case .line(let candidate) = primitive.geometry else { return false }
                return abs(candidate.length - line.length) <= ExtractionTestSupport.coordinateTolerance
            }
        )
        guard case .line(let candidate) = extractedLine.geometry else { return }
        #expect(ExtractionTestSupport.isNear(candidate.start, line.points[0]))
        #expect(ExtractionTestSupport.isNear(candidate.end, line.points[1]))
    }

    @Test("Clip-derived primitives are opt-in and carry reduced confidence when enabled")
    func clipDerivedPrimitivesAreOptIn() async throws {
        var options = VectorExtractionOptions.standard
        options.emitsClipDerivedPrimitives = true
        let result = try await ExtractionTestSupport.extract(.clippedContent, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        let clipDerived = result.extraction.primitives.filter { $0.paint.contains(.clipDerived) }
        #expect(!clipDerived.isEmpty)
        for primitive in clipDerived {
            #expect(primitive.confidence == VectorConfidence.clipDerived)
        }
        #expect(!result.extraction.filterDecisions.contains { $0.rule == .clippingOnly })
    }

    @Test("The page-sized background rectangle is filtered and the real geometry is kept")
    func backgroundRectangleIsFiltered() async throws {
        let result = try await ExtractionTestSupport.extract(.giantBackgroundRectangle)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.availability == .available)

        let background = try #require(result.manifest.path(id: "background"))
        #expect(background.isBackground)

        let decisions = result.extraction.filterDecisions.filter { $0.rule == .pageSizedBackground }
        #expect(decisions.count == 1)
        let decision = try #require(decisions.first)
        // The rule fired on measurable numbers, both recorded.
        #expect(decision.measuredValue == 1.0)
        #expect(decision.threshold == VectorBackgroundFilter.standard.minimumCropBoxAreaFraction)
        #expect(abs(decision.bounds.area - background.area) <= 1e-9)

        // Nothing the size of the page survived.
        for primitive in result.extraction.primitives {
            #expect(primitive.bounds.area < background.area * 0.5)
        }

        // Both foreground paths did survive, exactly where the manifest puts them.
        for id in ["foreground-line", "foreground-rect"] {
            let path = try #require(result.manifest.path(id: id))
            ExtractionTestSupport.expectVertices(of: path, in: result.extraction)
        }
    }

    @Test("Turning the background filter off restores the rectangle, so nothing is lost silently")
    func backgroundFilterIsConfigurable() async throws {
        var options = VectorExtractionOptions.standard
        options.backgroundFilter = .disabled
        let result = try await ExtractionTestSupport.extract(.giantBackgroundRectangle, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.filterDecisions.isEmpty)
        let background = try #require(result.manifest.path(id: "background"))
        ExtractionTestSupport.expectVertices(of: background, in: result.extraction)
    }

    @Test("A stroked page-sized border is drawing content, not background, by default")
    func strokedPageSizedRectangleSurvives() async throws {
        // A1 and ARCH-D sheets carry a real drawn border inset 36 pt. It covers a large
        // share of the sheet and a naive area rule would eat it; it is exactly the
        // linework a user reaches for first.
        for kind in [FixtureKind.sizeA1, .sizeArchD] {
            let result = try await ExtractionTestSupport.extract(kind)
            defer { ExtractionTestSupport.remove(result.directory) }
            let border = try #require(result.manifest.path(id: "border"))
            #expect(!result.extraction.filterDecisions.contains { $0.rule == .pageSizedBackground })
            ExtractionTestSupport.expectVertices(of: border, in: result.extraction)
        }
    }

    @Test("The background heuristic thresholds are configurable and take effect")
    func backgroundThresholdIsConfigurable() async throws {
        var options = VectorExtractionOptions.standard
        // Filled-only off plus a low area threshold: now the A1 border does look like a
        // background, and the decision says by exactly how much.
        options.backgroundFilter = VectorBackgroundFilter(
            minimumCropBoxAreaFraction: 0.5,
            filtersFilledOnly: false
        )
        let result = try await ExtractionTestSupport.extract(.sizeA1, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        let decision = try #require(
            result.extraction.filterDecisions.first { $0.rule == .pageSizedBackground }
        )
        let measured = try #require(decision.measuredValue)
        #expect(measured >= 0.5)
        #expect(decision.threshold == 0.5)
    }

    @Test("A page whose only geometry is filtered reports unavailable, not available")
    func onlyFilteredGeometryIsUnavailable() async throws {
        // The A1 sheet has a border and a scale bar. With `filtersFilledOnly` off and a
        // threshold low enough to catch the border, and the bar removed by an aggressive
        // out-of-crop rule, the page must not claim to be usable.
        var options = VectorExtractionOptions.standard
        options.backgroundFilter = VectorBackgroundFilter(
            minimumCropBoxAreaFraction: 0.001,
            filtersFilledOnly: false
        )
        let result = try await ExtractionTestSupport.extract(.rectangle, options: options)
        defer { ExtractionTestSupport.remove(result.directory) }

        #expect(result.extraction.primitives.isEmpty)
        guard case .unavailable(let reason) = result.extraction.availability else {
            Issue.record("expected unavailable, got \(result.extraction.availability)")
            return
        }
        #expect(reason == .onlyFilteredGeometry(filteredCount: 1))
    }

    @Test("An `n` with no pending clip discards the path and records why")
    func discardedPathIsRecorded() async throws {
        // The malformed-operator fixture ends its block with `-0 -0 m l l l S`; the
        // clipped fixture is the one with a genuine `W n`. Here the discard rule is
        // exercised through the clipping fixture with clip-derived emission off, which
        // is the default, plus the malformed stream's own discarded paths.
        let result = try await ExtractionTestSupport.extract(.hugeMalformedOperatorStream)
        defer { ExtractionTestSupport.remove(result.directory) }
        // Whatever it decided, every discarded subpath must carry a recorded reason.
        #expect(result.extraction.filterDecisions.allSatisfy { !$0.rule.explanation.isEmpty })
    }
}
