import CoreGraphics
import Foundation

/// One drawing of a Form XObject on the page (NL-AUTO-12): which form, where, and which of the
/// page's primitives it produced.
///
/// A CAD exporter that keeps blocks writes each door, fixture or symbol once as a Form XObject
/// and draws it with `Do` wherever it is placed. Two invocations of the same form are the same
/// block, exactly — no alignment, no residual. The extractor used to discard that identity and
/// keep only the nesting depth; this side table keeps it, without changing the primitive layout.
public struct VectorFormInvocation: Sendable, Hashable, Codable {
    /// A digest of the form's content-stream bytes and, for a form that draws other forms, of
    /// their identities in drawing order (W-080): stable across extractions of the same file,
    /// equal for every `Do` of the same form (and for byte-identical copies of it that draw
    /// the same sub-forms).
    public let formIdentity: UInt64
    /// The primitives the invocation produced are `primitives[firstPrimitiveIndex ..<
    /// firstPrimitiveIndex + primitiveCount]`, nested invocations' included.
    public let firstPrimitiveIndex: Int
    public let primitiveCount: Int
    /// 1 for a form drawn by page content, 2 for a form drawn inside that one, …
    public let depth: Int
    /// Form space to canonical page space, as `CGAffineTransform` components.
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double

    public init(formIdentity: UInt64, firstPrimitiveIndex: Int, primitiveCount: Int, depth: Int, transform: CGAffineTransform) {
        self.formIdentity = formIdentity
        self.firstPrimitiveIndex = firstPrimitiveIndex
        self.primitiveCount = primitiveCount
        self.depth = depth
        a = Double(transform.a); b = Double(transform.b); c = Double(transform.c)
        d = Double(transform.d); tx = Double(transform.tx); ty = Double(transform.ty)
    }

    public var transform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// The range into ``VectorPageExtraction/primitives``.
    public var primitiveRange: Range<Int> { firstPrimitiveIndex..<(firstPrimitiveIndex + primitiveCount) }
}
