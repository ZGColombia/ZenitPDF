import Foundation
import ZPDFUIPresentation

/// A 2-D affine map from the comparison revision's page space into the baseline's.
///
/// `x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`.
public struct RevisionAlignmentTransform: Hashable, Sendable {

    /// Row-one x coefficient.
    public var a: Double
    /// Row-two x coefficient.
    public var b: Double
    /// Row-one y coefficient.
    public var c: Double
    /// Row-two y coefficient.
    public var d: Double
    /// Horizontal translation.
    public var tx: Double
    /// Vertical translation.
    public var ty: Double

    /// Creates a transform.
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// The map that changes nothing.
    public static let identity = RevisionAlignmentTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// Applies the map to a point.
    public func apply(to point: PDFPointValue) -> PDFPointValue {
        PDFPointValue(
            x: a * point.x + c * point.y + tx,
            y: b * point.x + d * point.y + ty
        )
    }

    /// The uniform scale the map applies, as the square root of the absolute determinant.
    public var scale: Double {
        (a * d - b * c).magnitude.squareRoot()
    }

    /// The map's determinant.
    public var determinant: Double { a * d - b * c }

    /// The map that undoes this one, or `nil` when it collapses the plane.
    ///
    /// Needed by the click-to-mark gesture: the person clicks a feature where the
    /// comparison sheet is *currently drawn*, which is baseline space, and the point pair
    /// has to be stored in the comparison sheet's own space so that it stays true after
    /// the next re-fit moves the drawing.
    public func inverted() -> RevisionAlignmentTransform? {
        let det = determinant
        guard det.isFinite, det.magnitude > 1e-12 else { return nil }
        let ia = d / det
        let ib = -b / det
        let ic = -c / det
        let id = a / det
        return RevisionAlignmentTransform(
            a: ia,
            b: ib,
            c: ic,
            d: id,
            tx: -(ia * tx + ic * ty),
            ty: -(ib * tx + id * ty)
        )
    }

    /// The rotation the map applies, in degrees.
    public var rotationDegrees: Double {
        atan2(b, a) * 180 / .pi
    }

    /// The translation the map applies.
    public var translation: PDFPointValue {
        PDFPointValue(x: tx, y: ty)
    }

    /// A localized one-line description of what the map does, for the alignment readout.
    public var displaySummary: String {
        let format = NSLocalizedString(
            "Scale %1$.4f · rotation %2$.2f° · shift %3$.1f, %4$.1f pt",
            comment: "Alignment transform summary: scale, rotation in degrees, translation in points"
        )
        return String(format: format, scale, rotationDegrees, tx, ty)
    }
}

/// One point the person marked on both sheets.
public struct RevisionAlignmentPointPair: Hashable, Sendable, Identifiable {

    /// Stable identity of the pair.
    public let id: UUID
    /// Where the feature sits on the baseline sheet.
    public var baselinePoint: PDFPointValue
    /// Where the same feature sits on the comparison sheet.
    public var comparisonPoint: PDFPointValue

    /// Creates a point pair.
    public init(id: UUID = UUID(), baselinePoint: PDFPointValue, comparisonPoint: PDFPointValue) {
        self.id = id
        self.baselinePoint = baselinePoint
        self.comparisonPoint = comparisonPoint
    }
}

/// Which family of transform the person is fitting.
public enum RevisionAlignmentMode: String, Hashable, Sendable, CaseIterable, Identifiable {

    /// Translation, rotation and one uniform scale. Two points determine it exactly.
    case twoPoint
    /// A full affine map, which also absorbs a different scale in each axis and a shear.
    /// Three points determine it exactly.
    case threePoint

    /// Stable identity.
    public var id: String { rawValue }

    /// How many pairs the fit needs at minimum.
    public var minimumPairCount: Int {
        switch self {
        case .twoPoint: return 2
        case .threePoint: return 3
        }
    }

    /// A localized name for the mode switch.
    public var displayName: String {
        switch self {
        case .twoPoint: return NSLocalizedString("Two Points", comment: "Revision alignment mode")
        case .threePoint: return NSLocalizedString("Three Points", comment: "Revision alignment mode")
        }
    }

    /// A localized sentence explaining what the mode can and cannot absorb.
    public var explanation: String {
        switch self {
        case .twoPoint:
            return NSLocalizedString(
                "Handles a sheet that was moved, turned, or plotted at a different size. Pick two features that appear on both sheets and are far apart.",
                comment: "Explanation of two-point alignment"
            )
        case .threePoint:
            return NSLocalizedString(
                "Also handles a sheet that was stretched differently across and down. Pick three features that are not in a straight line.",
                comment: "Explanation of three-point alignment"
            )
        }
    }
}

