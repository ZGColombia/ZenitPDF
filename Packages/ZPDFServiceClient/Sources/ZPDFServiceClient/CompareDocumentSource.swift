import CoreGraphics
import Foundation
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFServiceWire
import ZPDFVectorExtraction

/// Revision Compare's document source, out of process (finding S17-02).
///
/// Compare opens the most untrusted file the product handles — the revision a
/// subcontractor emailed this morning — and until this type existed it was the one
/// document path that parsed it inside the application: PDFKit for the raster,
/// `CGPDFScanner` for the geometry, both with the application's entitlements. Every
/// one of those three operations now crosses to `GeometryService.xpc`, whose
/// entitlement set is a single `app-sandbox` key and whose death the client survives
/// and retries once.
///
/// The diffing is *not* here and must not move here: the raster diff, the alignment
/// solve, the vector matcher and the overlay compositor operate on buffers we
/// produced, not on attacker bytes, and running them in the service would only widen
/// what a service compromise reaches.
///
/// The compared page must have a `fileURL`. That is not a new requirement invented
/// here — the vector pass has always needed one — but it is now a requirement of the
/// raster pass too, because a descriptor is what crosses the boundary and a PDFKit
/// `DocumentHandle` cannot. A reference without one is refused with
/// ``CompareFault/vectorSourceUnavailable(label:)`` rather than quietly falling back
/// to in-process parsing.
public struct ServiceBackedRevisionDocumentSource: RevisionDocumentSourcing {

    private let client: ZPDFGeometryServiceClient
    public let isolation: RevisionParsingIsolation

    /// - Parameter isolation: what this source *claims*, asserted by callers. Pass
    ///   `.inProcess` only for a client built on `.inProcess`; anything else is a
    ///   lie the application would then repeat.
    public init(client: ZPDFGeometryServiceClient, isolation: RevisionParsingIsolation) {
        self.client = client
        self.isolation = isolation
    }

    /// The application's constructor. Always the embedded XPC service: when it is
    /// missing the request fails with a typed
    /// ``ZPDFServiceError/serviceUnavailable(service:detail:)`` instead of silently
    /// parsing the revision here.
    public static func automatic() -> ServiceBackedRevisionDocumentSource {
        ServiceBackedRevisionDocumentSource(
            client: ZPDFGeometryServiceClient(backend: .xpcService),
            isolation: .outOfProcess)
    }

    /// `swift test`'s out-of-process source: a real separate process, spawned as a
    /// stdio worker because an `.xpc` bundle cannot launch outside a host app.
    public static func subprocess(executableURL: URL) -> ServiceBackedRevisionDocumentSource {
        ServiceBackedRevisionDocumentSource(
            client: ZPDFGeometryServiceClient(backend: .subprocess(executableURL: executableURL)),
            isolation: .outOfProcess)
    }

    public func shutdown() async {
        await client.shutdown()
    }

    // MARK: - RevisionDocumentSourcing

    public func pageBox(of reference: RevisionPageReference) async throws -> CGRect {
        let url = try Self.url(for: reference)
        do {
            let reply = try await client.pageBox(
                documentAt: url,
                pageIndex: reference.pageIndex,
                box: Self.wireBox(reference.box))
            return CGRect(
                x: reply.boxX, y: reply.boxY, width: reply.boxWidth, height: reply.boxHeight)
        } catch {
            throw Self.fault(for: error, label: reference.label)
        }
    }

    public func render(
        _ reference: RevisionPageReference,
        scale: Double,
        maximumPixels: Int
    ) async throws -> RenderedRevisionPage {
        let url = try Self.url(for: reference)
        let page: RasterWirePage
        do {
            page = try await client.rasterizePage(
                documentAt: url,
                pageIndex: reference.pageIndex,
                box: Self.wireBox(reference.box),
                scale: scale,
                maximumPixels: maximumPixels)
        } catch {
            throw Self.fault(for: error, label: reference.label)
        }
        // Re-checked on this side of the boundary. The service is the trusted end of
        // an untrusted document, not a trusted source of geometry: a compromised or
        // simply buggy service must not be able to hand the diff engine a buffer
        // whose declared size and real size disagree. `GrayImage.init` is the check.
        let frame = page.frame
        guard frame.pixelWidth * frame.pixelHeight <= maximumPixels else {
            throw CompareFault.pixelBudgetExceeded(
                requestedPixels: frame.pixelWidth * frame.pixelHeight, limit: maximumPixels)
        }
        return RenderedRevisionPage(
            image: try GrayImage(
                width: frame.pixelWidth, height: frame.pixelHeight, pixels: page.pixels),
            frame: RasterFrame(
                boxRect: CGRect(
                    x: frame.boxX, y: frame.boxY, width: frame.boxWidth, height: frame.boxHeight),
                renderedRegion: CGRect(
                    x: frame.regionX, y: frame.regionY,
                    width: frame.regionWidth, height: frame.regionHeight),
                rotation: frame.rotation,
                scale: frame.scale,
                pixelWidth: frame.pixelWidth,
                pixelHeight: frame.pixelHeight),
            label: reference.label)
    }

    public func extractGeometry(_ reference: RevisionPageReference) async throws -> VectorPageExtraction {
        let url = try Self.url(for: reference)
        do {
            return try await client.extractPageGeometry(
                documentAt: url, pageIndex: reference.pageIndex)
        } catch {
            throw Self.fault(for: error, label: reference.label)
        }
    }

    // MARK: - Support

    /// What a boundary error becomes on the compare side.
    ///
    /// A cancellation stays a cancellation: it is rethrown as `CancellationError`,
    /// which is what the compare presenter's cancel path catches. It used to be
    /// wrapped like every other error as `CompareFault.vectorExtraction(label:,
    /// reason: "cancelled")`, so a user who cancelled a Revision Compare was shown
    /// a failed comparison blaming the document (BH-213).
    static func fault(for error: any Error, label: String) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let service = error as? ZPDFServiceError, service == .cancelled { return CancellationError() }
        return CompareFault.vectorExtraction(label: label, reason: String(describing: error))
    }

    private static func url(for reference: RevisionPageReference) throws -> URL {
        guard let url = reference.fileURL else {
            throw CompareFault.vectorSourceUnavailable(label: reference.label)
        }
        return url
    }

    static func wireBox(_ box: PDFPageBox) -> RasterWireBox {
        switch box {
        case .media: return .media
        case .crop: return .crop
        case .bleed: return .bleed
        case .trim: return .trim
        case .art: return .art
        }
    }
}
