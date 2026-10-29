import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// BH-167 follow-up: the colours cost no memory per primitive and keep 8-bit precision.
///
/// Old layout: two `Optional<VectorColor>` of four `Double`s (33 bytes each) grew the stride of
/// `VectorPrimitive` from 232 to 312 bytes — 3.12 MB instead of 2.32 MB for the 10 000-segment
/// fixture's page. The channels are now packed 8-bit and the two colours live in alignment
/// padding the layout already had.
struct ColorStorageTests {

    @Test("A primitive's stride is 232 bytes, the same as before colours existed")
    func primitiveStrideIsUnchanged() {
        #expect(MemoryLayout<VectorPrimitive>.stride == 232)
        #expect(MemoryLayout<VectorColor>.size == 4)
    }

    @Test("Channels round to the nearest 1/255; 0 and 1 are exact")
    func quantisation() {
        // 0.5 * 255 = 127.5 -> 128 (half away from zero); 128 / 255 = 0.50196..., within 1/510.
        let gray = VectorColor(deviceGray: 0.5)
        #expect(gray.rgba == 0x8080_80FF)
        #expect(gray.red == 128.0 / 255.0)
        #expect(abs(gray.red - 0.5) <= 1.0 / 510.0)
        // CMYK (0.2, 0.4, 0.6, 0.5): r = 0.8 * 0.5 = 0.4 -> 102, g = 0.3 -> 76.5 -> 77, b = 0.2 -> 51.
        let cmyk = VectorColor(deviceCyan: 0.2, magenta: 0.4, yellow: 0.6, black: 0.5)
        #expect(cmyk.rgba >> 8 == 0x66_4D_33)
        #expect(VectorColor.white.isOpaqueWhite && VectorColor.white.red == 1 && VectorColor.black.red == 0)
        // Nearly white paint (254.9 / 255 rounds to 255) is opaque white at 8-bit precision.
        #expect(VectorColor(red: 0.9999, green: 1, blue: 1).isOpaqueWhite)
        #expect(!VectorColor(red: 0.99, green: 1, blue: 1).isOpaqueWhite)
        // withAlpha replaces only the alpha channel: 0.25 * 255 = 63.75 -> 64.
        #expect(VectorColor.white.withAlpha(0.25).rgba == 0xFFFF_FF40)
    }

    @Test("Colours survive the primitive round trip, and absent colours stay absent")
    func presenceBits() throws {
        func primitive(fill: VectorColor?, stroke: VectorColor?) -> VectorPrimitive {
            let line = VectorLine(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1))
            return VectorPrimitive(
                id: 1, parentID: nil, kind: .lineSegment, geometry: .line(line),
                bounds: VectorBounds(minX: 0, minY: 0, maxX: 1, maxY: 1),
                sourceObjectID: 1, subpathIndex: 0, nestingDepth: 0, paint: .stroked,
                strokeWidth: 1, strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil,
                confidence: 1, layerID: nil, fillColor: fill, strokeColor: stroke
            )
        }
        let red = VectorColor(red: 1, green: 0, blue: 0)
        // Black is all-zero channels with alpha 255; presence, not the bits, says "set".
        let both = primitive(fill: .black, stroke: red)
        #expect(both.fillColor == .black && both.strokeColor == red)
        let none = primitive(fill: nil, stroke: nil)
        #expect(none.fillColor == nil && none.strokeColor == nil)
        let transparentBlack = VectorColor(rgba: 0)
        let onlyStroke = primitive(fill: nil, stroke: transparentBlack)
        #expect(onlyStroke.fillColor == nil && onlyStroke.strokeColor == transparentBlack)
        #expect(both != none)

        // JSON keeps the component shape the type always had, and decodes it back.
        let data = try JSONEncoder().encode(both)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"fillColor\"") && json.contains("\"red\""))
        #expect(!json.contains("fillBits") && !json.contains("colorPresence"))
        #expect(try JSONDecoder().decode(VectorPrimitive.self, from: data) == both)
        let noColours = try JSONEncoder().encode(none)
        #expect(!(String(data: noColours, encoding: .utf8) ?? "").contains("fillColor"))
        #expect(try JSONDecoder().decode(VectorPrimitive.self, from: noColours) == none)
        // A colour written as four Doubles decodes to the nearest 8-bit channels.
        let legacy = Data(#"{"red":0.5,"green":0,"blue":1,"alpha":1}"#.utf8)
        #expect(try JSONDecoder().decode(VectorColor.self, from: legacy).rgba == 0x8000_FFFF)
    }
}
