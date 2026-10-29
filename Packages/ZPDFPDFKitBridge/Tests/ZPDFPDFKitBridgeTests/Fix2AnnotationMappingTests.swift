import CoreGraphics
import Foundation
import Testing
@testable import ZPDFPDFKitBridge

/// Regression tests for the annotation-reading findings of bug hunt 2
/// (BH-028, BH-170, BH-570, BH-571).
@Suite("Fix 2 — annotation mapping")
struct Fix2AnnotationMappingTests {

    private func polygonAndInkFixture() throws -> URL {
        try HandBuiltPDF.onePage(
            content: "",
            mediaBox: "[0 0 300 300]",
            pageExtra: "/Annots [5 0 R 6 0 R]",
            additional: [
                "<< /Type /Annot /Subtype /Polygon /Rect [10 10 110 110] /Vertices [10 10 110 10 110 110] /C [1 0 0] /F 4 >>",
                "<< /Type /Annot /Subtype /Ink /Rect [100 100 250 250] /InkList [[100 100 150 200 250 100] [110 240 240 240]] /C [0 0 1] /F 4 >>"
            ],
            label: "polygon-and-ink"
        )
    }

    // MARK: - BH-028

    @Test("BH-028: a polygon imported from another tool keeps its vertices")
    func polygonVerticesAreRead() async throws {
        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: try polygonAndInkFixture())
        let annotations = try await provider.annotations(of: opened.handle, pageIndex: 0)
        let polygon = try #require(annotations.first { $0.kind == .polygon })
        // Old code: [] — the flat NSNumber array matched `as? [NSValue]` first.
        #expect(polygon.points == [
            CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 110, y: 110)
        ])
        await provider.close(opened.handle)
    }

    @Test("BH-028: both shapes PDFKit hands a point list back in are read")
    func pointListShapes() {
        let numbers: [NSNumber] = [1, 2, 3, 4, 5]
        // Old code: [] for the number shape.
        #expect(AnnotationMapping.pointList(numbers) == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
        let boxed: [NSValue] = [NSValue(point: NSPoint(x: 7, y: 8)), NSValue(point: NSPoint(x: 9, y: 10))]
        #expect(AnnotationMapping.pointList(boxed) == [CGPoint(x: 7, y: 8), CGPoint(x: 9, y: 10)])
        #expect(AnnotationMapping.pointList(nil).isEmpty)
        #expect(AnnotationMapping.pointList("not a list").isEmpty)
    }

    // MARK: - BH-170

    @Test("BH-170: ink strokes stored as number arrays are read, not N empty paths")
    func inkPathsAreRead() async throws {
        let numberStrokes: [[NSNumber]] = [[1, 2, 3, 4], [5, 6, 7, 8, 9, 10]]
        // Old code: [[], []].
        #expect(AnnotationMapping.inkPaths(numberStrokes) == [
            [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
            [CGPoint(x: 5, y: 6), CGPoint(x: 7, y: 8), CGPoint(x: 9, y: 10)]
        ])
        let boxedStrokes: [[NSValue]] = [[NSValue(point: NSPoint(x: 1, y: 1))]]
        #expect(AnnotationMapping.inkPaths(boxedStrokes) == [[CGPoint(x: 1, y: 1)]])

        let provider = PDFKitDocumentProvider()
        let opened = try await provider.open(fileAt: try polygonAndInkFixture())
        let annotations = try await provider.annotations(of: opened.handle, pageIndex: 0)
        let ink = try #require(annotations.first { $0.kind == .ink })
        // Old code: [] — PDFKit hands /InkList back as Bézier paths, which no branch read.
        #expect(ink.inkPaths == [
            [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 200), CGPoint(x: 250, y: 100)],
            [CGPoint(x: 110, y: 240), CGPoint(x: 240, y: 240)]
        ])
        await provider.close(opened.handle)
    }

    // MARK: - BH-570

    @Test("BH-570: a GoTo page PDFKit cannot place is nil, not NSNotFound")
    func notFoundPageIndexIsNil() {
        // Old code passed `index(for:)` through: .goToPage(pageIndex: 9223372036854775807).
        #expect(AnnotationMapping.validPageIndex(NSNotFound, pageCount: 10) == nil)
        #expect(AnnotationMapping.validPageIndex(10, pageCount: 10) == nil)
        #expect(AnnotationMapping.validPageIndex(-1, pageCount: 10) == nil)
        #expect(AnnotationMapping.validPageIndex(3, pageCount: 10) == 3)
        #expect(AnnotationMapping.pageIndex(of: nil) == nil)
    }

    // MARK: - BH-571

    @Test("BH-571: a +HHmm offset without apostrophes keeps its minutes")
    func apostropheLessOffset() throws {
        let reference = try #require(AnnotationMapping.pdfDate(from: "D:20240101063000Z"))
        // 12:00 at +05:30 is 06:30 UTC. Old code read the minutes from index 18 ("0") and
        // produced 07:00 UTC — thirty minutes off.
        let compact = try #require(AnnotationMapping.pdfDate(from: "D:20240101120000+0530"))
        #expect(compact == reference)
        #expect(AnnotationMapping.pdfDate(from: "D:20240101120000+05'30'") == reference)
        #expect(AnnotationMapping.pdfDate(from: "D:20240101120000+05'30") == reference)
        let hoursOnly = try #require(AnnotationMapping.pdfDate(from: "D:20240101120000+05"))
        #expect(hoursOnly == reference.addingTimeInterval(30 * 60))
        let negative = try #require(AnnotationMapping.pdfDate(from: "D:20240101120000-0130"))
        #expect(negative == (try #require(AnnotationMapping.pdfDate(from: "D:20240101133000Z"))))
    }
}
