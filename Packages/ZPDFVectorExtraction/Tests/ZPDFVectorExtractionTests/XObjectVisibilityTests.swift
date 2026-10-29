import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// XObject-level and configuration-level visibility rules the synthetic corpus does not
/// reach: `/OC` on a form or image XObject dictionary (BH-328), a form `/BBox` disjoint
/// from the clip in force (BH-329), `/BaseState /OFF` in the default optional-content
/// configuration (BH-864), form-local layer names the page does not know (BH-865) and a
/// stray `EMC` inside a form (BH-867). The documents are assembled by hand with
/// `OptionalContentTests.MiniPDF`; every expectation is derived from PDF 32000-1 by hand
/// (`QUALITY_BAR` 2.6), never from the code under test.
@Suite("XObject visibility")
struct XObjectVisibilityTests {
    typealias MiniPDF = OptionalContentTests.MiniPDF

    static func stroke(at y: Double, in extraction: VectorPageExtraction) -> VectorPrimitive? {
        extraction.primitives.first { primitive in
            guard primitive.kind == .lineSegment, case let .line(line) = primitive.geometry else { return false }
            return abs(line.start.y - y) <= 1e-9 && abs(line.end.y - y) <= 1e-9
        }
    }

    static func hiddenCount(in extraction: VectorPageExtraction) -> Int? {
        for reason in extraction.partialReasons {
            if case let .hiddenOptionalContentExcluded(count) = reason { return count }
        }
        return nil
    }

    // MARK: - BH-328: `/OC` on an XObject dictionary