/// Why a fit could not be made.
public enum RevisionAlignmentProblem: Error, Hashable, Sendable {

    /// Not enough pairs for the chosen mode.
    case notEnoughPoints(needed: Int, given: Int)
    /// Every marked point is in the same place.
    case pointsCoincide
    /// Every marked point lies on one straight line, which an affine fit cannot resolve.
    case pointsCollinear

    /// A localized sentence saying what is wrong and what to do about it.
    public var message: String {
        switch self {
        case let .notEnoughPoints(needed, given):
            let format = NSLocalizedString(
                "Mark %1$@ on both sheets. You have marked %2$lld.",
                comment: "Alignment problem: not enough point pairs; the needed pairs as '3 matching points', the marked count"
            )
            return String(format: format, WorkflowPlurals.matchingPoints(needed), given)
        case .pointsCoincide:
            return NSLocalizedString(
                "The points you marked are all in the same spot, so there is nothing for Zenit to work out. Spread them across the sheet.",
                comment: "Alignment problem: coincident points"
            )
        case .pointsCollinear:
            return NSLocalizedString(
                "The three points you marked lie on one straight line. Move one of them off the line, for example to the opposite corner of the sheet.",
                comment: "Alignment problem: collinear points"
            )
        }
    }
}

/// A fitted alignment and how well it fits.
public struct RevisionAlignmentFit: Hashable, Sendable {

    /// The map from comparison space into baseline space.
    public var transform: RevisionAlignmentTransform
    /// Root-mean-square distance between where the map puts each marked point and where the
    /// person said it should land, in PDF points.
    public var residualRMSPoints: Double
    /// The single worst such distance.
    public var maximumResidualPoints: Double
    /// How many pairs went into the fit.
    public var pairCount: Int
    /// Which mode was fitted.
    public var mode: RevisionAlignmentMode

    /// Creates a fit.
    public init(
        transform: RevisionAlignmentTransform,
        residualRMSPoints: Double,
        maximumResidualPoints: Double,
        pairCount: Int,
        mode: RevisionAlignmentMode
    ) {
        self.transform = transform
        self.residualRMSPoints = residualRMSPoints
        self.maximumResidualPoints = maximumResidualPoints
        self.pairCount = pairCount
        self.mode = mode
    }

    /// Whether the fit used exactly as many points as it has freedoms.
    ///
    /// When it does, the residual is zero by construction and says nothing about quality. Zenit
    /// reports that honestly rather than showing a reassuring `0.00 pt`.
    public var isExactlyDetermined: Bool {
        pairCount <= mode.minimumPairCount
    }

    /// The presentation-layer alignment state this fit corresponds to.
    ///
    /// The state's residual is in **screen pixels**, and this fit's is in PDF points, so the
    /// caller says how many pixels a point covers (backing scale × zoom). The residual used
    /// to be handed over unconverted and printed as "residual 1.20 px" for a 1.20 pt error —
    /// a threefold understatement at 2× backing and 150 % zoom. Finding BH-835.
    public func alignmentState(pixelsPerPoint: Double) -> RevisionAlignmentState {
        let scale = pixelsPerPoint.isFinite && pixelsPerPoint > 0 ? pixelsPerPoint : 1
        let residualPixels = residualRMSPoints * scale
        switch mode {
        case .twoPoint: return .manualTwoPoint(residualPixels: residualPixels)
        case .threePoint: return .manualThreePoint(residualPixels: residualPixels)
        }
    }

    /// A localized readout of how well the sheets line up.
    public var residualSummary: String {
        if isExactlyDetermined {
            let format = NSLocalizedString(
                "Exact fit on %@. Mark one more point somewhere else on the sheet to see how well it really lines up.",
                comment: "Alignment residual readout when the fit is exactly determined; the pairs as '3 points'"
            )
            return String(format: format, WorkflowPlurals.points(pairCount))
        }
        let format = NSLocalizedString(
            "Typical error %1$.2f pt, worst %2$.2f pt, over %3$@.",
            comment: "Alignment residual readout: RMS error, maximum error, the point count as '5 points'"
        )
        return String(format: format, residualRMSPoints, maximumResidualPoints, WorkflowPlurals.points(pairCount))
    }
}

