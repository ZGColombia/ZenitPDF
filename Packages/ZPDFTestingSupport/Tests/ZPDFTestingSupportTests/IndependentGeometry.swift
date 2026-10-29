import Foundation
import ZPDFTestingSupport

/// Geometry written **only** for the test target.
///
/// The whole value of a manifest is that its numbers were derived from a formula, not
/// from a traversal of the coordinate list. These helpers do the traversal, so that a
/// manifest that disagrees with its own coordinates is caught here rather than by a
/// downstream engine three packages away.
enum IndependentGeometry {

    /// Signed area of a ring by the shoelace formula. Counter-clockwise is positive.
    static func shoelaceArea(_ ring: [FixturePoint]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Condition number of the shoelace sum, as defined in QUALITY_BAR class M-A3.
    static func shoelaceConditionNumber(_ rings: [[FixturePoint]]) -> Double {
        var absoluteSum = 0.0
        var signedSum = 0.0
        for ring in rings where ring.count >= 3 {
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                let cross = a.x * b.y - b.x * a.y
                absoluteSum += abs(cross)
                signedSum += cross
            }
        }
        guard signedSum != 0 else { return .infinity }
        return absoluteSum / abs(signedSum)
    }

    /// Length of an open polyline.
    static func polylineLength(_ points: [FixturePoint]) -> Double {
        guard points.count >= 2 else { return 0 }
        var total = 0.0
        for index in 0..<(points.count - 1) {
            total += points[index].distance(to: points[index + 1])
        }
        return total
    }

    /// Perimeter of a closed ring, including the closing edge.
    static func ringPerimeter(_ ring: [FixturePoint]) -> Double {
        guard ring.count >= 2 else { return 0 }
        var total = 0.0
        for index in ring.indices {
            total += ring[index].distance(to: ring[(index + 1) % ring.count])
        }
        return total
    }

    /// `rel(a, b)` from QUALITY_BAR section 2.1.
    static func relativeError(_ value: Double, _ reference: Double, floor: Double) -> Double {
        abs(value - reference) / Swift.max(abs(reference), floor)
    }

    /// Area enclosed by a chain of cubic Béziers, by dense flattening.
    ///
    /// Used only to confirm that the recorded closed-form Bézier area is the area the
    /// recorded control points actually enclose.
    static func flattenedArea(_ cubics: [FixtureCubic], samplesPerCurve: Int) -> Double {
        var points: [FixturePoint] = []
        points.reserveCapacity(cubics.count * samplesPerCurve)
        for cubic in cubics {
            for step in 0..<samplesPerCurve {
                let t = Double(step) / Double(samplesPerCurve)
                points.append(cubic.point(at: t))
            }
        }
        return shoelaceArea(points)
    }
}
