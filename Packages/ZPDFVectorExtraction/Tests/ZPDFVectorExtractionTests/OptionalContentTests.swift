import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// Optional-content membership (CR-48), plus the lexical marked-content and current-point
/// rules of CR-39 and CR-42 as the scanner actually meets them: through `CGPDFScanner`, on a
/// document whose objects are written out below.
///
/// The synthetic corpus in `ZPDFTestingSupport` has no membership dictionary, no `/VE`, and
/// no form-local `/Properties`, and its writer is internal to that package. The document here
/// is therefore assembled by hand — a dozen objects and a correct cross-reference table — and
/// every expectation beside it is derived from PDF 32000-1 8.11.2.2 by hand, never from the
/// code under test (`QUALITY_BAR` 2.6).
@Suite("Optional content membership")
struct OptionalContentTests {

    // MARK: - A minimal PDF writer

    enum MiniPDF {
        /// Assembles a document from object bodies: `objects[i]` is object `i + 1`, written
        /// without its `obj`/`endobj` wrapper. Object 1 must be the catalog.
        static func data(objects: [String]) -> Data {
            var out = Data("%PDF-1.7\n".utf8)
            var offsets: [Int] = []
            for (index, body) in objects.enumerated() {
                offsets.append(out.count)
                out.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
            }
            let xrefOffset = out.count
            var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
            for offset in offsets { xref += String(format: "%010d 00000 n \n", offset) }
            xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
            xref += "startxref\n\(xrefOffset)\n%%EOF\n"
            out.append(Data(xref.utf8))
            return out
        }

        static func stream(_ content: String, entries: String = "") -> String {
            "<< /Length \(content.utf8.count) \(entries) >>\nstream\n\(content)\nendstream"
        }

        static func write(_ data: Data) throws -> URL {
            let directory = try ExtractionTestSupport.makeTemporaryDirectory()
            let url = directory.appendingPathComponent("optional-content.pdf")
            try data.write(to: url)
            return url
        }
    }