/// Fits an alignment to the points the person marked.
///
/// Both fits are ordinary least squares, so marking extra points improves the answer instead of
/// being ignored. That matters: with the minimum number of points the residual is always zero and
/// tells the person nothing, and the interface says so.
public enum RevisionAlignmentSolver {

    /// Fits the transform for a mode.
    public static func fit(
        pairs: [RevisionAlignmentPointPair],
        mode: RevisionAlignmentMode
    ) -> Result<RevisionAlignmentFit, RevisionAlignmentProblem> {
        guard pairs.count >= mode.minimumPairCount else {
            return .failure(.notEnoughPoints(needed: mode.minimumPairCount, given: pairs.count))
        }
        switch mode {
        case .twoPoint: return similarity(pairs: pairs)
        case .threePoint: return affine(pairs: pairs)
        }
    }

    /// Least-squares similarity: translation, rotation and one uniform scale.
    public static func similarity(
        pairs: [RevisionAlignmentPointPair]
    ) -> Result<RevisionAlignmentFit, RevisionAlignmentProblem> {
        guard pairs.count >= 2 else {
            return .failure(.notEnoughPoints(needed: 2, given: pairs.count))
        }
        let sourceCentroid = centroid(pairs.map(\.comparisonPoint))
        let targetCentroid = centroid(pairs.map(\.baselinePoint))

        var numeratorCos = 0.0
        var numeratorSin = 0.0
        var denominator = 0.0
        var targetSpread = 0.0
        for pair in pairs {
            let sx = pair.comparisonPoint.x - sourceCentroid.x
            let sy = pair.comparisonPoint.y - sourceCentroid.y
            let tx = pair.baselinePoint.x - targetCentroid.x
            let ty = pair.baselinePoint.y - targetCentroid.y
            numeratorCos += sx * tx + sy * ty
            numeratorSin += sx * ty - sy * tx
            denominator += sx * sx + sy * sy
            targetSpread += tx * tx + ty * ty
        }
        // Both sides are checked, as the affine path checks both. Only the comparison side used
        // to be: baseline clicks on one point made a = b = c = d = 0, reported as an exact fit
        // with "Scale 0.0000", collapsed the comparison sheet to a pixel, and — the inverse
        // being nil — made the next Mark Point store a raw baseline click as a comparison
        // point. Finding BH-308.
        guard denominator > 1e-12, targetSpread > 1e-12 else { return .failure(.pointsCoincide) }

        let scaleCos = numeratorCos / denominator
        let scaleSin = numeratorSin / denominator
        let transform = RevisionAlignmentTransform(
            a: scaleCos,
            b: scaleSin,
            c: -scaleSin,
            d: scaleCos,
            tx: targetCentroid.x - (scaleCos * sourceCentroid.x - scaleSin * sourceCentroid.y),
            ty: targetCentroid.y - (scaleSin * sourceCentroid.x + scaleCos * sourceCentroid.y)
        )
        return .success(makeFit(transform: transform, pairs: pairs, mode: .twoPoint))
    }

    /// Least-squares affine: also absorbs a different scale in each axis and a shear.
    public static func affine(
        pairs: [RevisionAlignmentPointPair]
    ) -> Result<RevisionAlignmentFit, RevisionAlignmentProblem> {
        guard pairs.count >= 3 else {
            return .failure(.notEnoughPoints(needed: 3, given: pairs.count))
        }
        if isCollinear(pairs.map(\.comparisonPoint)) || isCollinear(pairs.map(\.baselinePoint)) {
            return .failure(.pointsCollinear)
        }

        var sumXX = 0.0, sumXY = 0.0, sumYY = 0.0, sumX = 0.0, sumY = 0.0
        var rhsAX = 0.0, rhsAY = 0.0, rhsA1 = 0.0
        var rhsBX = 0.0, rhsBY = 0.0, rhsB1 = 0.0
        let count = Double(pairs.count)
        for pair in pairs {
            let x = pair.comparisonPoint.x
            let y = pair.comparisonPoint.y
            let u = pair.baselinePoint.x
            let v = pair.baselinePoint.y
            sumXX += x * x
            sumXY += x * y
            sumYY += y * y
            sumX += x
            sumY += y
            rhsAX += x * u
            rhsAY += y * u
            rhsA1 += u
            rhsBX += x * v
            rhsBY += y * v
            rhsB1 += v
        }
        let normal = Matrix3(
            m00: sumXX, m01: sumXY, m02: sumX,
            m10: sumXY, m11: sumYY, m12: sumY,
            m20: sumX, m21: sumY, m22: count
        )
        guard let rowOne = normal.solve(rhsAX, rhsAY, rhsA1),
              let rowTwo = normal.solve(rhsBX, rhsBY, rhsB1) else {
            return .failure(.pointsCollinear)
        }
        let transform = RevisionAlignmentTransform(
            a: rowOne.0, b: rowTwo.0,
            c: rowOne.1, d: rowTwo.1,
            tx: rowOne.2, ty: rowTwo.2
        )
        return .success(makeFit(transform: transform, pairs: pairs, mode: .threePoint))
    }

