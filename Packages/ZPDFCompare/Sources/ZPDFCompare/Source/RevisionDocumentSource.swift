import CoreGraphics
import Foundation
import ZPDFPDFKitBridge
import ZPDFVectorExtraction

/// Where the bytes of a revision PDF are actually parsed.
///
/// Revision Compare opens the most untrusted file the product handles: the drawing a
/// subcontractor or an architect just sent. Until finding S17-02 it was also the only
/// document path that skipped the service boundary — PDFKit rasterised it and
/// `CGPDFScanner` re-scanned it, both inside the application process. This enum makes
/// the answer to "where did that happen" a value a test and the application can assert
/// on rather than a property of whichever initialiser happened to be called.
public enum RevisionParsingIsolation: String, Sendable, Hashable, Codable, CustomStringConvertible {
    /// Every byte of the compared document is parsed in a separate, sandboxed
    /// process. What the shipping application must use.
    case outOfProcess
    /// Parsed in this process. `swift test` and headless tools only: an `.xpc`
    /// service cannot be launched outside a host app bundle, so the suites that
    /// exercise the comparison maths run the parser here.
    case inProcess

    public var description: String { rawValue }
}

/// Everything Revision Compare needs from a document it did not write.
///
/// Three operations, and they are exactly the three that touch attacker bytes: the
/// page box, the page raster, and the page's vector geometry. Everything else in this
/// package — alignment, the raster diff, the vector diff, the overlay compositor —
/// operates on values *we* produced from those three, so it is our arithmetic on our
/// own buffers and belongs in whichever process asked the question.
///
/// ``RevisionComparator`` takes one of these and has no other way to reach a PDF.
/// There is deliberately no default: the safe implementation lives in a macOS-only
/// package this one must not depend on, so a default here could only ever be the
/// unsafe one, and a default that is the unsafe one is how S17-02 happened.
public protocol RevisionDocumentSourcing: Sendable {

    /// Where this source parses. Asserted by the application at construction time
    /// and by the compare suites.
    var isolation: RevisionParsingIsolation { get }

    /// The page box of one revision page, in page space.
    func pageBox(of reference: RevisionPageReference) async throws -> CGRect

    /// One revision page, rasterised to 8-bit gray with the frame that locates it.
    func render(
        _ reference: RevisionPageReference,
        scale: Double,
        maximumPixels: Int
    ) async throws -> RenderedRevisionPage

    /// One revision page's vector primitives.
    func extractGeometry(_ reference: RevisionPageReference) async throws -> VectorPageExtraction
}

/// The in-process source: PDFKit for the raster, `CGPDFScanner` for the geometry,
/// both in the calling process.
///
/// This is the code that ran before S17-02, unchanged and deliberately kept, because
/// `swift test` cannot launch an XPC service and the comparison maths has to be
/// exercised against real rendered pages. Its name is the documentation: anything
/// that constructs it is choosing to parse untrusted bytes here, and
/// ``isolation`` reports `.inProcess` so an assertion can catch it in a shipping
/// build.
public struct InProcessRevisionDocumentSource: RevisionDocumentSourcing {
    private let provider: any PDFDocumentProviding
    private let extractor: VectorExtractor

    public init(provider: any PDFDocumentProviding, extractor: VectorExtractor = VectorExtractor()) {
        self.provider = provider
        self.extractor = extractor
    }

    public var isolation: RevisionParsingIsolation { .inProcess }

    public func pageBox(of reference: RevisionPageReference) async throws -> CGRect {
        try await descriptorBox(of: reference)
    }

    public func render(
        _ reference: RevisionPageReference,
        scale: Double,
        maximumPixels: Int
    ) async throws -> RenderedRevisionPage {
        let boxRect = try await descriptorBox(of: reference)
        let rendered: RenderedPageImage
        do {
            rendered = try await provider.renderPageRegion(
                PageRenderRequest(
                    document: reference.document,
                    pageIndex: reference.pageIndex,
                    box: reference.box,
                    region: nil,
                    scale: CGFloat(scale),
                    opaqueBackground: true
                )
            )
        } catch let error as PDFBridgeError {
            throw CompareFault.render(error)
        }
        return RenderedRevisionPage(
            image: try GrayImage.from(rendered.image, maximumPixels: maximumPixels),
            frame: RasterFrame(rendered: rendered, boxRect: boxRect),
            label: reference.label
        )
    }

    public func extractGeometry(_ reference: RevisionPageReference) async throws -> VectorPageExtraction {
        guard let url = reference.fileURL else {
            throw CompareFault.vectorSourceUnavailable(label: reference.label)
        }
        do {
            return try await extractor.extract(documentAt: url, pageIndex: reference.pageIndex)
        } catch VectorExtractionError.cancelled {
            // A cancel the user asked for is not an extraction failure (BH-477).
            throw CompareFault.cancelled
        } catch is CancellationError {
            throw CompareFault.cancelled
        } catch {
            throw CompareFault.vectorExtraction(
                label: reference.label, reason: String(describing: error))
        }
    }

    private func descriptorBox(of reference: RevisionPageReference) async throws -> CGRect {
        do {
            let descriptors = try await provider.pageDescriptors(
                of: reference.document,
                range: reference.pageIndex..<(reference.pageIndex + 1)
            )
            // The range was already validated against the real page count, so an empty
            // answer means the page object itself could not be read. It used to be reported
            // as "out of range (0 pages)" for a 40-page document (BH-478).
            guard let descriptor = descriptors.first else {
                throw CompareFault.render(
                    .renderFailed(reason: "page \(reference.pageIndex) could not be read; the page object is damaged"))
            }
            return descriptor.boxes[reference.box]
        } catch let error as PDFBridgeError {
            throw CompareFault.render(error)
        }
    }
}