    /// Two groups — A on, B off in `/D` — six memberships, one form XObject with a
    /// form-local name for A, and one stroke per case at a distinct `y`.
    ///
    /// | y | inside | expected |
    /// |---|---|---|
    /// | 10 | `/L0` = A | visible, layer `L0` |
    /// | 20 | `/L1` = B (off) | hidden |
    /// | 30 | `/M1` = OCMD `/OCGs [A B] /P /AllOn` | hidden — B is off |
    /// | 40 | `/M2` = OCMD `/VE [/Not A]` | hidden — A is on |
    /// | 50 | `/M3` = OCMD `/OCGs [A B] /P /AnyOff` | visible — B is off |
    /// | 60 | `/M4` = OCMD `/OCGs [A B] /P /AllOff` | hidden — A is on |
    /// | 70 | `/L1 BDC q EMC` … stroke … `Q` | visible, unlayered (CR-39) |
    /// | 80 | `q /L1 BDC Q` … stroke … `EMC` | hidden (CR-39) |
    /// | 90→ | `m l l h` then `60 290 l S` | the segment (10,90)→(60,290) exists (CR-42) |
    /// | 300 | form `/F0` = A, drawn inside the form | visible, layer `L0`, not `F0` (CR-48) |
    static func document() -> Data {
        let page = """
        /OC /L0 BDC 10 10 m 100 10 l S EMC
        /OC /L1 BDC 10 20 m 100 20 l S EMC
        /OC /M1 BDC 10 30 m 100 30 l S EMC
        /OC /M2 BDC 10 40 m 100 40 l S EMC
        /OC /M3 BDC 10 50 m 100 50 l S EMC
        /OC /M4 BDC 10 60 m 100 60 l S EMC
        /OC /L1 BDC q EMC 10 70 m 100 70 l S Q
        q /OC /L1 BDC Q 10 80 m 100 80 l S EMC
        10 90 m 110 90 l 110 190 l h 60 290 l S
        q 1 0 0 1 0 0 cm /Fx Do Q
        """
        let form = "/OC /F0 BDC 10 300 m 100 300 l S EMC"
        return MiniPDF.data(objects: [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /OFF [6 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
                + "/Resources << /Properties << /L0 5 0 R /L1 6 0 R /M1 7 0 R /M2 8 0 R /M3 9 0 R /M4 10 0 R >> "
                + "/XObject << /Fx 11 0 R >> >> >>",
            MiniPDF.stream(page),
            "<< /Type /OCG /Name (A) >>",
            "<< /Type /OCG /Name (B) >>",
            "<< /Type /OCMD /OCGs [5 0 R 6 0 R] /P /AllOn >>",
            "<< /Type /OCMD /VE [/Not 5 0 R] >>",
            "<< /Type /OCMD /OCGs [5 0 R 6 0 R] /P /AnyOff >>",
            "<< /Type /OCMD /OCGs [5 0 R 6 0 R] /P /AllOff >>",
            MiniPDF.stream(
                form,
                entries: "/Type /XObject /Subtype /Form /BBox [0 0 612 792] "
                    + "/Resources << /Properties << /F0 5 0 R >> >>"
            )
        ])
    }

    /// The horizontal stroke at `y`, if it was extracted.
    static func stroke(at y: Double, in extraction: VectorPageExtraction) -> VectorPrimitive? {
        extraction.primitives.first { primitive in
            guard primitive.kind == .lineSegment, case let .line(line) = primitive.geometry else { return false }
            return abs(line.start.y - y) <= 1e-9 && abs(line.end.y - y) <= 1e-9
                && abs(line.start.x - 10) <= 1e-9 && abs(line.end.x - 100) <= 1e-9
        }
    }

    @Test("`/P /AllOn`, `/AnyOff`, `/AllOff` and `/VE` decide membership visibility (CR-48)")
    func membershipPoliciesThroughTheScanner() async throws {
        let url = try MiniPDF.write(Self.document())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        #expect(Self.stroke(at: 10, in: extraction)?.layerID == "L0")
        #expect(Self.stroke(at: 20, in: extraction) == nil, "B is off in /D")
        // Old output: the three lines below were extracted — only `/AnyOn` was implemented,
        // so `/AllOn` with B off read as visible, `/VE [/Not A]` was ignored, and `/AllOff`
        // with A on read as visible.
        #expect(Self.stroke(at: 30, in: extraction) == nil, "/AllOn with B off is hidden")
        #expect(Self.stroke(at: 40, in: extraction) == nil, "/VE [/Not A] with A on is hidden")
        #expect(Self.stroke(at: 60, in: extraction) == nil, "/AllOff with A on is hidden")
        // Old output: the `/AnyOff` stroke was hidden (every-group-off was the only rule).
        #expect(Self.stroke(at: 50, in: extraction) != nil, "/AnyOff with B off is visible")
    }

    @Test("`q`/`Q` neither restores nor ends a marked-content section (CR-39, through the scanner)")
    func markedContentIsLexicalThroughTheScanner() async throws {
        let url = try MiniPDF.write(Self.document())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        // Old output: y = 70 absent (the `Q` restored the hidden depth), y = 80 present.
        let afterEMC = try #require(Self.stroke(at: 70, in: extraction))
        #expect(afterEMC.layerID == nil)
        #expect(Self.stroke(at: 80, in: extraction) == nil)
    }

    @Test("A segment after `h` starts at the closed subpath's start (CR-42, through the scanner)")
    func segmentAfterCloseThroughTheScanner() async throws {
        let url = try MiniPDF.write(Self.document())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        let lines = extraction.primitives.compactMap { primitive -> VectorLine? in
            if case let .line(line) = primitive.geometry { return line }
            return nil
        }
        // Old output: no such line, and the page reported `malformedOperandCount` 1 with a
        // `.malformedContentStream` partial reason.
        #expect(lines.contains(VectorLine(start: CGPoint(x: 10, y: 90), end: CGPoint(x: 60, y: 290))))
        #expect(extraction.statistics.malformedOperandCount == 0)
        let malformed = extraction.partialReasons.contains {
            if case .malformedContentStream = $0 { return true }
            return false
        }
        #expect(!malformed)
    }

    @Test("A form-local property name resolves to the page's name for the same group (CR-48)")
    func formLocalLayerNameResolvesToThePageName() async throws {
        let url = try MiniPDF.write(Self.document())
        defer { ExtractionTestSupport.remove(url.deletingLastPathComponent()) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)

        let inForm = try #require(Self.stroke(at: 300, in: extraction))
        #expect(inForm.nestingDepth == 1)
        // Old output: "F0" — a name the page's layer list does not contain, so hiding the
        // page's `L0` would have left this stroke snappable.
        #expect(inForm.layerID == "L0")
        // `M3` is the visible `/AnyOff` membership at y = 50; nothing else visible is layered.
        #expect(extraction.layerIDs == ["L0", "M3"])
    }

    // MARK: - The rule on values

    @Test("Every `/P` policy over every on/off combination, by hand")
    func policyTable() {
        typealias V = OptionalContentVisibility
        let on = false
        let off = true
        // One on, one off.
        #expect(V.isHidden(.init(groupsHidden: [on, off], policy: .anyOn)) == false)
        #expect(V.isHidden(.init(groupsHidden: [on, off], policy: .allOn)) == true)
        #expect(V.isHidden(.init(groupsHidden: [on, off], policy: .anyOff)) == false)
        #expect(V.isHidden(.init(groupsHidden: [on, off], policy: .allOff)) == true)
        // Both off.
        #expect(V.isHidden(.init(groupsHidden: [off, off], policy: .anyOn)) == true)
        #expect(V.isHidden(.init(groupsHidden: [off, off], policy: .allOn)) == true)
        #expect(V.isHidden(.init(groupsHidden: [off, off], policy: .anyOff)) == false)
        #expect(V.isHidden(.init(groupsHidden: [off, off], policy: .allOff)) == false)
        // Both on.
        #expect(V.isHidden(.init(groupsHidden: [on, on], policy: .anyOn)) == false)
        #expect(V.isHidden(.init(groupsHidden: [on, on], policy: .allOn)) == false)
        #expect(V.isHidden(.init(groupsHidden: [on, on], policy: .anyOff)) == true)
        #expect(V.isHidden(.init(groupsHidden: [on, on], policy: .allOff)) == true)
        // No groups at all: visible whatever the policy says.
        for policy in [V.Policy.anyOn, .allOn, .anyOff, .allOff] {
            #expect(V.isHidden(.init(groupsHidden: [], policy: policy)) == false)
        }
    }

    @Test("`/VE` takes precedence over `/OCGs` and evaluates And, Or and Not")
    func visibilityExpressions() {
        typealias V = OptionalContentVisibility
        let on = V.Expression.group(isHidden: false)
        let off = V.Expression.group(isHidden: true)
        #expect(V.isHidden(.init(expression: .not(on), groupsHidden: [])) == true)
        #expect(V.isHidden(.init(expression: .not(off), groupsHidden: [true])) == false)
        #expect(V.isHidden(.init(expression: .and([on, off]), groupsHidden: [])) == true)
        #expect(V.isHidden(.init(expression: .and([on, on]), groupsHidden: [])) == false)
        #expect(V.isHidden(.init(expression: .or([off, off]), groupsHidden: [])) == true)
        #expect(V.isHidden(.init(expression: .or([off, on]), groupsHidden: [])) == false)
        #expect(V.isHidden(.init(expression: .and([on, .not(.or([off, off]))]), groupsHidden: [])) == false)
        // The identities: an empty And is true, an empty Or is false.
        #expect(V.isHidden(.init(expression: .and([]), groupsHidden: [])) == false)
        #expect(V.isHidden(.init(expression: .or([]), groupsHidden: [])) == true)
    }
}
