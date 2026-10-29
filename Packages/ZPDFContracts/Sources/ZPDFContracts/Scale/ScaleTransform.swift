import Foundation

/// A point in real-world space, in metres.
public struct RealPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = RealPoint(x: 0, y: 0)

    /// Distance in metres.
    public func distance(to other: RealPoint) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A displacement in real-world space, in metres.
public struct RealVector: Codable, Hashable, Sendable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }

    /// Length in metres.
    public var magnitude: Double { (dx * dx + dy * dy).squareRoot() }
}

/// The affine map `r = A * p + b` from PDF page points to real-world metres (spec 10.1).
///
/// The six components are stored as `Decimal` and persisted as **decimal strings**, so a scale
/// written by one build reads back bit-identically in the next: no binary float, no locale, no
/// drift. Geometry maths reads the `Double` projection through ``components``.
///
/// `a`, `b`, `c`, `d` are metres per PDF point. `tx`, `ty` are metres.
public struct AffineScaleMatrix: Hashable, Sendable {
    public let a: Decimal
    public let b: Decimal
    public let c: Decimal
    public let d: Decimal
    public let tx: Decimal
    public let ty: Decimal

    public init(a: Decimal, b: Decimal, c: Decimal, d: Decimal, tx: Decimal = 0, ty: Decimal = 0) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// The identity map: one metre per PDF point. Only useful as an algebraic unit.
    public static let identity = AffineScaleMatrix(a: 1, b: 0, c: 0, d: 1)

    /// `det(A)`. Its absolute value is the area factor: square metres per square PDF point
    /// (spec 10.1).
    public var determinant: Decimal { a * d - b * c }

    /// `abs(det(A))` — the factor a PDF-space area is multiplied by to become a real area.
    public var areaFactor: Decimal { Swift.abs(determinant) }

    /// The inverse map, from metres back to PDF page points.
    ///
    /// - Throws: ``ScaleError/singularMatrix`` when `det(A) == 0`.
    public func inverted() throws -> AffineScaleMatrix {
        let det = determinant
        guard det != 0 else { throw ScaleError.singularMatrix }
        let ia = d / det
        let ib = -b / det
        let ic = -c / det
        let id = a / det
        return AffineScaleMatrix(
            a: ia,
            b: ib,
            c: ic,
            d: id,
            tx: -(ia * tx + ib * ty),
            ty: -(ic * tx + id * ty)
        )
    }

    /// The six components widened to `Double`, which is what geometry code multiplies with.
    public struct Components: Hashable, Sendable {
        public let a: Double
        public let b: Double
        public let c: Double
        public let d: Double
        public let tx: Double
        public let ty: Double
    }

    /// `Double` projection of the matrix. Lossy by construction and deliberately explicit.
    public var components: Components {
        Components(
            a: NumericPolicy.double(from: a),
            b: NumericPolicy.double(from: b),
            c: NumericPolicy.double(from: c),
            d: NumericPolicy.double(from: d),
            tx: NumericPolicy.double(from: tx),
            ty: NumericPolicy.double(from: ty)
        )
    }

    /// Maps a page point to a real-world point, in metres.
    public func map(_ point: PDFPoint) -> RealPoint {
        let m = components
        return RealPoint(
            x: m.a * point.x + m.b * point.y + m.tx,
            y: m.c * point.x + m.d * point.y + m.ty
        )
    }

    /// Maps a page-space displacement to a real-world displacement. Translation does not apply
    /// to a delta, which is why lengths use this and not two ``map(_:)`` calls.
    public func mapDelta(dx: Double, dy: Double) -> RealVector {
        let m = components
        return RealVector(dx: m.a * dx + m.b * dy, dy: m.c * dx + m.d * dy)
    }

    /// Real-world length of the page-space segment `from`->`to`, in metres (spec 10.1).
    public func length(from start: PDFPoint, to end: PDFPoint) -> Double {
        mapDelta(dx: end.x - start.x, dy: end.y - start.y).magnitude
    }

    /// Metres per PDF point along the page x axis.
    public var metresPerPointX: Double {
        let m = components
        return (m.a * m.a + m.c * m.c).squareRoot()
    }

    /// Metres per PDF point along the page y axis.
    public var metresPerPointY: Double {
        let m = components
        return (m.b * m.b + m.d * m.d).squareRoot()
    }

    /// True when the map is the same in every direction (no shear, equal axis scales).
    public var isUniform: Bool {
        b == 0 && c == 0 && a == d
    }
}

extension AffineScaleMatrix: Codable {
    private enum CodingKeys: String, CodingKey {
        case a, b, c, d, tx, ty
    }

