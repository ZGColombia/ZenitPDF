import CoreGraphics
import Foundation
import Testing
@testable import ZPDFMeasureDictionary

/// NL-PLAT-06, the read half. Expected ratios are derived by hand from the dictionaries' numbers.
@Suite("PDF measure dictionaries — NL-PLAT-06")
struct PDFMeasureReaderTests {

    /// A one-page PDF whose page carries `viewports` (the `/VP` array's contents, verbatim).
    static func pdf(viewports: String?) -> CGPDFDocument {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2384 1684]\(viewports.map { " /VP [\($0)]" } ?? "") /Contents 4 0 R >>",
        ]
        objects.append("<< /Length 0 >>\nstream\n\nendstream")
        var body = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return CGPDFDocument(CGDataProvider(data: Data(body.utf8) as CFData)!)!
    }

    @Test("A CAD sheet at 1 in = 8 ft reads as 1:96, with its box and its text")
    func imperialViewport() throws {
        // 1 in = 8 ft: one point (1/72 in) is 8/72 ft = 0.111111 ft.
        let vp = "<< /Type /Viewport /Name (Plan) /BBox [100 100 2300 1600] /Measure << /Type /Measure /Subtype /RL /R (1 in = 8 ft) "
            + "/X [<< /Type /NumberFormat /U (ft) /C 0.1111111111 /D 16 >> << /U (in) /C 12 >>] >> >>"
        let viewports = PDFMeasureReader.viewports(in: Self.pdf(viewports: vp))
        let found = try #require(viewports.first)
        #expect(viewports.count == 1)
        #expect(found.pageIndex == 0)
        #expect(found.ratioText == "1 in = 8 ft")
        #expect(found.name == "Plan")
        #expect(found.unitLabel == "ft")
        #expect(found.bbox == CGRect(x: 100, y: 100, width: 2200, height: 1500))
        // 1 in on paper = 96 in real: 1:96.
        #expect(found.ratioDenominator == 96)
        #expect(abs(found.metresPerPoint - 0.1111111111 * 0.3048) < 1e-15)
    }

    @Test("A metric sheet at 1:100 reads from /X; /D converts from /X units and never sets the scale alone")
    func metricViewportReadsX() throws {
        // Old behaviour: /D was preferred and read as if from user space, so Zenit's own export
        // (/X mm at 35.2777… per point, /D m at 0.001 per mm) read as 0.001 m/pt, i.e. 1:2.835.
        // 1:100 → one point is 0.0254 / 72 × 100 m = 35.2777… mm.
        let vp = "<< /Type /Viewport /Measure << /Subtype /RL /R (1:100) /X [<< /U (mm) /C 35.2777777778 >>] "
            + "/D [<< /U (m) /C 0.001 >>] /A [<< /U (sq m) /C 0.000001 >>] >> >>"
        let found = try #require(PDFMeasureReader.viewports(in: Self.pdf(viewports: vp)).first)
        #expect(found.ratioDenominator == 100)
        #expect(found.unitLabel == "mm")
        #expect(found.bbox == nil)
        // 35.2777777778 mm per point is 100 × 0.0254 / 72 m (W-056: this case was pinned only on
        // the deleted second /VP reader).
        #expect(abs(found.metresPerPoint - 100 * 0.0254 / 72) < 1e-9)
    }

    @Test("/X in a unit label nobody names still reads through /D; a producer with /D only is read from user space")
    func distanceFormatFallbacks() throws {
        // /X in "units" at 1 per point, /D in metres at 0.0352777… per unit → 1:100.
        let viaX = "<< /Measure << /Subtype /RL /X [<< /U (units) /C 1 >>] /D [<< /U (m) /C 0.0352777777778 >>] >> >>"
        #expect(try #require(PDFMeasureReader.viewports(in: Self.pdf(viewports: viaX)).first).ratioDenominator == 100)
        // No /X at all (not conforming): /D can only mean metres per point, 1:50.
        let dOnly = "<< /Measure << /Subtype /RL /D [<< /U (m) /C 0.0176388888889 >>] >> >>"
        #expect(try #require(PDFMeasureReader.viewports(in: Self.pdf(viewports: dOnly)).first).ratioDenominator == 50)
    }

    @Test("No /VP, a geospatial measure, an unknown unit, and a zero factor all read as nothing")
    func nothingIsGuessed() {
        #expect(PDFMeasureReader.viewports(in: Self.pdf(viewports: nil)).isEmpty)
        #expect(PDFMeasureReader.viewports(in: Self.pdf(viewports: "<< /Measure << /Subtype /GEO >> >>")).isEmpty)
        #expect(PDFMeasureReader.viewports(in: Self.pdf(viewports: "<< /Measure << /Subtype /RL /X [<< /U (furlong) /C 1 >>] >> >>")).isEmpty)
        #expect(PDFMeasureReader.viewports(in: Self.pdf(viewports: "<< /Measure << /Subtype /RL /X [<< /U (m) /C 0 >>] >> >>")).isEmpty)
    }
}
