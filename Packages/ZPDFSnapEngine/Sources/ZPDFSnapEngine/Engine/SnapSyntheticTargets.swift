import Foundation
import ZPDFContracts
import ZPDFGeometry

/// Snap targets that have no primitive behind them: the grid and the angle increment.
///
/// Neither is indexed. A grid has no bounded extent, and an angle constraint depends on the
/// in-progress point rather than on the page, so both are computed analytically inside the
/// radius. That is also what keeps them alive on a scanned page whose vector index is empty —
/// `SNAP_CONTRACT` 13.11 requires exactly that.
public enum SnapSyntheticTargets {

    /// The nearest grid intersection, plus the nearest point on each grid line through the
    /// cursor's cell, if they fall inside the radius.
    ///
    /// The lattice is anchored at the page's **visible box origin**, not at (0, 0): a page whose
    /// crop box starts at (-50, -25) must not have its grid offset by the crop, and a fixture
    /// with a negative media-box origin is exactly where that goes wrong.
    public static func grid(
        cursor: PDFPoint,
        page: PageDescriptor,
        spacing: Double,
        radius: Double
    ) -> [SnapTarget] {
        guard spacing.isFinite, spacing > 0, cursor.isFinite else { return [] }
        let origin = page.visibleBox.standardized
        let ox = origin.minX
        let oy = origin.minY

        let column = ((cursor.x - ox) / spacing).rounded()
        let row = ((cursor.y - oy) / spacing).rounded()
        guard column.isFinite, row.isFinite else { return [] }

        let point = PDFPoint(x: ox + column * spacing, y: oy + row * spacing)
        guard point.isFinite, point.distance(to: cursor) <= radius else { return [] }

        return [
            SnapTarget(
                kind: .grid,
                position: point,
                primitiveID: nil,
                source: .grid,
                confidence: 1.0,
                layerID: nil,
                guide: .crosshair(point)
            )
        ]
    }

    /// The projection of the cursor onto the nearest allowed direction from `anchor`
    /// (`SNAP_CONTRACT` 13.8, `Shift`).
    ///
    /// The candidate is the point on the constrained ray closest to the cursor, so the snap
    /// tracks the cursor along the constrained direction instead of pinning it to a fixed
    /// distance.
    public static func angleIncrement(
        cursor: PDFPoint,
        anchor: PDFPoint,
        incrementDegrees: Double,
        radius: Double
    ) -> [SnapTarget] {
        guard let constraint = SnapAngleConstraint(anchor: anchor, incrementDegrees: incrementDegrees),
              let direction = constraint.direction(toward: cursor),
              let point = constraint.projection(of: cursor)
        else { return [] }
        guard point.isFinite, point.distance(to: cursor) <= radius else { return [] }

        return [
            SnapTarget(
                kind: .angleIncrement,
                position: point,
                primitiveID: nil,
                source: .temporaryGuide,
                confidence: 1.0,
                layerID: nil,
                guide: .ray(origin: anchor, direction: direction)
            )
        ]
    }

    /// Whether a candidate position satisfies the active direction constraint.
    ///
    /// The test is angular, with a tolerance derived from the snap radius at the current zoom:
    /// a candidate one page point off a constrained ray is on the ray at 5 % zoom and far off it
    /// at 6400 %, and the constraint has to mean the same thing to the user at both.
    public static func satisfiesDirection(
        _ position: PDFPoint,
        anchor: PDFPoint,
        incrementDegrees: Double,
        toleranceViewPoints: Double,
        zoom: Double
    ) -> Bool {
        // An increment the constraint does not accept constrains nothing — the same answer
        // `angleIncrement` gives by emitting no target (IM-086).
        guard let constraint = SnapAngleConstraint(anchor: anchor, incrementDegrees: incrementDegrees)
        else { return true }
        // Perpendicular offset from the constrained ray, in page points, then in view points.
        // A candidate at the anchor is on every ray: offset 0.
        return constraint.perpendicularOffset(of: position) * zoom <= toleranceViewPoints
    }
}

/// The Shift constraint of `SNAP_CONTRACT` 13.8: directions from an anchor rounded to a whole
/// multiple of an angle increment.
///
/// One definition, used by the angle-increment target, by the direction test every scored
/// candidate is put through, and by the placed point when nothing wins. The three used to be
/// written out separately and disagreed about which increments are valid — the target refused
/// one above 180 degrees while the other two applied it — so the scored candidate and the
/// placed point could follow different rules (IM-086).
public struct SnapAngleConstraint: Sendable, Hashable {

    public let anchor: PDFPoint
    public let incrementDegrees: Double

    /// The increments the constraint accepts: finite, above zero and at most 180 degrees —
    /// the same range `SnapSettings.validate()` enforces.
    public static func isValidIncrement(_ degrees: Double) -> Bool {
        degrees.isFinite && degrees > 0 && degrees <= 180
    }

    /// `nil` for an increment outside ``isValidIncrement(_:)`` or a non-finite anchor.
    public init?(anchor: PDFPoint, incrementDegrees: Double) {
        guard Self.isValidIncrement(incrementDegrees), anchor.isFinite else { return nil }
        self.anchor = anchor
        self.incrementDegrees = incrementDegrees
    }

    /// The allowed unit direction nearest to the direction from the anchor to `point`, or
    /// `nil` when `point` is at the anchor and has no direction.
    public func direction(toward point: PDFPoint) -> PDFVector? {
        let delta = PDFVector(from: anchor, to: point)
        guard delta.magnitude > 1e-12 else { return nil }
        let step = incrementDegrees * Double.pi / 180
        let snapped = (delta.angle / step).rounded() * step
        return PDFVector(dx: Foundation.cos(snapped), dy: Foundation.sin(snapped))
    }

    /// The nearest point to `point` on the allowed ray: the projection, not a rotation, so the
    /// constrained point tracks the cursor along the ray. `nil` at the anchor.
    public func projection(of point: PDFPoint) -> PDFPoint? {
        guard let direction = direction(toward: point) else { return nil }
        let delta = PDFVector(from: anchor, to: point)
        let projection = Swift.max(0, delta.dot(direction))
        return PDFPoint(
            x: anchor.x + direction.dx * projection,
            y: anchor.y + direction.dy * projection
        )
    }

    /// Distance in page points from `point` to the line of the allowed direction through the
    /// anchor; `0` at the anchor, which lies on every ray.
    public func perpendicularOffset(of point: PDFPoint) -> Double {
        guard let direction = direction(toward: point) else { return 0 }
        return Swift.abs(direction.cross(PDFVector(from: anchor, to: point)))
    }
}