    /// Decimals persist as strings. `Decimal.description` is the round-trippable canonical form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(a.description, forKey: .a)
        try container.encode(b.description, forKey: .b)
        try container.encode(c.description, forKey: .c)
        try container.encode(d.description, forKey: .d)
        try container.encode(tx.description, forKey: .tx)
        try container.encode(ty.description, forKey: .ty)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decimal(_ key: CodingKeys) throws -> Decimal {
            let text = try container.decode(String.self, forKey: key)
            guard let value = Decimal(string: text, locale: nil) else {
                throw ScaleError.malformedDecimalString(text)
            }
            return value
        }
        self.init(
            a: try decimal(.a),
            b: try decimal(.b),
            c: try decimal(.c),
            d: try decimal(.d),
            tx: try decimal(.tx),
            ty: try decimal(.ty)
        )
    }
}

/// Where a scale came from (spec 10.2, 10.3, 10.4).
///
/// The provenance is part of the contract because the UI must never present a guessed scale as
/// a measured one, and because a recalculation prompt reads differently for an inherited scale
/// than for one the user calibrated by hand.
public enum ScaleSource: String, Codable, Hashable, Sendable, CaseIterable {
    /// Two points plus a known real length (spec 10.2).
    case calibrationTwoPoint
    /// Independent X and Y calibration lines (spec 10.3).
    case calibrationXY
    /// A named architectural or engineering preset, for example 1:50.
    case preset
    /// Copied from another page, a bulk apply, or the document default (spec 10.5).
    case inherited
}

/// How a value is rounded when it is shown or exported (spec 11.5).
///
/// Display rounding never touches the stored SI value.
public enum PrecisionMode: Codable, Hashable, Sendable {
    /// Metric: a fixed number of decimal places, ``decimalPlacesRange``.
    case decimalPlaces(Int)
    /// Imperial: the nearest 1/denominator of the display unit.
    case imperialFraction(ImperialFractionDenominator)

    public static let defaultMetric = PrecisionMode.decimalPlaces(3)
    public static let defaultImperial = PrecisionMode.imperialFraction(.sixteenth)

    /// The decimal places a metric precision may ask for. The freeze prints this constant.
    public static let decimalPlacesRange = 0...12

    public func validate() throws {
        if case .decimalPlaces(let places) = self, !Self.decimalPlacesRange.contains(places) {
            throw ScaleError.unsupportedDecimalPlaces(places)
        }
    }

    /// The synthesized layout, decoded and then validated (BH-491, ADR-0017).
    ///
    /// Nothing in production called ``validate()``: a stored `decimalPlaces(-2)` reached
    /// `NSDecimalRound` and showed `384.2 m²` as `400`. A precision decodes from a project
    /// file or a saved layout, and a value that decodes is validated, as
    /// ``QuantityDimension`` already is. The shadow enum keeps the wire format byte-identical
    /// to what the synthesized conformance wrote.
    public init(from decoder: Decoder) throws {
        switch try StoredForm(from: decoder) {
        case .decimalPlaces(let places): self = .decimalPlaces(places)
        case .imperialFraction(let denominator): self = .imperialFraction(denominator)
        }
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "PrecisionMode out of range: \(error)"
            ))
        }
    }

    /// Mirrors the cases exactly so the synthesized `Codable` of this shadow reads and writes
    /// the same JSON as ``PrecisionMode`` itself.
    private enum StoredForm: Codable {
        case decimalPlaces(Int)
        case imperialFraction(ImperialFractionDenominator)
    }

    /// Applies the mode to a value. **View and export boundary only.**
    public func apply(to value: Decimal) -> Decimal {
        switch self {
        case .decimalPlaces(let places):
            NumericPolicy.rounded(value, decimalPlaces: places)
        case .imperialFraction(let denominator):
            NumericPolicy.roundedToFraction(value, denominator: denominator.rawValue)
        }
    }
}

/// The imperial fraction denominators the product supports (spec 11.5).
public enum ImperialFractionDenominator: Int, Codable, Hashable, Sendable, CaseIterable {
    case whole = 1
    case half = 2
    case quarter = 4
    case eighth = 8
    case sixteenth = 16
    case thirtySecond = 32
    case sixtyFourth = 64
}

/// The unit metadata a scale carries so measurements made under it display consistently.
public struct ScaleUnitPolicy: Codable, Hashable, Sendable {
    public var length: LengthUnit
    public var area: AreaUnit
    public var volume: VolumeUnit
    public var angle: AngleUnit
    public var precision: PrecisionMode

