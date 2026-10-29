import Foundation
import Testing
import ZPDFServiceWire

/// The raster reply is a new wire format, and finding S17-01 is the reason it is
/// checked this hard: the *reply* is attacker-influenced too. A `CGPDFScanner` or
/// PDFKit bug that gave someone control of the service's reply bytes must not be
/// able to do anything to the application beyond making one comparison fail.
///
/// Every refusal below is a `throw` of a typed case. Nothing here may trap: a trap
/// is not catchable, the crash-recovery machinery never runs, and the "no
/// `fatalError`" rule is violated by the standard library on our behalf.
struct HostileRasterPayloadTests {

    static func referenceFrame(width: Int = 8, height: Int = 4) -> RasterWireFrame {
        RasterWireFrame(
            boxX: 0, boxY: 0, boxWidth: 400, boxHeight: 200,
            regionX: 0, regionY: 0, regionWidth: 400, regionHeight: 200,
            rotation: 0, scale: 2, pixelWidth: width, pixelHeight: height)
    }

    static func referencePayload() throws -> Data {
        try RasterWireCodec.encode(
            frame: referenceFrame(), pixels: [UInt8](repeating: 200, count: 32))
    }

    @Test("A well-formed raster payload round-trips")
    func validPayloadDecodes() throws {
        let decoded = try RasterWireCodec.decode(try Self.referencePayload())
        #expect(decoded.frame == Self.referenceFrame())
        #expect(decoded.pixels.count == 32)
        #expect(decoded.pixels.allSatisfy { $0 == 200 })
    }

    @Test("A single flipped byte anywhere is caught by the checksum", arguments: [0, 5, 13, 40, 47])
    func flippedByteIsRefused(offset: Int) throws {
        var bytes = [UInt8](try Self.referencePayload())
        guard offset < bytes.count else { return }
        bytes[offset] ^= 0xff
        #expect(throws: (any Error).self) { _ = try RasterWireCodec.decode(Data(bytes)) }
    }

    @Test("Truncation at any point is refused, never read past the end", arguments: [0, 1, 12, 20, 27, 30])
    func truncationIsRefused(length: Int) throws {
        let bytes = [UInt8](try Self.referencePayload())
        #expect(throws: (any Error).self) {
            _ = try RasterWireCodec.decode(Data(bytes.prefix(length)))
        }
    }

    @Test("Geometry that no coordinate calculation could survive is refused, not narrowed")
    func implausibleGeometryIsRefused() throws {
        var frames: [RasterWireFrame] = []
        var overflowing = Self.referenceFrame()
        overflowing.pixelWidth = Int.max
        frames.append(overflowing)
        var negative = Self.referenceFrame()
        negative.pixelHeight = -1
        frames.append(negative)
        var enormous = Self.referenceFrame()
        enormous.pixelWidth = RasterWireCodec.maximumPixelExtent + 1
        frames.append(enormous)
        var skewRotation = Self.referenceFrame()
        skewRotation.rotation = 45
        frames.append(skewRotation)
        var nan = Self.referenceFrame()
        nan.boxWidth = .nan
        frames.append(nan)
        var infinite = Self.referenceFrame()
        infinite.scale = .infinity
        frames.append(infinite)
        var zeroBox = Self.referenceFrame()
        zeroBox.boxHeight = 0
        frames.append(zeroBox)

        for frame in frames {
            #expect(throws: RasterWireCodecError.self) { try RasterWireCodec.validate(frame) }
        }
        print("S17-02 raster payload: \(frames.count) implausible geometries refused, 0 traps")
    }

    @Test("A pixel count that disagrees with the geometry is refused")
    func pixelCountMustMatchGeometry() throws {
        // Encode a frame that claims 8x4 with only 16 bytes of pixels. The encoder
        // will happily do it — the *decoder* is the guard, because the decoder is
        // the side that faces a service it does not control.
        let payload = try RasterWireCodec.encode(
            frame: Self.referenceFrame(), pixels: [UInt8](repeating: 0, count: 16))
        #expect(throws: (any Error).self) { _ = try RasterWireCodec.decode(payload) }
    }

    @Test("A payload with the wrong magic or version is refused before anything is decoded")
    func magicAndVersionAreChecked() throws {
        var bytes = [UInt8](try Self.referencePayload())
        bytes[0] = 0x21  // 'Z' -> '!'
        // Re-checksum so the refusal is the magic, not the checksum.
        let body = Array(bytes[0..<(bytes.count - 8)])
        var hashed = body
        let hash = RasterWireCodec.fnv1a(Data(body))
        for shift in stride(from: 56, through: 0, by: -8) {
            hashed.append(UInt8((hash >> UInt64(shift)) & 0xff))
        }
        #expect(throws: RasterWireCodecError.badMagic) {
            _ = try RasterWireCodec.decode(Data(hashed))
        }
    }

    @Test("A metadata length above the cap allocates nothing")
    func metadataLengthIsCapped() throws {
        var bytes = [UInt8](try Self.referencePayload())
        let huge = UInt32(0x00ff_ffff)
        for (index, shift) in stride(from: 24, through: 0, by: -8).enumerated() {
            bytes[8 + index] = UInt8((huge >> UInt32(shift)) & 0xff)
        }
        let body = Array(bytes[0..<(bytes.count - 8)])
        var hashed = body
        let hash = RasterWireCodec.fnv1a(Data(body))
        for shift in stride(from: 56, through: 0, by: -8) {
            hashed.append(UInt8((hash >> UInt64(shift)) & 0xff))
        }
        #expect(throws: RasterWireCodecError.metadataTooLarge(huge)) {
            _ = try RasterWireCodec.decode(Data(hashed))
        }
    }
}
