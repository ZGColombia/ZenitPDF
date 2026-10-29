import Foundation

/// A byte sink that tracks how many bytes have been written, because a PDF
/// cross-reference table is a table of byte offsets.
///
/// Two implementations exist so that the 1 000-page fixture can be streamed straight
/// to disk one page at a time instead of being buffered whole.
protocol PDFByteSink: AnyObject {
    /// Bytes written so far — the offset the next byte will occupy.
    var offset: Int { get }
    func write(_ data: Data) throws
}

extension PDFByteSink {
    /// Writes `string` as Latin-1, the encoding PDF syntax outside of strings uses.
    func write(_ string: String, kind: FixtureKind) throws {
        guard let data = string.data(using: .isoLatin1) else {
            throw FixtureError.encodingFailed(
                kind: kind,
                reason: "string is not representable in ISO Latin-1"
            )
        }
        try write(data)
    }
}

/// Accumulates the document in memory. Used by `ZPDFFixtures.data(_:)` and by every
/// fixture small enough that buffering costs nothing.
final class PDFDataSink: PDFByteSink {
    private(set) var data = Data()

    var offset: Int { data.count }

    init(reservingCapacity capacity: Int = 16 * 1024) {
        data.reserveCapacity(capacity)
    }

    func write(_ data: Data) throws {
        self.data.append(data)
    }
}

/// Streams the document to a file handle. Peak memory is one object, not one
/// document, which is how the 1 000-page fixture is generated without holding it all.
final class PDFFileSink: PDFByteSink {
    private let handle: FileHandle
    private let path: String
    private(set) var offset: Int = 0

    init(handle: FileHandle, path: String) {
        self.handle = handle
        self.path = path
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw FixtureError.writeFailed(path: path, reason: "\(error)")
        }
        offset += data.count
    }
}