    public init(
        length: LengthUnit,
        area: AreaUnit,
        volume: VolumeUnit,
        angle: AngleUnit = .degree,
        precision: PrecisionMode = .defaultMetric
    ) {
        self.length = length
        self.area = area
        self.volume = volume
        self.angle = angle
        self.precision = precision
    }

    public static let metric = ScaleUnitPolicy(
        length: .metre,
        area: .squareMetre,
        volume: .cubicMetre,
        angle: .degree,
        precision: .defaultMetric
    )

    public static let imperial = ScaleUnitPolicy(
        length: .foot,
        area: .squareFoot,
        volume: .cubicYard,
        angle: .degree,
        precision: .defaultImperial
    )
}

/// A versioned, identified scale: the matrix plus everything needed to reproduce and audit it
/// (spec 10.1, 10.6).
///
/// A markup stores the scale id **and** the scale version it was measured under, so changing a
/// scale can offer Recalculate / Keep / Cancel with an exact count of what is affected, and so a
/// stale measurement is always detectable rather than silently wrong.
public struct ScaleTransform: Codable, Hashable, Sendable {
    /// Stable identity of this scale across edits.
    public let id: ScaleID
    /// The page this scale belongs to (spec 10.5).
    ///
    /// A drawing set routinely mixes scales — a 1:100 plan and a 1:20 detail on the same set,
    /// or a detail sheet drawn at its own scale — so a scale without a page is a scale that can
    /// be applied to a sheet nobody calibrated. The resolution order is *Scale Region, else the
    /// page's own scale, else nothing*, and "nothing" means the measurement is refused.
    ///
    /// It is `Optional` for exactly two reasons, both narrow:
    ///
    /// - The pure measurement and geometry engines take a `ScaleTransform` as a **value**. A
    ///   golden case that measures a polygon at 1:50 has no document and no page, and inventing
    ///   a page identity for it would be a fiction the engine then had to carry.
    /// - A project written before this contract version has no page recorded on the value (it
    ///   is recorded on the *row*: `scale_definition.page_id` has been `NOT NULL` since schema
    ///   v1), so `nil` decodes without a migration of the encoded form.
    ///
    /// Everywhere a scale meets a *document* it is required: `TakeoffSession` refuses a scale
    /// with no page and refuses one whose page it does not hold, so a `nil` here can never
    /// reach a measurement.
    public let pageID: PageID?
    /// Bumped on every change to the matrix. Markups record the version they used.
    public let version: Int
    /// The affine map, PDF points to metres.
    public let matrix: AffineScaleMatrix
    /// Display unit and precision metadata.
    public let units: ScaleUnitPolicy
    /// Where the scale came from.
    public let source: ScaleSource
    /// Optional human label, for example "1:50" or "Calibrated on grid line A".
    public let label: String?

    public init(
        id: ScaleID,
        pageID: PageID? = nil,
        version: Int,
        matrix: AffineScaleMatrix,
        units: ScaleUnitPolicy,
        source: ScaleSource,
        label: String? = nil
    ) {
        self.id = id
        self.pageID = pageID
        self.version = version
        self.matrix = matrix
        self.units = units
        self.source = source
        self.label = label
    }

    // MARK: - Constructors

    /// The bounds outside which a scale is considered extreme and needs confirmation
    /// (spec 10.2). One micrometre and ten kilometres per PDF point respectively.
    public static let sanePointScaleRange: ClosedRange<Decimal> =
        NumericPolicy.exact(1, -6)...NumericPolicy.exact(1, 4)

    /// The smallest distance, in PDF points, two calibration points may be apart. The default
    /// of `calibratedTwoPoint(minimumPDFDistance:)`, and the value the freeze prints (BH-484).
    public static let minimumCalibrationPDFDistance: Double = 4.0

    /// A uniform scale: the same metres per PDF point in both axes (spec 10.1).
    public static func uniform(
        id: ScaleID,
        pageID: PageID? = nil,
        version: Int = 1,
        metresPerPoint: Decimal,
        units: ScaleUnitPolicy,
        source: ScaleSource,
        label: String? = nil,
        allowExtreme: Bool = false
    ) throws -> ScaleTransform {
        guard metresPerPoint > 0 else { throw ScaleError.nonPositiveScale(metresPerPoint) }
        if !allowExtreme, !sanePointScaleRange.contains(metresPerPoint) {
            throw ScaleError.extremeScaleRequiresConfirmation(metresPerPoint: metresPerPoint)
        }
        return ScaleTransform(
            id: id,
            pageID: pageID,
            version: version,
            matrix: AffineScaleMatrix(a: metresPerPoint, b: 0, c: 0, d: metresPerPoint),
            units: units,
            source: source,
            label: label
        )
    }

