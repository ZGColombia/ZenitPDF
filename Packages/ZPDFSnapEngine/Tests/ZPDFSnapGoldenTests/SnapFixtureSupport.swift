import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
import ZPDFGeometry
import ZPDFSnapEngine
import ZPDFSnapScenario
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// Builds a snap index from a real fixture PDF, through the real extractor.
///
/// The golden suite is the only place that does this: it is the one that answers "does the
/// engine agree with the corpus", and it is deliberately end-to-end from bytes on disk.
enum SnapFixture {

    struct Built {
        let handle: FixtureHandle
        let extraction: VectorPageExtraction
        let page: PageDescriptor
        let index: SnapIndex
    }

    static func build(
        _ kind: FixtureKind,
        pageIndex: Int = 0,
        markups: [SnapMarkupGeometry] = [],
        boundaries: [SnapBoundary] = []
    ) async throws -> Built {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-snap-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let handle = try ZPDFFixtures.make(kind, in: directory)

        let extractor = VectorExtractor()
        let extraction = try await extractor.extract(
            documentAt: handle.url, pageIndex: pageIndex
        )

        let manifestPage = handle.manifest.pages[pageIndex]
        let page = PageDescriptor(
            id: PageID(UUID(uuidString: "00000000-0000-4000-8000-0000000000A1") ?? UUID()),
            documentID: DocumentID(
                UUID(uuidString: "00000000-0000-4000-8000-00000000D0C1") ?? UUID()
            ),
            index: pageIndex,
            label: String(pageIndex + 1),
            boxes: PageBoxes(
                media: rect(manifestPage.mediaBox),
                crop: rect(manifestPage.cropBox)
            ),
            rotation: try PageRotation.normalizing(degrees: manifestPage.rotation)
        )

        let index = try SnapIndexBuilder().build(
            page: page,
            extraction: extraction,
            markups: markups,
            boundaries: boundaries
        )
        return Built(handle: handle, extraction: extraction, page: page, index: index)
    }

    static func rect(_ r: FixtureRect) -> PDFRect {
        PDFRect(x: r.llx, y: r.lly, width: r.urx - r.llx, height: r.ury - r.lly)
    }

    /// A layout that puts page point `(x, y)` at view point `(x * zoom, y * zoom)` for an
    /// unrotated page whose crop box starts at the origin, so a test can write cursor positions
    /// in page coordinates and stay readable.
    static func layout(zoom: Double, backingScale: Double = 2.0) -> PageViewLayout {
        PageViewLayout(anchor: .zero, zoom: zoom, backingScale: backingScale, isViewFlipped: false)
    }

    /// The view point that corresponds to a page point, through the real converter.
    static func viewPoint(
        _ page: PageDescriptor, _ layout: PageViewLayout, _ point: PDFPoint
    ) throws -> CGPoint {
        try PageCoordinateConverter(page: page, layout: layout).pageToView(point)
    }
}
