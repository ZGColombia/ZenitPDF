import Foundation
import Testing
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFVectorExtraction

/// Finding S17-02, from this side of the seam.
///
/// `ZPDFCompare` cannot itself reach `GeometryService.xpc` — the service client is a
/// macOS-only package and this one compiles for iOS 17 as well — so what it can
/// guarantee is narrower and worth stating precisely: the comparator has exactly one
/// way to reach a PDF, that way is injected, and it reports honestly which process it
/// parses in. The out-of-process half is proved in `ZPDFServiceClient`'s
/// `CompareIsolationTests`, against a real second process.
struct IsolationContractTests {

    @Test("The in-process source declares itself in-process, and the comparator repeats it")
    func inProcessSourceIsLabelled() async throws {
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let source = InProcessRevisionDocumentSource(provider: provider)
        #expect(source.isolation == .inProcess)
        #expect(RevisionComparator(source: source).isolation == .inProcess)
        print("S17-02 compare contract: the in-process source reports \(source.isolation)")
    }

    @Test("A stub source proves the comparator reaches a PDF through the source and nowhere else")
    func comparatorTouchesNothingButItsSource() async throws {
        // The stub parses nothing at all. If the comparator still produced a raster,
        // it would have to be reaching PDFKit behind the source's back — which is
        // exactly the shape of the defect S17-02 recorded.
        let source = RefusingRevisionDocumentSource()
        let comparator = RevisionComparator(source: source)
        #expect(comparator.isolation == .outOfProcess)
        let reference = RevisionPageReference(
            document: DocumentHandle(rawValue: 0),
            pageIndex: 0,
            box: .crop,
            fileURL: URL(fileURLWithPath: "/nonexistent/revision.pdf"),
            label: "stub")
        await #expect(throws: CompareFault.vectorSourceUnavailable(label: "stub")) {
            _ = try await comparator.render(reference, scale: 2)
        }
        await #expect(throws: CompareFault.vectorSourceUnavailable(label: "stub")) {
            _ = try await comparator.pageBox(of: reference)
        }
    }
}

/// A source that refuses everything. Used to show the comparator has no second door.
private struct RefusingRevisionDocumentSource: RevisionDocumentSourcing {
    var isolation: RevisionParsingIsolation { .outOfProcess }

    func pageBox(of reference: RevisionPageReference) async throws -> CGRect {
        throw CompareFault.vectorSourceUnavailable(label: reference.label)
    }

    func render(
        _ reference: RevisionPageReference,
        scale: Double,
        maximumPixels: Int
    ) async throws -> RenderedRevisionPage {
        throw CompareFault.vectorSourceUnavailable(label: reference.label)
    }

    func extractGeometry(_ reference: RevisionPageReference) async throws -> VectorPageExtraction {
        throw CompareFault.vectorSourceUnavailable(label: reference.label)
    }
}
