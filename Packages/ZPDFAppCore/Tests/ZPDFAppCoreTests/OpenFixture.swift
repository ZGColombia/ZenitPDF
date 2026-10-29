import Foundation
import ZPDFAppCore
import ZPDFContracts
import ZPDFPDFKitBridge
import ZPDFSnapEngine
import ZPDFTestingSupport
import ZPDFVectorExtraction

/// A fixture opened through the real PDF stack: PDFKit behind the exception barrier for
/// page geometry, `CGPDFScanner` for vector geometry, and a snap index built over both.
///
/// Every test in this target starts here rather than from hand-written page descriptors,
/// because the point of this package is that the UI runs on the real engines — and a test
/// that invents its own `PageDescriptor` is not testing that.
struct OpenedFixture {

    /// Where the fixture was written.
    let url: URL
    /// What the fixture generator says is in the file, with closed-form geometry.
    let manifest: FixtureManifest
    /// The contract page descriptors, read out of the file by PDFKit.
    let pages: [ZPDFContracts.PageDescriptor]
    /// The document identity every markup is stamped with.
    let documentID: DocumentID
    /// Page 0's vector geometry, or `nil` when the page has none.
    let extraction: VectorPageExtraction?

    /// The first page.
    var firstPage: ZPDFContracts.PageDescriptor { pages[0] }

    /// Writes a fixture into a temporary directory, opens it, and extracts page 0.
    static func open(_ kind: FixtureKind, in directory: URL) async throws -> OpenedFixture {
        let handle = try ZPDFFixtures.make(kind, in: directory)
        let documentID = DocumentID(UUID())

        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(.url(handle.url), password: nil, limits: .standard)
        let descriptors = try await provider.pageDescriptors(of: opened.handle, range: nil)
        await provider.close(opened.handle)

        let pages = try descriptors.map { descriptor in
            ZPDFContracts.PageDescriptor(
                id: PageID(UUID()),
                documentID: documentID,
                index: descriptor.index,
                label: descriptor.label,
                boxes: PageBoxes(
                    media: PDFRect(
                        x: descriptor.boxes.media.origin.x,
                        y: descriptor.boxes.media.origin.y,
                        width: descriptor.boxes.media.size.width,
                        height: descriptor.boxes.media.size.height
                    ),
                    crop: PDFRect(
                        x: descriptor.boxes.crop.origin.x,
                        y: descriptor.boxes.crop.origin.y,
                        width: descriptor.boxes.crop.size.width,
                        height: descriptor.boxes.crop.size.height
                    )
                ),
                rotation: try PageRotation.normalizing(degrees: descriptor.rotation)
            )
        }

        let extractor = VectorExtractor()
        let extraction = try? await extractor.extract(documentAt: handle.url, pageIndex: 0)

        return OpenedFixture(
            url: handle.url,
            manifest: handle.manifest,
            pages: pages,
            documentID: documentID,
            extraction: extraction
        )
    }
}

/// A scratch directory for one test.
///
/// Fixtures are written to disk because that is how the vector extractor reads a document —
/// it takes a URL, not bytes — so the test corpus is real files for the duration of a run.
/// Cleanup is explicit rather than a `deinit`: a `deinit` on a class shared across an
/// `await` would need `@unchecked Sendable`, which this repository does not allow.
struct TemporaryDirectory {

    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-appcore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