    /// A separate-XY scale: independent metres per PDF point per axis (spec 10.1, 10.3).
    public static func separateXY(
        id: ScaleID,
        pageID: PageID? = nil,
        version: Int = 1,
        metresPerPointX: Decimal,
        metresPerPointY: Decimal,
        units: ScaleUnitPolicy,
        source: ScaleSource,
        label: String? = nil,
        allowExtreme: Bool = false
    ) throws -> ScaleTransform {
        guard metresPerPointX > 0 else { throw ScaleError.nonPositiveScale(metresPerPointX) }
        guard metresPerPointY > 0 else { throw ScaleError.nonPositiveScale(metresPerPointY) }
        if !allowExtreme {
            for factor in [metresPerPointX, metresPerPointY]
            where !sanePointScaleRange.contains(factor) {
                throw ScaleError.extremeScaleRequiresConfirmation(metresPerPoint: factor)
            }
        }
        return ScaleTransform(
            id: id,
            pageID: pageID,
            version: version,
            matrix: AffineScaleMatrix(a: metresPerPointX, b: 0, c: 0, d: metresPerPointY),
            units: units,
            source: source,
            label: label
        )
    }

    /// Two-point calibration (spec 10.2): a PDF-space distance and the real length it represents.
    ///
    /// - Throws: ``ScaleError/calibrationPointsTooClose(pdfDistance:)`` when the two points are
    ///   within `minimumPDFDistance` of each other, and
    ///   ``ScaleError/nonPositiveKnownLength(_:)`` for a zero or negative length.
    public static func calibratedTwoPoint(
        id: ScaleID,
        pageID: PageID? = nil,
        version: Int = 1,
        first: PDFPoint,
        second: PDFPoint,
        knownLength: Decimal,
        knownLengthUnit: LengthUnit,
        units: ScaleUnitPolicy,
        label: String? = nil,
        minimumPDFDistance: Double = ScaleTransform.minimumCalibrationPDFDistance,
        allowExtreme: Bool = false
    ) throws -> ScaleTransform {
        guard knownLength > 0 else { throw ScaleError.nonPositiveKnownLength(knownLength) }
        let pdfDistance = first.distance(to: second)
        guard pdfDistance.isFinite, pdfDistance >= minimumPDFDistance else {
            throw ScaleError.calibrationPointsTooClose(pdfDistance: pdfDistance)
        }
        let metres = knownLengthUnit.toBase(knownLength)
        let divisor = try NumericPolicy.decimal(from: pdfDistance)
        return try uniform(
            id: id,
            pageID: pageID,
            version: version,
            metresPerPoint: metres / divisor,
            units: units,
            source: .calibrationTwoPoint,
            label: label,
            allowExtreme: allowExtreme
        )
    }

    /// A preset drawing ratio on a page, honouring the page's `/UserUnit` (spec 9.1, 10.1;
    /// code review CR-128).
    ///
    /// `1:100` is `ratioNumerator: 1, ratioDenominator: 100`. The factor is
    /// `0.0254 / 72 * denominator / numerator * page.userUnit` metres per PDF unit — see
    /// ``AffineScaleMatrix/metresPerPoint(ratioNumerator:ratioDenominator:userUnit:)`` for why
    /// the user unit belongs here and not in a calibration.
    public static func preset(
        id: ScaleID,
        page: PageDescriptor,
        version: Int = 1,
        ratioNumerator: Decimal = 1,
        ratioDenominator: Decimal,
        units: ScaleUnitPolicy,
        label: String? = nil,
        allowExtreme: Bool = false
    ) throws -> ScaleTransform {
        let metresPerPoint = try AffineScaleMatrix.metresPerPoint(
            ratioNumerator: ratioNumerator,
            ratioDenominator: ratioDenominator,
            userUnit: page.userUnit
        )
        return try uniform(
            id: id,
            pageID: page.id,
            version: version,
            metresPerPoint: metresPerPoint,
            units: units,
            source: .preset,
            label: label ?? "\(ratioNumerator):\(ratioDenominator)",
            allowExtreme: allowExtreme
        )
    }

    // MARK: - Derived

    /// `det(A)` (spec 10.1).
    public var determinant: Decimal { matrix.determinant }

    /// The inverse map, metres back to PDF page points.
    ///
    /// This returns a bare ``AffineScaleMatrix`` rather than a `ScaleTransform` on purpose: the
    /// inverse is not a scale. It has no id, no version and no provenance, and treating it as one
    /// is how a metres-per-point number ends up persisted as points-per-metre.
    public func inverse() throws -> AffineScaleMatrix { try matrix.inverted() }

