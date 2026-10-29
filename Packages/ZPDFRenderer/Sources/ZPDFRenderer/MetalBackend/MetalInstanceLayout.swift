import Foundation
import ZPDFContracts

/// The byte layouts shared between Swift and the Metal shading language source.
///
/// Every struct below is laid out by hand to Metal's alignment rules — a `float4` member forces
/// 16-byte alignment on the struct — and every one is asserted against `MemoryLayout.stride` in
/// `MetalInstanceLayoutTests`. A silent layout drift between the two languages is the single
/// most expensive bug class in a hand-written renderer, so it is a compile-and-test-time fact
/// here rather than a comment.
public enum MetalInstanceLayout {
    public static let segmentStride = MemoryLayout<SegmentInstance>.stride
    public static let triangleVertexStride = MemoryLayout<TriangleVertex>.stride
    public static let symbolStride = MemoryLayout<SymbolInstance>.stride
    public static let glyphStride = MemoryLayout<GlyphInstance>.stride
    public static let uniformStride = MemoryLayout<FrameUniforms>.stride

    /// Set on an instance whose slot has been freed; the vertex stage sends it off screen instead
    /// of leaving stale geometry visible. Compaction reclaims it later.
    public static let deadFlag: UInt32 = 1 << 8
    /// A glyph instance's flags carry ``CompiledGlyph/rotationSteps`` from this bit up (bits
    /// 16…31): the quad's turn about its top-left corner in 1/65536ths of a turn (T-065).
    public static let glyphRotationShift: UInt32 = 16
}

/// Packs a colour into one `uint` as RGBA8, straight (non-premultiplied) alpha.
public func packColor(_ color: RGBAColor) -> UInt32 {
    func channel(_ value: Double) -> UInt32 {
        let clamped = Swift.min(1.0, Swift.max(0.0, value.isFinite ? value : 0))
        return UInt32((clamped * 255).rounded())
    }
    return channel(color.red)
        | (channel(color.green) << 8)
        | (channel(color.blue) << 16)
        | (channel(color.alpha) << 24)
}

/// One stroked segment on the GPU. 48 bytes, 16-byte aligned.
public struct SegmentInstance: Sendable, Equatable {
    /// Up to four dash runs in page points; unused slots are zero.
    public var dashRuns: (Float, Float, Float, Float)
    /// Start and end in page space, relative to the scene origin.
    public var p0x: Float
    public var p0y: Float
    public var p1x: Float
    public var p1y: Float
    /// Nominal width in page points.
    public var width: Float
    /// Arc length offset into the dash pattern, in page points.
    public var dashOffset: Float
    public var color: UInt32
    /// Bits 0-1 start cap, bits 2-3 end cap, bits 4-7 dash run count, bit 8 dead.
    public var flags: UInt32

    public init(
        dashRuns: (Float, Float, Float, Float) = (0, 0, 0, 0),
        p0x: Float = 0, p0y: Float = 0, p1x: Float = 0, p1y: Float = 0,
        width: Float = 0, dashOffset: Float = 0,
        color: UInt32 = 0, flags: UInt32 = 0
    ) {
        self.dashRuns = dashRuns
        self.p0x = p0x; self.p0y = p0y; self.p1x = p1x; self.p1y = p1y
        self.width = width; self.dashOffset = dashOffset
        self.color = color; self.flags = flags
    }

    public static func == (lhs: SegmentInstance, rhs: SegmentInstance) -> Bool {
        lhs.dashRuns == rhs.dashRuns && lhs.p0x == rhs.p0x && lhs.p0y == rhs.p0y
            && lhs.p1x == rhs.p1x && lhs.p1y == rhs.p1y && lhs.width == rhs.width
            && lhs.dashOffset == rhs.dashOffset && lhs.color == rhs.color && lhs.flags == rhs.flags
    }

    public static let dead = SegmentInstance(flags: MetalInstanceLayout.deadFlag)
}

/// One filled-triangle vertex. 16 bytes.
public struct TriangleVertex: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var color: UInt32
    public var flags: UInt32

    public init(x: Float = 0, y: Float = 0, color: UInt32 = 0, flags: UInt32 = 0) {
        self.x = x; self.y = y; self.color = color; self.flags = flags
    }

    public static let dead = TriangleVertex(flags: MetalInstanceLayout.deadFlag)
}

/// One count-symbol instance. 48 bytes, 16-byte aligned.
public struct SymbolInstance: Sendable, Equatable {
    /// `u0, v0, u1, v1` in the symbol atlas.
    public var uv: (Float, Float, Float, Float)
    public var centerX: Float
    public var centerY: Float
    /// Edge length in page points; zero means use ``sizeViewPoints``.
    public var sizePagePoints: Float
    public var sizeViewPoints: Float
    public var color: UInt32
    public var flags: UInt32
    /// Rotation about the centre in radians, counter-clockwise on the page. The shader turns it
    /// into pixel space with the frame matrix's orientation (BH-634). Occupies what was padding,
    /// so the stride is unchanged.
    public var rotationRadians: Float
    private var padding: UInt32 = 0