    /// Whether every point lies on one straight line, to within a relative tolerance.
    public static func isCollinear(_ points: [PDFPointValue], relativeTolerance: Double = 1e-6) -> Bool {
        guard points.count >= 3 else { return true }
        var extent = 0.0
        for outer in points {
            for inner in points {
                extent = max(extent, outer.distance(to: inner))
            }
        }
        guard extent > 1e-9 else { return true }
        let origin = points[0]
        var maximumArea = 0.0
        for i in 1..<points.count {
            for j in (i + 1)..<points.count {
                let ax = points[i].x - origin.x
                let ay = points[i].y - origin.y
                let bx = points[j].x - origin.x
                let by = points[j].y - origin.y
                maximumArea = max(maximumArea, (ax * by - ay * bx).magnitude)
            }
        }
        return maximumArea / (extent * extent) < relativeTolerance
    }

    // MARK: - Private

    private static func makeFit(
        transform: RevisionAlignmentTransform,
        pairs: [RevisionAlignmentPointPair],
        mode: RevisionAlignmentMode
    ) -> RevisionAlignmentFit {
        var sumSquares = 0.0
        var worst = 0.0
        for pair in pairs {
            let mapped = transform.apply(to: pair.comparisonPoint)
            let distance = mapped.distance(to: pair.baselinePoint)
            sumSquares += distance * distance
            worst = max(worst, distance)
        }
        let rms = (sumSquares / Double(pairs.count)).squareRoot()
        return RevisionAlignmentFit(
            transform: transform,
            residualRMSPoints: rms,
            maximumResidualPoints: worst,
            pairCount: pairs.count,
            mode: mode
        )
    }

    private static func centroid(_ points: [PDFPointValue]) -> PDFPointValue {
        guard !points.isEmpty else { return .zero }
        let count = Double(points.count)
        return PDFPointValue(
            x: points.reduce(0) { $0 + $1.x } / count,
            y: points.reduce(0) { $0 + $1.y } / count
        )
    }
}

/// A 3×3 system solved by Cramer's rule, which is enough for the normal equations of a plane fit.
private struct Matrix3 {
    let m00, m01, m02: Double
    let m10, m11, m12: Double
    let m20, m21, m22: Double

    var determinant: Double {
        m00 * (m11 * m22 - m12 * m21)
            - m01 * (m10 * m22 - m12 * m20)
            + m02 * (m10 * m21 - m11 * m20)
    }

    func solve(_ r0: Double, _ r1: Double, _ r2: Double) -> (Double, Double, Double)? {
        let det = determinant
        guard det.magnitude > 1e-9 else { return nil }
        let dx = Matrix3(
            m00: r0, m01: m01, m02: m02,
            m10: r1, m11: m11, m12: m12,
            m20: r2, m21: m21, m22: m22
        ).determinant
        let dy = Matrix3(
            m00: m00, m01: r0, m02: m02,
            m10: m10, m11: r1, m12: m12,
            m20: m20, m21: r2, m22: m22
        ).determinant
        let dz = Matrix3(
            m00: m00, m01: m01, m02: r0,
            m10: m10, m11: m11, m12: r1,
            m20: m20, m21: m21, m22: r2
        ).determinant
        return (dx / det, dy / det, dz / det)
    }
}

/// The statement Zenit always shows next to an aligned overlay.
public enum RevisionAlignmentDisclosure {

    /// What an alignment is and is not.
    public static let approximate = NSLocalizedString(
        "Alignment is approximate. Two sheets are never plotted identically, so treat an overlay as a way to find changes, not as proof of where something is.",
        comment: "Standing statement about revision alignment"
    )

    /// What a detected difference is and is not.
    public static let differencesAreCandidates = NSLocalizedString(
        "Detected differences are candidates for you to review. Zenit does not decide that something is a change, and never claims one is a variation.",
        comment: "Standing statement about detected revision differences"
    )
}
