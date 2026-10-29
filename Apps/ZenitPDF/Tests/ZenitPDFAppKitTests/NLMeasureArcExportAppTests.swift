import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFContracts
import ZPDFUIPresentation
@testable import ZenitPDFAppKit

/// NL-MEASURE-05 (ADR-0030 §5.6): an arc edge reaches the flattened and the annotated PDF export as
/// cubic Bézier curves (`c` operators), drawn within 0.01 pt of the circle; the quantity is untouched.
///
/// The markup is the golden area at 100 pt = 1 m: (100,100)–(1100,100)–(1100,600)–(100,600) with
/// its right side an outward semicircle of radius 250 pt. A quarter-turn cubic would stray
/// 2.7e-4 × 250 ≈ 0.068 pt, so the semicircle is four eighth-turn cubics (≈ 0.001 pt) — four `c`
/// for the fill and four for the stroke. The fixture drawing itself holds one straight line.
@MainActor
@Suite(.appTierSerialised)
struct NLMeasureArcExportAppTests {

    nonisolated final class Counter {
        var curves = 0
    }

    /// The semicircle's centre in the two spaces a Core Graphics PDF context writes a path in:
    /// page space — a fill, which Core Graphics writes after resolving the matrix — and the
    /// renderer's pixel space, where a page point (x, y) of this uncropped 1684 × 2384 sheet at
    /// zoom 1 is (x, 2384 − y) — a stroke, whose width needs the matrix kept. Radius 250 in both.
    nonisolated static let centres = [(x: 1100.0, y: 350.0), (x: 1100.0, y: 2034.0)]
    nonisolated static let radius = 250.0

    /// Counts the `c` operators in a content stream whose end point lies on the semicircle's circle
    /// (within the 0.01 pt drawing tolerance), following Form XObjects it paints. Glyph outlines —
    /// the caption pill is drawn as outlines on paper — are curves too, and are not on the circle.
    nonisolated static func curves(in stream: CGPDFContentStreamRef) -> Int {
        guard let table = CGPDFOperatorTableCreate() else { return 0 }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let info else { return }
            var y: CGPDFReal = 0, x: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &y), CGPDFScannerPopNumber(scanner, &x) else { return }
            let onCircle = NLMeasureArcExportAppTests.centres.contains { centre in
                let dx = Double(x) - centre.x, dy = Double(y) - centre.y
                return Swift.abs((dx * dx + dy * dy).squareRoot() - NLMeasureArcExportAppTests.radius) <= 0.01
            }
            guard onCircle else { return }
            Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue().curves += 1
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let info else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Form" else { return }
            var resources: CGPDFDictionaryRef?
            _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let nested = CGPDFContentStreamCreateWithStream(xobject, resources ?? dictionary, content)
            Unmanaged<Counter>.fromOpaque(info).takeUnretainedValue().curves += NLMeasureArcExportAppTests.curves(in: nested)
            CGPDFContentStreamRelease(nested)
        }
        let counter = Counter()
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(counter).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        return counter.curves
    }

    /// `c` operators on page 1 and in its annotations' normal appearances.
    nonisolated static func curveCounts(in url: URL) throws -> (page: Int, appearances: Int) {
        let document = try #require(CGPDFDocument(url as CFURL))
        let page = try #require(document.page(at: 1))
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        let onPage = curves(in: content)
        var inAppearances = 0
        var annotations: CGPDFArrayRef?
        if let dictionary = page.dictionary, CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations {
            for index in 0..<CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                var appearance: CGPDFDictionaryRef?
                var normal: CGPDFStreamRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation,
                      CGPDFDictionaryGetDictionary(annotation, "AP", &appearance), let appearance,
                      CGPDFDictionaryGetStream(appearance, "N", &normal), let normal else { continue }
                guard let streamDictionary = CGPDFStreamGetDictionary(normal) else { continue }
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(streamDictionary, "Resources", &resources)
                let stream = CGPDFContentStreamCreateWithStream(normal, resources ?? streamDictionary, content)
                inAppearances += curves(in: stream)
                CGPDFContentStreamRelease(stream)
            }
        }
        return (onPage, inAppearances)
    }

    @Test("Flattened and annotated exports draw the arc edge as Bézier curves")
    func arcsExportAsCurves() async throws {
        let harness = try await NLMeasureR2Harness.make("Arc Export.pdf")
        defer { NLMeasureR2Harness.tearDown(harness) }
        let core = harness.core
        try await core.commands.calibrate(page: harness.page, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 100, y: 0), knownLength: 1, knownLengthUnit: .metre)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let bay = ZPDFContracts.MarkupRecord(
            id: MarkupID(UUID()), documentID: DocumentID(core.snapshot.documentID), pageID: harness.page,
            kind: .measurement, tool: .area, subject: "Bay", author: "t",
            style: MarkupStyle(color: AppMeasurementToolPresenter.measurementInk, fill: AppMeasurementToolPresenter.measurementFill(for: AppMeasurementToolPresenter.measurementInk)),
            geometry: MeasurementGeometry(pageID: harness.page, polygons: [PolygonGeometry(outer: PolygonRing(
                points: [PDFPoint(x: 100, y: 100), PDFPoint(x: 1100, y: 100), PDFPoint(x: 1100, y: 600), PDFPoint(x: 100, y: 600)],
                isClosed: true,
                bulges: [0, 1, 0, 0]
            ))]),
            createdAt: stamp, modifiedAt: stamp
        )
        try await core.commands.perform(.addMarkup(bay))
        await core.refresh()
        // The quantity is the arc's, exact: 50 + 3.125π m².
        let area = NSDecimalNumber(decimal: try #require(await core.session.markup(bay.id)?.measurement?[.netArea]?.value)).doubleValue
        #expect(Swift.abs(area - (50 + 3.125 * .pi)) <= (50 + 3.125 * .pi) * 1e-12)

        let flattened = harness.directory.appendingPathComponent("marked.pdf")
        _ = try await harness.controller.writeDrawing(.flattened, for: harness.document, to: flattened)
        let marked = try Self.curveCounts(in: flattened)
        // Old output: 0 — the arc was painted as its flattened chords.
        #expect(marked.page == 8, "flattened: \(marked.page) curves")

        let annotatedURL = harness.directory.appendingPathComponent("annotated.pdf")
        _ = try await harness.controller.writeAnnotatedDrawing(for: harness.document, to: annotatedURL)
        let annotated = try Self.curveCounts(in: annotatedURL)
        #expect(annotated.appearances == 8, "annotated: \(annotated.appearances) curves in the appearances")
    }
}
