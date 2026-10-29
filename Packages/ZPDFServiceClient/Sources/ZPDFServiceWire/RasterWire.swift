import Foundation

/// One page-rasterisation request, as it crosses the wire (finding S17-02).
///
/// Revision Compare needs three things out of a document it did not write: the page
/// box, the page raster and the page's vector geometry. The last already crossed this
/// boundary; this request is the first two. The raster reply includes the page box
/// geometry alongside the pixels. The page box can also be fetched separately
/// without rasterising the page.
public struct RasterWireRequest: Sendable, Codable, Hashable {
    public var requestID: UUID
    public var pageIndex: Int
    public var box: RasterWireBox
    /// Pixels per PDF point.
    public var scale: Double
    /// Refused before anything is allocated, on the service side and again on the
    /// client side when the reply is decoded.
    public var maximumPixels: Int
    /// Original file name, for error messages only — the service is never told the
    /// path it came from.
    public var fileName: String
    /// Test hook, as in ``GeometryWireRequest/debugDelayMilliseconds``.
    public var debugDelayMilliseconds: Int

    public init(
        requestID: UUID = UUID(),
        pageIndex: Int,
        box: RasterWireBox = .crop,
        scale: Double,
        maximumPixels: Int = 64_000_000,
        fileName: String = "document.pdf",
        debugDelayMilliseconds: Int = 0
    ) {
        self.requestID = requestID
        self.pageIndex = pageIndex
        self.box = box
        self.scale = scale
        self.maximumPixels = maximumPixels
        self.fileName = fileName
        self.debugDelayMilliseconds = debugDelayMilliseconds
    }
}

/// The Codable projection of `PDFPageBox`. Declared here so `ZPDFServiceWire` keeps
/// its zero dependencies; the two enums are mapped explicitly at both ends, which is
/// what makes a new case a compile error rather than a silent default.
public enum RasterWireBox: String, Sendable, Codable, Hashable, CaseIterable {
    case media
    case crop
    case bleed
    case trim
    case art
}

