import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// NL-AUTO-13: "the same style" — red new doors and grey existing doors of one shape.
struct SymbolStyleGateTests {

    static let red = VectorColor(red: 1, green: 0, blue: 0)
    static let grey = VectorColor(red: 0.5, green: 0.5, blue: 0.5)

    static func line(_ id: UInt64, _ a: CGPoint, _ b: CGPoint, color: VectorColor, width: Double = 0.5, layer: String? = nil) -> VectorPrimitive {
        VectorPrimitive(
            id: id, parentID: nil, kind: .lineSegment,
            geometry: .line(VectorLine(start: a, end: b)),
            bounds: VectorBounds(point: a).union(b),
            sourceObjectID: id, subpathIndex: 0, nestingDepth: 0, paint: .stroked,
            strokeWidth: width, strokeIsDashed: false, clipRelation: .unclipped, clipBounds: nil,
            confidence: 1, layerID: layer, strokeColor: color
        )
    }

    /// An L of a 20-long and a 12-long stroke at (x, y).
    static func ell(_ base: UInt64, _ x: Double, _ y: Double, color: VectorColor, width: Double = 0.5) -> [VectorPrimitive] {
        [line(base, CGPoint(x: x, y: y), CGPoint(x: x + 20, y: y), color: color, width: width),
         line(base + 1, CGPoint(x: x, y: y), CGPoint(x: x, y: y + 12), color: color, width: width)]
    }

    static func page() -> [VectorPrimitive] {
        // Three red, two grey, one red drawn at 1 pt instead of 0.5 pt.
        ell(10, 100, 100, color: red) + ell(20, 200, 100, color: red) + ell(30, 300, 100, color: red)
            + ell(40, 100, 300, color: grey) + ell(50, 200, 300, color: grey)
            + ell(60, 300, 300, color: red, width: 1)
    }

    static func exemplar(_ primitives: [VectorPrimitive]) throws -> SymbolExemplar {
        try SymbolExemplar(primitives: primitives, region: VectorBounds(minX: 95, minY: 95, maxX: 125, maxY: 117))
    }

    @Test("Shape alone finds all six; the same colour finds the four red ones")
    func colourGate() throws {
        let primitives = Self.page()
        let exemplar = try Self.exemplar(primitives)
        #expect(exemplar.style.strokeColor == Self.red)
        let shape = try SymbolMatcher().matches(exemplar: exemplar, in: primitives)
        #expect(shape.confirmed.count == 6)
        var options = SymbolMatchOptions.standard
        options.styleGate = [.strokeColor]
        let red = try SymbolMatcher().matches(exemplar: exemplar, in: primitives, options: options)
        #expect(red.confirmed.count == 4)
        #expect(red.confirmed.allSatisfy { $0.position.y < 200 || $0.position.x > 290 })
    }

    @Test("Colour and width together leave the three red half-point doors")
    func colourAndWidth() throws {
        let primitives = Self.page()
        let exemplar = try Self.exemplar(primitives)
        #expect(exemplar.style.strokeWidth == 0.5)
        var options = SymbolMatchOptions.standard
        options.styleGate = [.strokeColor, .strokeWidth]
        #expect(try SymbolMatcher().matches(exemplar: exemplar, in: primitives, options: options).confirmed.count == 3)
    }

    @Test("A width within 10 % passes; the layer gate reads the majority layer")
    func widthToleranceAndLayer() {
        let style = SymbolStyle(members: [
            Self.line(1, .zero, CGPoint(x: 1, y: 0), color: Self.red, width: 1.0, layer: "A"),
            Self.line(2, .zero, CGPoint(x: 0, y: 1), color: Self.red, width: 1.0, layer: "A"),
            Self.line(3, .zero, CGPoint(x: 1, y: 1), color: Self.grey, width: 3.0, layer: "B")
        ])
        #expect(style.strokeColor == Self.red && style.layerID == "A" && style.strokeWidth == 1.0)
        #expect(style.admits(Self.line(9, .zero, CGPoint(x: 1, y: 0), color: Self.red, width: 1.09), gate: [.strokeWidth]))
        #expect(!style.admits(Self.line(9, .zero, CGPoint(x: 1, y: 0), color: Self.red, width: 1.11), gate: [.strokeWidth]))
        #expect(!style.admits(Self.line(9, .zero, CGPoint(x: 1, y: 0), color: Self.red, layer: "B"), gate: [.layer]))
        #expect(style.admits(Self.line(9, .zero, CGPoint(x: 1, y: 0), color: Self.grey, layer: "B"), gate: []))
    }
}