    public init(
        uv: (Float, Float, Float, Float) = (0, 0, 0, 0),
        centerX: Float = 0, centerY: Float = 0,
        sizePagePoints: Float = 0, sizeViewPoints: Float = 0,
        color: UInt32 = 0, flags: UInt32 = 0,
        rotationRadians: Float = 0
    ) {
        self.uv = uv
        self.centerX = centerX; self.centerY = centerY
        self.sizePagePoints = sizePagePoints; self.sizeViewPoints = sizeViewPoints
        self.color = color; self.flags = flags
        self.rotationRadians = rotationRadians
    }

    public static func == (lhs: SymbolInstance, rhs: SymbolInstance) -> Bool {
        lhs.uv == rhs.uv && lhs.centerX == rhs.centerX && lhs.centerY == rhs.centerY
            && lhs.sizePagePoints == rhs.sizePagePoints && lhs.sizeViewPoints == rhs.sizeViewPoints
            && lhs.color == rhs.color && lhs.flags == rhs.flags
            && lhs.rotationRadians == rhs.rotationRadians
    }

    public static let dead = SymbolInstance(flags: MetalInstanceLayout.deadFlag)
}

/// One glyph quad. 48 bytes, 16-byte aligned.
public struct GlyphInstance: Sendable, Equatable {
    public var uv: (Float, Float, Float, Float)
    public var anchorX: Float
    public var anchorY: Float
    /// Offset from the anchor's pixel position to the quad's top-left corner, in device pixels.
    public var offsetX: Float
    public var offsetY: Float
    public var widthPixels: Float
    public var heightPixels: Float
    public var color: UInt32
    public var flags: UInt32

    public init(
        uv: (Float, Float, Float, Float) = (0, 0, 0, 0),
        anchorX: Float = 0, anchorY: Float = 0,
        offsetX: Float = 0, offsetY: Float = 0,
        widthPixels: Float = 0, heightPixels: Float = 0,
        color: UInt32 = 0, flags: UInt32 = 0
    ) {
        self.uv = uv
        self.anchorX = anchorX; self.anchorY = anchorY
        self.offsetX = offsetX; self.offsetY = offsetY
        self.widthPixels = widthPixels; self.heightPixels = heightPixels
        self.color = color; self.flags = flags
    }

    public static func == (lhs: GlyphInstance, rhs: GlyphInstance) -> Bool {
        lhs.uv == rhs.uv && lhs.anchorX == rhs.anchorX && lhs.anchorY == rhs.anchorY
            && lhs.offsetX == rhs.offsetX && lhs.offsetY == rhs.offsetY
            && lhs.widthPixels == rhs.widthPixels && lhs.heightPixels == rhs.heightPixels
            && lhs.color == rhs.color && lhs.flags == rhs.flags
    }

    public static let dead = GlyphInstance(flags: MetalInstanceLayout.deadFlag)
}

/// Per-frame constants. The only thing that changes on a pan or a zoom.
public struct FrameUniforms: Sendable, Equatable {
    /// Linear part of page-relative to pixel: `a, b, c, d`.
    public var matrix: (Float, Float, Float, Float)
    /// Translation `tx, ty`, then the drawable size in pixels.
    public var translationAndViewport: (Float, Float, Float, Float)
    /// `pixelsPerPagePoint, minimumStrokePixels, maximumStrokePixels, backingScale`.
    public var strokeParameters: (Float, Float, Float, Float)
    /// `dashMinimumRunPixels, 0, 0, 0`.
    public var dashParameters: (Float, Float, Float, Float)

    public init(
        matrix: (Float, Float, Float, Float) = (1, 0, 0, 1),
        translationAndViewport: (Float, Float, Float, Float) = (0, 0, 1, 1),
        strokeParameters: (Float, Float, Float, Float) = (1, 1, 4096, 1),
        dashParameters: (Float, Float, Float, Float) = (1.5, 0, 0, 0)
    ) {
        self.matrix = matrix
        self.translationAndViewport = translationAndViewport
        self.strokeParameters = strokeParameters
        self.dashParameters = dashParameters
    }

    public static func == (lhs: FrameUniforms, rhs: FrameUniforms) -> Bool {
        lhs.matrix == rhs.matrix
            && lhs.translationAndViewport == rhs.translationAndViewport
            && lhs.strokeParameters == rhs.strokeParameters
            && lhs.dashParameters == rhs.dashParameters
    }
}
