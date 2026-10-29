import Foundation

/// A six-page PDF that declares `/PageLabels` and a `/Names /Dests` name tree.
///
/// **Why this is not a corpus fixture.** `ZPDFTestingSupport` is the source of every PDF
/// in these tests, and it should stay that way — but the corpus has no document with
/// page labels and no document with named destinations, and those are exactly the two
/// features spec 20.1 calls out and that a construction set depends on (`A-102` is a
/// label, not a page number). Rather than assert nothing about them, this file writes
/// the minimum bytes needed to exercise the two catalog readers: six empty pages, a
/// `/Nums` number tree, and two named destinations. It is a probe, not a fixture: it
/// carries no geometry and nothing else asserts against it.
///
/// The labels it declares, by page index:
///
/// | index | 0 | 1 | 2 | 3 | 4 | 5 |
/// |-------|---|---|---|---|---|---|
/// | label | `i` | `ii` | `A-101` | `A-102` | `A-103` | `D-1` |
enum LabelledProbeDocument {

    static let pageCount = 6
    static let expectedLabels = ["i", "ii", "A-101", "A-102", "A-103", "D-1"]
    /// `SHEET-A102` points at page index 3, whose label is `A-102`.
    static let sheetDestinationName = "SHEET-A102"
    static let sheetDestinationPageIndex = 3
    static let coverDestinationName = "COVER"
    static let coverDestinationPageIndex = 0

    /// Writes the probe document and returns its URL.
    static func write(into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("page-labels-probe.pdf", isDirectory: false)
        try data().write(to: url, options: .atomic)
        return url
    }

    static func data() -> Data {
        // Object numbers: 1 catalog, 2 page tree, 3…8 pages.
        let firstPageObject = 3
        let kids = (0..<pageCount)
            .map { "\(firstPageObject + $0) 0 R" }
            .joined(separator: " ")

        var bodies: [String] = []
        bodies.append("""
        << /Type /Catalog /Pages 2 0 R \
        /PageLabels << /Nums [0 << /S /r >> 2 << /S /D /P (A-) /St 101 >> 5 << /S /D /P (D-) /St 1 >>] >> \
        /Names << /Dests << /Names [\
        (\(coverDestinationName)) [\(firstPageObject + coverDestinationPageIndex) 0 R /XYZ 0 0 0] \
        (\(sheetDestinationName)) [\(firstPageObject + sheetDestinationPageIndex) 0 R /XYZ 100 200 0]\
        ] >> >> >>
        """)
        bodies.append("<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>")
        for _ in 0..<pageCount {
            bodies.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>")
        }

        var out = Data("%PDF-1.7\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }

        let xrefOffset = out.count
        var xref = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        xref += "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(xref.utf8))
        return out
    }
}