    /// Groups A (5 0 R, on) and B (6 0 R, off in `/D`). Three XObjects drawn with a bare
    /// `Do`, no `BDC` anywhere:
    ///
    /// | name | `/OC` | content | expected |
    /// |---|---|---|---|
    /// | `/Fh` | B (off) | stroke at y = 10 | hidden, counted |
    /// | `/Fv` | A (on) | stroke at y = 20 | visible, layer `L0` (the page's name for A) |
    /// | `/Im` | B (off) | 1 × 1 image | no raster region |
    ///
    /// PDF 32000-1 8.11.3.3, *Optional Content in XObjects*: "An optional content group or
    /// optional content membership dictionary may be attached to an image or form XObject
    /// via the OC entry in its dictionary … the XObject shall be drawn only if the
    /// optional content is visible".
    static func xobjectDocument() -> Data {
        MiniPDF.data(objects: [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /OFF [6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Properties << /L0 5 0 R /L1 6 0 R >> "
                + "/XObject << /Fh 7 0 R /Fv 8 0 R /Im 9 0 R >> >> >>",
            MiniPDF.stream("q /Fh Do Q q /Fv Do Q q 10 0 0 10 300 300 cm /Im Do Q"),
            "<< /Type /OCG /Name (A) >>",
            "<< /Type /OCG /Name (B) >>",
            MiniPDF.stream(
                "10 10 m 100 10 l S",
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /OC 6 0 R"
            ),
            MiniPDF.stream(
                "10 20 m 100 20 l S",
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /OC 5 0 R"
            ),
            MiniPDF.stream(
                "X",
                entries: "/Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray "
                    + "/BitsPerComponent 8 /OC 6 0 R"
            )
        ])
    }

    @Test("A form or image XObject whose `/OC` group is off is not extracted (BH-328)")
    func xobjectOptionalContentIsHonoured() async throws {
        let url = try MiniPDF.write(Self.xobjectDocument())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        // Old output: both strokes present (y = 10 with layerID nil), one raster region,
        // and no `.hiddenOptionalContentExcluded` reason.
        #expect(Self.stroke(at: 10, in: extraction) == nil, "the /OC B form is off")
        let visible = try #require(Self.stroke(at: 20, in: extraction))
        #expect(visible.layerID == "L0")
        #expect(visible.nestingDepth == 1)
        #expect(Self.hiddenCount(in: extraction) == 1)
        #expect(extraction.rasterRegions.isEmpty)
        #expect(extraction.primitives.count == 1)
    }

    @Test("With `includesHiddenOptionalContent` the `/OC` form is extracted, tagged with the page's layer name")
    func xobjectOptionalContentCanBeIncluded() async throws {
        let url = try MiniPDF.write(Self.xobjectDocument())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        var options = VectorExtractionOptions.standard
        options.includesHiddenOptionalContent = true
        let extraction = try await VectorExtractor(options: options).extract(documentAt: url, pageIndex: 0)

        let hidden = try #require(Self.stroke(at: 10, in: extraction))
        #expect(hidden.layerID == "L1")
        #expect(Self.stroke(at: 20, in: extraction)?.layerID == "L0")
        #expect(Self.hiddenCount(in: extraction) == nil)
        #expect(extraction.rasterRegions.count == 1)
        #expect(extraction.layerIDs == ["L0", "L1"])
    }

    // MARK: - BH-329: a form `/BBox` disjoint from the clip in force

    /// The page clips to [0,100]² and then draws two forms:
    ///
    /// | name | `/BBox` | content | expected |
    /// |---|---|---|---|
    /// | `/Fx` | [200,300]² — disjoint from the clip | stroke (250,250)→(280,280) | dropped |
    /// | `/Fy` | [0,300]² — overlapping | stroke (10,50)→(90,50) | `.insideClip` |
    ///
    /// PDF 32000-1 8.10.1: the form's `/BBox` "shall be used to clip the form"; 8.5.4:
    /// clips intersect. [0,100]² ∩ [200,300]² is empty, so nothing in `/Fx` can paint.
    static func bboxDocument() -> Data {
        MiniPDF.data(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /XObject << /Fx 5 0 R /Fy 6 0 R >> >> >>",
            MiniPDF.stream("q 0 0 100 100 re W n /Fx Do Q q 0 0 100 100 re W n /Fy Do Q"),
            MiniPDF.stream(
                "250 250 m 280 280 l S",
                entries: "/Type /XObject /Subtype /Form /BBox [200 200 300 300]"
            ),
            MiniPDF.stream(
                "10 50 m 90 50 l S",
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 300 300]"
            )
        ])
    }

    @Test("A form whose BBox misses the clip in force paints nothing (BH-329)")
    func disjointFormBBoxEmptiesTheClip() async throws {
        let url = try MiniPDF.write(Self.bboxDocument())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        // Old output: 2 primitives — the (250,250)→(280,280) stroke emitted `.insideClip`
        // at confidence 1.0, the clip having been *replaced* by the form's BBox.
        #expect(extraction.primitives.count == 1)
        let kept = try #require(Self.stroke(at: 50, in: extraction))
        #expect(kept.clipRelation == .insideClip)
        #expect(kept.confidence == 1)
        #expect(extraction.filterDecisions.contains { $0.rule == .entirelyOutsideClip })
        #expect(extraction.availability == .available)
    }

    // MARK: - BH-864: `/BaseState /OFF`

    /// `/D << /BaseState /OFF /ON [5 0 R] >>` and no `/OFF` array at all. PDF 32000-1
    /// 8.11.4.3, Table 101: BaseState "shall be applied to every group" before `/ON` and
    /// `/OFF` override it, so A (5 0 R) is on and B (6 0 R) is off.
    static func baseStateDocument() -> Data {
        MiniPDF.data(objects: [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] "
                + "/D << /BaseState /OFF /ON [5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Properties << /L0 5 0 R /L1 6 0 R >> >> >>",
            MiniPDF.stream("/OC /L0 BDC 10 10 m 100 10 l S EMC /OC /L1 BDC 10 20 m 100 20 l S EMC"),
            "<< /Type /OCG /Name (A) >>",
            "<< /Type /OCG /Name (B) >>"
        ])
    }

    @Test("`/BaseState /OFF` hides every group not listed under `/ON` (BH-864)")
    func baseStateOffHidesUnlistedGroups() async throws {
        let url = try MiniPDF.write(Self.baseStateDocument())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        // Old output: both strokes extracted and no hidden count — only `/OFF` was read.
        #expect(Self.stroke(at: 10, in: extraction)?.layerID == "L0")
        #expect(Self.stroke(at: 20, in: extraction) == nil, "B is off by base state")
        #expect(Self.hiddenCount(in: extraction) == 1)
        #expect(extraction.primitives.count == 1)
    }

    // MARK: - BH-865: form-local layer names the page does not know

    /// The page names only A (`/L0`). Three forms use local `/Properties` the page never
    /// lists: `/Fx` says `/oc0` for group G (6 0 R), `/Fy` says `/oc0` for group H (7 0 R),
    /// and `/Fz` says `/oc1` for group G again. No group is off.
    ///
    /// | stroke | form | local name | group | expected layer |
    /// |---|---|---|---|---|
    /// | y = 10 | `/Fx` | `/oc0` | G | `Fx/oc0` — first meeting of G |
    /// | y = 20 | `/Fy` | `/oc0` | H | `Fy/oc0` — a different group, a different ID |
    /// | y = 30 | `/Fz` | `/oc1` | G | `Fx/oc0` — the same group, the same ID |
    static func formLocalNamesDocument() -> Data {
        MiniPDF.data(objects: [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R 7 0 R] /D << >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Properties << /L0 5 0 R >> "
                + "/XObject << /Fx 8 0 R /Fy 9 0 R /Fz 10 0 R >> >> >>",
            MiniPDF.stream("q /Fx Do Q q /Fy Do Q q /Fz Do Q"),
            "<< /Type /OCG /Name (A) >>",
            "<< /Type /OCG /Name (G) >>",
            "<< /Type /OCG /Name (H) >>",
            MiniPDF.stream(
                "/OC /oc0 BDC 10 10 m 100 10 l S EMC",
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] "
                    + "/Resources << /Properties << /oc0 6 0 R >> >>"
            ),
            MiniPDF.stream(
                "/OC /oc0 BDC 10 20 m 100 20 l S EMC",
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] "
                    + "/Resources << /Properties << /oc0 7 0 R >> >>"
            ),
            MiniPDF.stream(
                "/OC /oc1 BDC 10 30 m 100 30 l S EMC",
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] "
                    + "/Resources << /Properties << /oc1 6 0 R >> >>"
            )
        ])
    }

    @Test("Form-local names the page does not know are keyed by group, not by name (BH-865)")
    func formLocalNamesAreKeyedByGroup() async throws {
        let url = try MiniPDF.write(Self.formLocalNamesDocument())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        // Old output: layers "oc0", "oc0", "oc1" — G and H collapsed into one layer and G
        // split into two.
        #expect(Self.stroke(at: 10, in: extraction)?.layerID == "Fx/oc0")
        #expect(Self.stroke(at: 20, in: extraction)?.layerID == "Fy/oc0")
        #expect(Self.stroke(at: 30, in: extraction)?.layerID == "Fx/oc0")
        #expect(extraction.layerIDs == ["Fx/oc0", "Fy/oc0"])
    }

    // MARK: - BH-867: a stray `EMC` inside a form

    /// The page opens a hidden section (`/L1` = B, off), draws the form `/Fx` inside it,
    /// then strokes at y = 10 still inside the section, ends it, and strokes at y = 30
    /// outside it. The form's stream begins with an unbalanced `EMC` and strokes at y = 20.
    ///
    /// PDF 32000-1 8.11.3.2 / 14.6: marked-content sections are lexical to the content
    /// stream they appear in; a form XObject is a separate stream, so its `EMC` cannot end a
    /// section the page began.
    ///
    /// | stroke | expected |
    /// |---|---|
    /// | y = 20 (in the form) | hidden — drawn inside the page's hidden section |
    /// | y = 10 (page, after the form) | hidden — the section is still open |
    /// | y = 30 (page, after `EMC`) | visible |
    static func strayEMCDocument() -> Data {
        MiniPDF.data(objects: [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /OFF [6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Properties << /L0 5 0 R /L1 6 0 R >> /XObject << /Fx 7 0 R >> >> >>",
            MiniPDF.stream("/OC /L1 BDC q /Fx Do Q 10 10 m 100 10 l S EMC 10 30 m 100 30 l S"),
            "<< /Type /OCG /Name (A) >>",
            "<< /Type /OCG /Name (B) >>",
            MiniPDF.stream(
                "EMC 10 20 m 100 20 l S",
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792]"
            )
        ])
    }

    @Test("A stray `EMC` inside a form cannot end the page's hidden section (BH-867)")
    func strayEMCInsideAFormIsContained() async throws {
        let url = try MiniPDF.write(Self.strayEMCDocument())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        // Old output: the form's `EMC` popped the page's entry, so y = 20 and y = 10 were
        // both extracted as visible snap targets and only the page's own `EMC` was counted
        // as unbalanced.
        #expect(Self.stroke(at: 20, in: extraction) == nil, "the form is inside the hidden section")
        #expect(Self.stroke(at: 10, in: extraction) == nil, "the section is still open after the form")
        let visible = try #require(Self.stroke(at: 30, in: extraction))
        #expect(visible.layerID == nil)
        #expect(Self.hiddenCount(in: extraction) == 2)
        #expect(extraction.primitives.count == 1)
        // The stray `EMC` is the one malformed operand; the page's own `EMC` balances.
        #expect(extraction.statistics.malformedOperandCount == 1)
    }
}