/// A rendered page's geometry, without the pixels. Plain `Double`s: the wire target
/// links no CoreGraphics.
public struct RasterWireFrame: Sendable, Codable, Hashable {
    public var boxX: Double
    public var boxY: Double
    public var boxWidth: Double
    public var boxHeight: Double
    public var regionX: Double
    public var regionY: Double
    public var regionWidth: Double
    public var regionHeight: Double
    public var rotation: Int
    public var scale: Double
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        boxX: Double, boxY: Double, boxWidth: Double, boxHeight: Double,
        regionX: Double, regionY: Double, regionWidth: Double, regionHeight: Double,
        rotation: Int, scale: Double, pixelWidth: Int, pixelHeight: Int
    ) {
        self.boxX = boxX
        self.boxY = boxY
        self.boxWidth = boxWidth
        self.boxHeight = boxHeight
        self.regionX = regionX
        self.regionY = regionY
        self.regionWidth = regionWidth
        self.regionHeight = regionHeight
        self.rotation = rotation
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// The cheap half of a raster request: one page's box and rotation, with no pixels.
///
/// Its own reply type rather than a raster with the pixel count set to zero, because
/// "a raster of no pixels" is exactly the sort of value a decoder ends up special-casing
/// and then mis-handling. Validated on arrival like everything else that crosses.
public struct PageBoxWireReply: Sendable, Codable, Hashable {
    public var boxX: Double
    public var boxY: Double
    public var boxWidth: Double
    public var boxHeight: Double
    public var rotation: Int

    public init(boxX: Double, boxY: Double, boxWidth: Double, boxHeight: Double, rotation: Int) {
        self.boxX = boxX
        self.boxY = boxY
        self.boxWidth = boxWidth
        self.boxHeight = boxHeight
        self.rotation = rotation
    }

    /// Throws ``RasterWireCodecError/implausibleGeometry(_:)`` for anything a
    /// coordinate calculation could not survive.
    public func validated() throws -> PageBoxWireReply {
        for (name, value) in [
            ("boxX", boxX), ("boxY", boxY), ("boxWidth", boxWidth), ("boxHeight", boxHeight)
        ] where !value.isFinite {
            throw RasterWireCodecError.implausibleGeometry("\(name) is not finite")
        }
        guard boxWidth > 0, boxHeight > 0 else {
            throw RasterWireCodecError.implausibleGeometry("box is \(boxWidth)x\(boxHeight)")
        }
        guard [0, 90, 180, 270].contains(rotation) else {
            throw RasterWireCodecError.implausibleGeometry("rotation \(rotation)")
        }
        return self
    }
}

/// A decoded raster reply: geometry plus `pixelWidth * pixelHeight` gray bytes,
/// row-major, row 0 at the top, 255 = paper.
public struct RasterWirePage: Sendable, Hashable {
    public let frame: RasterWireFrame
    public let pixels: [UInt8]

    public init(frame: RasterWireFrame, pixels: [UInt8]) {
        self.frame = frame
        self.pixels = pixels
    }
}

/// Why a raster payload was refused.
public enum RasterWireCodecError: Error, Sendable, Hashable, CustomStringConvertible {
    case truncated(expected: Int, available: Int)
    case badMagic
    case unsupportedVersion(UInt32)
    case metadataTooLarge(UInt32)
    case metadataUnreadable(String)
    case implausibleGeometry(String)
    case pixelCountMismatch(declared: UInt64, expected: Int)
    case checksumMismatch
    /// The raster is plausible but larger than the request asked for (BH-656).
    case exceedsRequestedBudget(pixels: Int, budget: Int)

    public var description: String {
        switch self {
        case let .truncated(expected, available):
            return "raster payload wants \(expected) bytes, \(available) remain"
        case .badMagic: return "raster payload does not start with ZPRA"
        case let .unsupportedVersion(version): return "raster payload version \(version) is not supported"
        case let .metadataTooLarge(length): return "raster metadata of \(length) bytes exceeds the cap"
        case let .metadataUnreadable(reason): return "raster metadata would not decode: \(reason)"
        case let .implausibleGeometry(reason): return "raster geometry is not usable: \(reason)"
        case let .pixelCountMismatch(declared, expected):
            return "raster declares \(declared) pixels, its geometry needs \(expected)"
        case .checksumMismatch: return "raster payload checksum does not match"
        case let .exceedsRequestedBudget(pixels, budget):
            return "raster of \(pixels) pixels exceeds the requested budget of \(budget)"
        }
    }
}

/// The raster wire format: magic, version, length-prefixed JSON geometry, the gray
/// bytes, and an FNV-1a checksum over everything before it.
///
/// Written to the rule finding S17-01 established the hard way: **every** scalar is
/// bounded before it is used, not just the collection counts. A length field here can
/// only ever produce an allocation the remaining bytes can actually satisfy, and the
/// pixel count must equal the geometry's own `width * height` rather than being
/// believed. A corrupted or hostile reply throws; nothing in this file traps.
public enum RasterWireCodec {

    public static let magic: [UInt8] = Array("ZPRA".utf8)
    public static let version: UInt32 = 1
    /// The geometry JSON is a dozen numbers. 64 KiB is four orders of magnitude of
    /// slack and still refuses a length field designed to make us allocate.
    public static let maximumMetadataBytes: UInt32 = 64 * 1024
    /// An absolute ceiling independent of any caller's budget: 256 Mpx of gray is
    /// 256 MB, which is already past anything the product renders.
    public static let maximumPixels = 256_000_000
    /// A page bigger than this in either direction is not a drawing.
    public static let maximumPixelExtent = 200_000

    public static func encode(frame: RasterWireFrame, pixels: [UInt8]) throws -> Data {
        let metadata = try JSONEncoder().encode(frame)
        var out = Data()
        out.append(contentsOf: magic)
        out.append(bigEndian: version)
        out.append(bigEndian: UInt32(metadata.count))
        out.append(metadata)
        out.append(bigEndian: UInt64(pixels.count))
        out.append(contentsOf: pixels)
        out.append(bigEndian: fnv1a(out))
        return out
    }

    /// Decodes a reply against the absolute ceiling only. Prefer
    /// ``decode(_:maximumPixels:)`` whenever the request's budget is known.
    public static func decode(_ data: Data) throws -> RasterWirePage {
        try decode(data, maximumPixels: maximumPixels)
    }

    /// Decodes a reply and refuses it when its raster exceeds `budget` pixels —
    /// the request's own ``RasterWireRequest/maximumPixels`` — before the pixels
    /// are copied out.
    ///
    /// BH-656: the request field promised a second refusal "on the client side
    /// when the reply is decoded", but decode knew only the absolute 256 Mpx
    /// ceiling, so a buggy or taken-over service could answer a 64 Mpx request
    /// with a 256 Mpx raster and every caller but one got it back unchecked. The
    /// decode also used to copy the whole payload three times (into an array, a
    /// checksum slice and the pixel array) before anything looked at the size; it
    /// now reads the payload in place and copies only the accepted pixels, once.
    public static func decode(_ data: Data, maximumPixels budget: Int) throws -> RasterWirePage {
        let base = data.startIndex
        let count = data.count
        // Header (4 + 4 + 4) + pixel count (8) + checksum (8).
        guard count >= 28 else {
            throw RasterWireCodecError.truncated(expected: 28, available: count)
        }
        guard Array(data[base..<(base + 4)]) == magic else { throw RasterWireCodecError.badMagic }

        let payloadEnd = count - 8
        let stated = readUInt64(data, at: payloadEnd)
        guard stated == fnv1a(data[base..<(base + payloadEnd)]) else {
            throw RasterWireCodecError.checksumMismatch
        }

        let fileVersion = readUInt32(data, at: 4)
        guard fileVersion == version else {
            throw RasterWireCodecError.unsupportedVersion(fileVersion)
        }

        let metadataLength = readUInt32(data, at: 8)
        guard metadataLength <= maximumMetadataBytes else {
            throw RasterWireCodecError.metadataTooLarge(metadataLength)
        }
        let metadataStart = 12
        let metadataEnd = metadataStart + Int(metadataLength)
        guard metadataEnd + 8 <= payloadEnd else {
            throw RasterWireCodecError.truncated(
                expected: metadataEnd + 8, available: payloadEnd)
        }
        let frame: RasterWireFrame
        do {
            frame = try JSONDecoder().decode(
                RasterWireFrame.self, from: Data(data[(base + metadataStart)..<(base + metadataEnd)]))
        } catch {
            throw RasterWireCodecError.metadataUnreadable(String(describing: error))
        }
        try validate(frame)

        let expected = frame.pixelWidth * frame.pixelHeight
        guard expected <= budget else {
            throw RasterWireCodecError.exceedsRequestedBudget(pixels: expected, budget: budget)
        }
        let declared = readUInt64(data, at: metadataEnd)
        guard declared == UInt64(expected) else {
            throw RasterWireCodecError.pixelCountMismatch(declared: declared, expected: expected)
        }
        let pixelStart = metadataEnd + 8
        guard pixelStart + expected == payloadEnd else {
            throw RasterWireCodecError.truncated(
                expected: pixelStart + expected, available: payloadEnd)
        }
        return RasterWirePage(
            frame: frame, pixels: [UInt8](data[(base + pixelStart)..<(base + payloadEnd)]))
    }

    /// Everything a reply must satisfy before a single pixel is trusted. Called on
    /// decode, so a service that has been taken over cannot hand the application a
    /// geometry that overflows an index calculation later.
    public static func validate(_ frame: RasterWireFrame) throws {
        for (name, value) in [
            ("boxX", frame.boxX), ("boxY", frame.boxY),
            ("boxWidth", frame.boxWidth), ("boxHeight", frame.boxHeight),
            ("regionX", frame.regionX), ("regionY", frame.regionY),
            ("regionWidth", frame.regionWidth), ("regionHeight", frame.regionHeight),
            ("scale", frame.scale)
        ] where !value.isFinite {
            throw RasterWireCodecError.implausibleGeometry("\(name) is not finite")
        }
        guard frame.boxWidth > 0, frame.boxHeight > 0 else {
            throw RasterWireCodecError.implausibleGeometry(
                "box is \(frame.boxWidth)x\(frame.boxHeight)")
        }
        guard frame.scale > 0, frame.scale <= 1000 else {
            throw RasterWireCodecError.implausibleGeometry("scale \(frame.scale)")
        }
        guard [0, 90, 180, 270].contains(frame.rotation) else {
            throw RasterWireCodecError.implausibleGeometry("rotation \(frame.rotation)")
        }
        guard frame.pixelWidth > 0, frame.pixelWidth <= maximumPixelExtent,
              frame.pixelHeight > 0, frame.pixelHeight <= maximumPixelExtent else {
            throw RasterWireCodecError.implausibleGeometry(
                "raster is \(frame.pixelWidth)x\(frame.pixelHeight)")
        }
        let product = frame.pixelWidth.multipliedReportingOverflow(by: frame.pixelHeight)
        guard !product.overflow, product.partialValue <= maximumPixels else {
            throw RasterWireCodecError.implausibleGeometry(
                "raster of \(frame.pixelWidth)x\(frame.pixelHeight) exceeds \(maximumPixels) pixels")
        }
    }

    // MARK: - Primitives

    public static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// `offset` is relative to the start of `data`, which need not be index 0.
    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(data[start + index]) }
        return value
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let start = data.startIndex + offset
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[start + index]) }
        return value
    }
}

extension Data {
    fileprivate mutating func append(bigEndian value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8((value >> UInt32(shift)) & 0xff))
        }
    }

    fileprivate mutating func append(bigEndian value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }
}
