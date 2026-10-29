import CoreGraphics
import Foundation
import ZPDFCompare
import ZPDFPDFKitBridge
import ZPDFServiceWire

/// Page rasterisation, inside the service (finding S17-02).
///
/// The two things this deliberately does **not** do are the point of it. It does not
/// re-implement rendering: it calls the same `ZPDFPDFKitBridge` provider the
/// application used to call, so a page compared through the service and the same page
/// compared under `swift test` produce identical pixels — the tested code is the
/// shipped code. And it does not reduce to gray by hand: `GrayImage.from(_:)` is
/// `ZPDFCompare`'s own conversion, so the bytes that come back are the bytes the
/// diff engine expects.
///
/// What changes is only *where* PDFKit meets the bytes: in `GeometryService.xpc`,
/// whose entitlement set is a single `app-sandbox` key and whose death the client
/// survives, instead of in the application process with the application's rights.
enum GeometryRasterizer {

    static func rasterize(
        request: RasterWireRequest,
        documentAt url: URL
    ) async throws -> Data {
        guard request.scale.isFinite, request.scale > 0, request.scale <= 100 else {
            throw RasterizeFault("render scale \(request.scale) is not usable")
        }
        guard request.pageIndex >= 0 else {
            throw RasterizeFault("page index \(request.pageIndex) is negative")
        }
        guard request.maximumPixels > 0, request.maximumPixels <= RasterWireCodec.maximumPixels else {
            throw RasterizeFault("pixel budget \(request.maximumPixels) is not usable")
        }

        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(fileAt: url)
        defer { Task { await provider.close(opened.handle) } }

        let box = pageBox(from: request.box)
        let descriptors = try await provider.pageDescriptors(
            of: opened.handle,
            range: request.pageIndex..<(request.pageIndex + 1))
        guard let descriptor = descriptors.first else {
            throw RasterizeFault("page \(request.pageIndex) does not exist")
        }
        let boxRect = descriptor.boxes[box]

        try Task.checkCancellation()
        let rendered = try await provider.renderPageRegion(
            PageRenderRequest(
                document: opened.handle,
                pageIndex: request.pageIndex,
                box: box,
                region: nil,
                scale: CGFloat(request.scale),
                opaqueBackground: true))
        try Task.checkCancellation()

        let gray = try GrayImage.from(rendered.image, maximumPixels: request.maximumPixels)
        let frame = RasterWireFrame(
            boxX: Double(boxRect.origin.x),
            boxY: Double(boxRect.origin.y),
            boxWidth: Double(boxRect.width),
            boxHeight: Double(boxRect.height),
            regionX: Double(rendered.renderedRegion.origin.x),
            regionY: Double(rendered.renderedRegion.origin.y),
            regionWidth: Double(rendered.renderedRegion.width),
            regionHeight: Double(rendered.renderedRegion.height),
            rotation: rendered.rotation,
            scale: Double(rendered.scale),
            pixelWidth: gray.width,
            pixelHeight: gray.height)
        try RasterWireCodec.validate(frame)
        return try RasterWireCodec.encode(frame: frame, pixels: gray.pixels)
    }

    static func pageBox(
        request: RasterWireRequest,
        documentAt url: URL
    ) async throws -> Data {
        guard request.pageIndex >= 0 else {
            throw RasterizeFault("page index \(request.pageIndex) is negative")
        }
        let provider = PDFKitDocumentProvider(thumbnailCacheCapacity: 0)
        let opened = try await provider.open(fileAt: url)
        defer { Task { await provider.close(opened.handle) } }
        let descriptors = try await provider.pageDescriptors(
            of: opened.handle,
            range: request.pageIndex..<(request.pageIndex + 1))
        guard let descriptor = descriptors.first else {
            throw RasterizeFault("page \(request.pageIndex) does not exist")
        }
        let rect = descriptor.boxes[pageBox(from: request.box)]
        let reply = try PageBoxWireReply(
            boxX: Double(rect.origin.x),
            boxY: Double(rect.origin.y),
            boxWidth: Double(rect.width),
            boxHeight: Double(rect.height),
            rotation: descriptor.rotation).validated()
        return try JSONEncoder().encode(reply)
    }

    /// Explicit both ways: a new box case is a compile error here rather than a
    /// silent fall back to `.crop` on one side of the wire.
    static func pageBox(from wire: RasterWireBox) -> PDFPageBox {
        switch wire {
        case .media: return .media
        case .crop: return .crop
        case .bleed: return .bleed
        case .trim: return .trim
        case .art: return .art
        }
    }
}

/// A refusal from the rasteriser that is neither a PDFKit error nor a compare fault.
struct RasterizeFault: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