    /// Square metres per square PDF point.
    public var areaFactor: Decimal { matrix.areaFactor }

    public var isUniform: Bool { matrix.isUniform }

    /// True when the scale sits outside ``sanePointScaleRange`` in either axis.
    public var isExtreme: Bool {
        let x = matrix.metresPerPointX
        let y = matrix.metresPerPointY
        let low = NumericPolicy.double(from: Self.sanePointScaleRange.lowerBound)
        let high = NumericPolicy.double(from: Self.sanePointScaleRange.upperBound)
        return !(x >= low && x <= high) || !(y >= low && y <= high)
    }

    /// Returns the same scale with a bumped version and a new matrix, which is the only way the
    /// matrix ever changes (spec 10.6).
    public func revised(matrix newMatrix: AffineScaleMatrix, source newSource: ScaleSource) -> ScaleTransform {
        ScaleTransform(
            id: id,
            pageID: pageID,
            version: version + 1,
            matrix: newMatrix,
            units: units,
            source: newSource,
            label: label
        )
    }

    /// The same scale, recorded as belonging to `page`.
    ///
    /// The version is **not** bumped: which sheet a scale was calibrated on is not a change to
    /// the transform, and bumping it here would mark every measurement taken under the scale
    /// stale for a fact that does not alter a single number. This is what the reader of a
    /// pre-page project uses to attach the page the row already records.
    public func assigned(toPage page: PageID) -> ScaleTransform {
        ScaleTransform(
            id: id,
            pageID: page,
            version: version,
            matrix: matrix,
            units: units,
            source: source,
            label: label
        )
    }
}

/// The three answers to "this scale changed, what about the measurements?" (spec 10.6).
public enum ScaleChangePolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Recompute every affected measurement. Undoable.
    case recalculate
    /// Leave stored values as they are; they keep their original scale version.
    case keepExisting
    /// Abandon the scale change.
    case cancel
}

/// The scope a scale is applied to in a bulk operation (spec 10.5).
public enum ScaleApplicationScope: String, Codable, Hashable, Sendable, CaseIterable {
    case currentPage
    case selectedPages
    case pageRange
    case pagesWithSameDimensions
    case entireDocument
}

/// What happens when a markup crosses two Scale Regions (spec 10.4).
///
/// There is no "pick one silently" case, by design.
public enum ScaleRegionCrossingPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Split the markup at the region boundary.
    case splitAtBoundary
    /// Ask the user which scale applies.
    case askUser
    /// Refuse to create the markup.
    case block
}

// MARK: - Drawing ratios and /UserUnit (spec 9.1, 10.1)

extension AffineScaleMatrix {
    /// Metres of real world per PDF user-space unit for a drawing plotted at
    /// `ratioNumerator : ratioDenominator` (`1:100` is numerator 1, denominator 100) on a page
    /// whose `/UserUnit` is `userUnit`.
    ///
    /// `/UserUnit` scales the page's user space: at `/UserUnit 2` one page unit is 2/72 inch,
    /// so every preset factor doubles (a `/UserUnit 2` sheet read at `/UserUnit 1` measures
    /// every quantity at half size). A two-point calibration needs no such correction: the two
    /// points are measured in the very user space the drawing content lives in, so the factor
    /// it derives already carries the user unit implicitly. This function is therefore the
    /// point-to-real conversion that has to honour the field explicitly — and until code review
    /// CR-128 nothing in the program read it.
    ///
    /// - Throws: ``ScaleError/nonPositiveScale(_:)`` for a non-positive ratio term,
    ///   ``PageGeometryError/invalidUserUnit(_:)`` for a non-finite or non-positive user unit.
    public static func metresPerPoint(
        ratioNumerator: Decimal = 1,
        ratioDenominator: Decimal,
        userUnit: Double
    ) throws -> Decimal {
        guard ratioNumerator > 0 else { throw ScaleError.nonPositiveScale(ratioNumerator) }
        guard ratioDenominator > 0 else { throw ScaleError.nonPositiveScale(ratioDenominator) }
        guard userUnit.isFinite, userUnit > 0 else {
            throw PageGeometryError.invalidUserUnit(userUnit)
        }
        let unit = try NumericPolicy.decimal(from: userUnit)
        // One division, last: the numerator product is exact in `Decimal` for every realistic
        // input, so the only rounding is the final quotient and the result does not depend on
        // the order the factors happened to be applied in.
        return NumericPolicy.exact(254, -4) * ratioDenominator * unit / (72 * ratioNumerator)
    }
}
