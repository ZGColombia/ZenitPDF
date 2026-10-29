import Foundation
import ZPDFDXF
import ZPDFServiceWire

/// NL-PLAT-05, round 2: a DXF is parsed and drawn here, in the geometry service, not in the app.
///
/// The reader is `ZPDFDXF`'s bounded pure-Swift parser (ASCII only, size, entity and nesting caps).
/// The service reads the inherited descriptor itself — never more than the reader's byte cap plus
/// one, so an oversized file is refused without being read whole — and answers with the sheet.
extension GeometryServiceCore {

    /// XPC path: the `.dxf` is an inherited read-only descriptor.
    public func convertDXF(request: DXFWireRequest, fileDescriptor: Int32) async -> WireReplyOutcome {
        await run(requestID: request.requestID, debugDelayMilliseconds: request.debugDelayMilliseconds,
                  failure: Self.dxfFailure(from:)) {
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
            try handle.seek(toOffset: 0)
            let data = try Self.readBounded(handle, limit: DXFLimits.standard.maximumBytes)
            return try Self.convertDXF(data: data, title: request.title)
        }
    }

    /// Stdio path (tests) and the in-process fallback.
    public func convertDXF(request: DXFWireRequest, documentAt url: URL) async -> WireReplyOutcome {
        await run(requestID: request.requestID, debugDelayMilliseconds: request.debugDelayMilliseconds,
                  failure: Self.dxfFailure(from:)) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try Self.readBounded(handle, limit: DXFLimits.standard.maximumBytes)
            return try Self.convertDXF(data: data, title: request.title)
        }
    }

    /// Parses, draws and encodes one drawing. Pure over its input.
    public static func convertDXF(data: Data, title: String) throws -> Data {
        try Task.checkCancellation()
        let drawing = try DXFReader.read(data)
        try Task.checkCancellation()
        // The writer checks cancellation as it draws (S-119), so a cancel or the deadline stops
        // a long sheet here rather than through the wedge watchdog.
        let sheet = try DXFSheetWriter.write(drawing, title: title)
        return try DXFWireCodec.encode(DXFWireSheet(
            pdf: sheet.pdf, scaleDenominator: sheet.scaleDenominator, scaleIsFromFile: sheet.scaleIsFromFile,
            unitRawValue: sheet.unit.rawValue, pageWidthPoints: sheet.pageSizePoints.width,
            pageHeightPoints: sheet.pageSizePoints.height, layers: sheet.layers, skipped: sheet.skipped))
    }

    /// At most `limit + 1` bytes: one past the cap is enough for the reader to refuse the file as
    /// too large, and a hostile descriptor cannot make the service read without end.
    static func readBounded(_ handle: FileHandle, limit: Int) throws -> Data {
        var data = Data()
        while data.count <= limit {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(4 * 1024 * 1024, limit + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    /// A refusal the person can act on keeps its words: the reader's reasons are written for them.
    static func dxfFailure(from error: Error) -> WireFailure {
        if error is CancellationError { return cancellationFailure }
        if let refusal = error as? DXFError {
            return WireFailure(domain: "ZPDFDXF", code: 100, message: refusal.description)
        }
        return WireFailure(domain: "ZPDFGeometryService", code: 2, message: String(describing: error))
    }
}
