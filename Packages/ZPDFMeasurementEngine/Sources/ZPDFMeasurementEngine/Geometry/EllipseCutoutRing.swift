import Foundation
import ZPDFContracts

/// The ring an Ellipse Cutout subtracts from its parent: an axis-aligned ellipse inscribed in its
/// box, as an **area-preserving** polygon that never reaches past the box.
///
/// Clipper2 wants a ring rather than a curve, and the parent must lose exactly the πab the cutout
/// row reports (BH-103: the inscribed 72-gon was 0.127 % short). Every polygon inside an ellipse
/// is smaller than it, so an exact-area ring must sit partly outside the curve. The ring used to
/// scale all 360 radii by `k = √(π / ((n/2)·sin(2π/n)))`, which put its vertices at 0°, 90°, 180°
/// and 270° 2.5·10⁻⁵ of a radius **past the box**: a cutout drawn flush with its parent's edge —
/// the box snapped to the wall — then stuck out of the parent by that sliver, and the engine
/// warned `cutoutOutsideParent` on a parent whose cutout lies wholly inside it (X-044).
///
/// Here the four vertices where the ellipse touches its box sit exactly on the box's edges, and
/// the other `n − 4` radii are scaled by the `k′` that restores the area: with `m = 4` unscaled
/// vertices, none adjacent, the shoelace about the centre is
///
/// ```text
/// A = (ab·sin Δ / 2) · Σ sᵢ·sᵢ₊₁ = (ab·sin Δ / 2) · ((n − 2m)·k′² + 2m·k′),   Δ = 2π/n
/// ```
///
/// and `A = πab` gives `k′ = (−m + √(m² + (n − 2m)·T)) / (n − 2m)` with `T = 2π / sin Δ`. For
/// `n = 360`, `k′ = 1.0000256`, below `1 / cos Δ = 1.000152`, so the vertices beside a touching
/// point stay inside the box: the ring lies within the drawn box and meets its edges only at the
/// four touching points.
public enum EllipseCutoutRing {

    /// Facets in the ring: a multiple of four, so the touching points are vertices.
    public static let facets = 360

    /// The ring inscribed in the box `corner`…`opposite`, counter-clockwise from the right-hand
    /// touching point. Its shoelace area is πab to rounding.
    public static func points(corner: PDFPoint, opposite: PDFPoint) -> [PDFPoint] {
        let minX = Swift.min(corner.x, opposite.x), maxX = Swift.max(corner.x, opposite.x)
        let minY = Swift.min(corner.y, opposite.y), maxY = Swift.max(corner.y, opposite.y)
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let radiusX = (maxX - minX) / 2
        let radiusY = (maxY - minY) / 2
        let n = facets
        let quarter = n / 4
        let step = 2 * Double.pi / Double(n)
        let k = scale
        return (0..<n).map { index in
            switch index {
            // The touching points, on the box's edges exactly: the lattice the containment test
            // runs on puts them on a flush parent edge, not a rounding beside it.
            case 0: return PDFPoint(x: maxX, y: centerY)
            case quarter: return PDFPoint(x: centerX, y: maxY)
            case 2 * quarter: return PDFPoint(x: minX, y: centerY)
            case 3 * quarter: return PDFPoint(x: centerX, y: minY)
            default:
                let angle = Double(index) * step
                return PDFPoint(
                    x: centerX + radiusX * k * Foundation.cos(angle),
                    y: centerY + radiusY * k * Foundation.sin(angle)
                )
            }
        }
    }

    /// `k′`, the radius factor of every vertex but the four touching points.
    static let scale: Double = {
        let n = Double(facets)
        let m = 4.0
        let t = 2 * Double.pi / Foundation.sin(2 * Double.pi / n)
        return (-m + (m * m + (n - 2 * m) * t).squareRoot()) / (n - 2 * m)
    }()
}
