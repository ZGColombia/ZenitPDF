import Foundation

/// Errors raised by dimensional algebra (spec 11.1, 11.4).
public enum DimensionError: Error, Hashable, Sendable {
    /// Addition or subtraction was attempted across different dimensions.
    case incompatibleDimensions(left: QuantityDimension, right: QuantityDimension)
    /// The resulting length power falls outside the supported -3...3 range.
    case unsupportedLengthPower(Int)
    /// angle x angle has no defined meaning in this domain.
    case angleProductUndefined
    /// Dividing a non-angle by an angle has no defined meaning in this domain.
    case angleQuotientUndefined
    /// Two currency-bearing quantities were multiplied.
    case currencyProductUndefined(left: String, right: String)
    /// Currencies differ and cannot be cancelled or combined.
    case currencyMismatch(left: String?, right: String?)
    /// A currency code was not three uppercase ISO 4217 letters.
    case invalidCurrencyCode(String)
    /// The ratio tag was set on a dimension that is not dimensionless — `m` cannot be a factor
    /// (ADR-0014). Only a hand-built or hand-edited value can reach this.
    case ratioOnDimensionedQuantity(QuantityDimension)
    /// Division by a zero quantity.
    case divisionByZero
    /// `DecimalQuantity.sum` of an empty list with no dimension supplied: an empty sum has no
    /// dimension of its own, and a count zero standing in for it would be refused by the next
    /// addition of anything that is not a count (BH-493).
    case emptySumHasNoDimension
}

/// Errors raised while converting between units.
public enum UnitConversionError: Error, Hashable, Sendable {
    /// The quantity's dimension does not match the unit family requested.
    case dimensionMismatch(expected: QuantityDimension, actual: QuantityDimension)
    /// The conversion factor is not exact and an exact conversion was demanded.
    case conversionNotExact(unit: String)
}

/// Errors raised by ``SlopeExpression`` (spec 12.8).
public enum SlopeError: Error, Hashable, Sendable {
    /// `run == 0`: the slope is vertical. Never returns infinity.
    case verticalSlopeUndefined
    /// A ratio of the form 1:n or n:1 was given with n == 0.
    case zeroRatioTerm
    /// The angle's magnitude is 90 degrees or more. At exactly +/- 90 the rise/run is
    /// undefined; beyond it the tangent is a finite number that means nothing as a slope
    /// (BH-495). The accepted range is `-90 < degrees < 90`.
    case degreesOutOfRange(Decimal)
    /// The slope ratio is NaN, or the true-length factor derived from it is not finite.
    case nonFiniteSlopeRatio
    /// An azimuth was built from a non-finite angle or a non-finite displacement (ADR-0004).
    case nonFiniteAzimuth
    /// An azimuth was built from two coincident points, which name no direction (ADR-0004).
    case azimuthFromCoincidentPoints
    /// A slope written as text could not be read as any of the accepted forms (ADR-0004 §3).
    case unparsableSlopeText(String)
}

/// Errors raised by page geometry validation (spec 9.1).
public enum PageGeometryError: Error, Hashable, Sendable {
    /// A box has zero or negative width or height.
    case degenerateBox(name: String)
    /// A box contains a non-finite coordinate.
    case nonFiniteCoordinate(name: String)
    /// The crop box is not contained by the media box.
    case cropBoxOutsideMediaBox
    /// The rotation was not a multiple of 90 degrees.
    case unsupportedRotation(Int)
    /// The PDF UserUnit was zero, negative or non-finite.
    case invalidUserUnit(Double)
}

/// Errors raised by scale construction and inversion (spec 10).
public enum ScaleError: Error, Hashable, Sendable {
    /// A scale factor was zero, negative or non-finite.
    case nonPositiveScale(Decimal)
    /// The 2x2 matrix has a zero determinant and cannot be inverted.
    case singularMatrix
    /// A calibration used two identical or near-identical points.
    case calibrationPointsTooClose(pdfDistance: Double)
    /// A calibration was given a zero or negative real-world length.
    case nonPositiveKnownLength(Decimal)
    /// The X and Y calibration lines are within the parallel tolerance of each other.
    case calibrationLinesNearlyParallel(angleRadians: Double)
    /// A scale outside the sane range was created without explicit confirmation.
    case extremeScaleRequiresConfirmation(metresPerPoint: Decimal)
    /// A stored decimal string could not be parsed back into a `Decimal`.
    case malformedDecimalString(String)
    /// A precision mode carried an unsupported number of decimal places.
    case unsupportedDecimalPlaces(Int)
}

/// Errors raised by coordinate conversion (spec 9.2).
public enum CoordinateError: Error, Hashable, Sendable {
    /// The page id is not present in the current document layout.
    case unknownPage(PageID)
    /// The converter has no live layout yet (no view, or the document is closed).
    case layoutUnavailable
    /// A non-finite coordinate was handed to the converter.
    case nonFiniteCoordinate
    /// The view transform is singular and cannot be inverted.
    case singularViewTransform
}

/// Errors raised by measurement input validation (spec 12.3, 12.4, 12.11).
public enum MeasurementError: Error, Hashable, Sendable {
    /// The geometry carried no usable input for the requested field.
    case emptyGeometry
    /// A polygon had fewer than three unique points.
    case fewerThanThreeUniquePoints
    /// A polygon self-intersects and was not normalised.
    case selfIntersectingPolygon
    /// A polygon or circle has an area indistinguishable from zero.
    case degenerateArea
    /// Three-point circle input is (nearly) collinear.
    case nearlyCollinearPoints
    /// A cutout does not overlap its parent at all (QUALITY_BAR 2.5, ADR-0015). The payload is
    /// the cutout's index in ``PolygonGeometry/holes``: the engine measures geometry, not
    /// markups, so it has no ``MarkupID`` to name. A cutout that overlaps *partly* is accepted
    /// and flagged with ``MeasurementWarning/Code/cutoutOutsideParent``.
    case cutoutOutsideParent(cutoutIndex: Int)
    /// A required parameter (depth, height, rise/run) was not supplied.
    case missingParameter(MeasurementParameterKey)
    /// The requested field is not produced by this geometry.
    case unsupportedField(MeasurementField)
    /// A non-finite coordinate reached the engine.
    case nonFiniteCoordinate
    /// A slope was applied to a length, a perimeter or a wall without a fall-line azimuth
    /// (ADR-0004 §1). There is no scalar fallback: `sqrt(1 + s^2)` is only the length factor for
    /// an edge that runs straight up the slope, so guessing here would over-measure every eave,
    /// ridge and contour line in the drawing.
    case slopeAzimuthRequired(MeasurementField)
    /// A volume was asked for on a sloped markup without saying whether the depth was measured
    /// vertically or perpendicular to the surface (ADR-0004 §2). There is no default.
    case volumeDepthReferenceRequired
    /// A net quantity came out below zero — openings larger than the wall they are cut from.
    /// QUALITY_BAR P11: a negative net area is a typed error, never a value (ADR-0015).
    case negativeNetArea(MeasurementField)
    /// A depth or height parameter was negative or not a number (ADR-0016). A thickness has
    /// no sign; `-0.2 m` is a typing slip, and a volume computed from it would be a negative
    /// value quietly subtracting from every total it enters.
    case negativeParameter(MeasurementParameterKey)
    /// A point, vertex, centre or radius is larger in magnitude than
    /// ``MeasurementGeometry/coordinateMagnitudeBound`` (1e7 PDF points). No PDF page reaches
    /// it; such geometry comes from a corrupt file or a bad transform, and a number computed
    /// from it would look plausible and mean nothing (QUALITY_BAR 2.5, ADR-0035).
    case coordinateOutOfRange
}

/// Names the parameter that a measurement was missing.
public enum MeasurementParameterKey: String, Codable, Hashable, Sendable, CaseIterable {
    case depth
    case height
    /// The far-end wall height of a gable wall (ADR-0004 §2).
    case heightAtEnd
    case riseRun
    case perSegmentRiseDrop
    case totalRiseDrop
    case slopeAzimuth
    case volumeDepthReference
    /// The opening areas subtracted from a wall (ADR-0035): each must be a number and not
    /// negative, or a corrupt record could enlarge the net wall area.
    case openingAreas
}

/// Errors raised by the snap subsystem (spec 13).
public enum SnapError: Error, Hashable, Sendable {
    /// The page has no vector content, so Vector Snap is unavailable.
    case vectorSnapUnavailable(PageID)
    /// A snap radius setting violates minimum <= default <= maximum.
    case invalidRadiusRange(minimum: Double, preferred: Double, maximum: Double)
    /// Hysteresis was negative.
    case negativeHysteresis(Double)
    /// Grid snap was enabled with a non-positive spacing.
    case nonPositiveGridSpacing(Double)
    /// An angle increment of zero or more than 180 degrees was requested.
    case invalidAngleIncrement(degrees: Double)
}

/// Errors raised by the ledger column and row model (spec 15).
public enum LedgerError: Error, Hashable, Sendable {
    /// Two columns claim the same stable key.
    case duplicateColumnKey(String)
    /// A choice column has no options, or a retired option is also the default.
    case invalidChoiceConfiguration(ColumnID)
    /// A cell value's kind does not match its column's kind.
    case cellKindMismatch(column: ColumnID, expected: ColumnKind, actual: ColumnKind)
    /// A built-in standard column was edited in a way the contract forbids.
    case standardColumnNotEditable(StandardLedgerColumn)
    /// A row references a column that is not in the definition set.
    case unknownColumn(ColumnID)
    /// A formula column carries no expression (BH-489).
    case missingFormula(ColumnID)
}

/// Errors raised by the formula grammar (spec 15.4). No JavaScript, no arbitrary functions.
public enum FormulaError: Error, Hashable, Sendable {
    /// The source text is empty or whitespace only.
    case emptySource
    /// The lexer met a character the grammar does not define.
    case unexpectedCharacter(Character, offset: Int)
    /// The parser met a token it cannot place.
    case unexpectedToken(String, offset: Int)
    /// The source ended while the parser still expected input.
    case unexpectedEndOfInput
    /// A function name is not in the frozen function set.
    case unknownFunction(String)
    /// A variable name is neither a frozen variable nor a known custom column key.
    case unknownVariable(String)
    /// A function was called with the wrong number of arguments.
    case argumentCountMismatch(function: String, expected: ClosedRange<Int>, actual: Int)
    /// The expression mixes dimensions in a way the algebra rejects.
    case dimensionRejected(DimensionError)
    /// Column A depends on column B which depends back on column A.
    case cycleDetected(path: [String])
    /// The stored grammar version is newer than this build understands.
    case unsupportedGrammarVersion(stored: Int, supported: Int)
    /// Division by zero inside an evaluated expression.
    case divisionByZero
}

/// Errors raised by the numeric policy helpers (spec 11.4).
public enum NumericError: Error, Hashable, Sendable {
    /// A NaN or infinite Double was handed to a Decimal conversion.
    case nonFiniteValue(Double)
    /// The requested significant-digit count is outside 1...34.
    case unsupportedSignificantDigits(Int)
    /// The Double could not be represented as a Decimal at the requested significance.
    case notRepresentableAsDecimal(Double)
    /// A `Decimal` operation overflowed. `Decimal` saturates to `NaN` rather than trapping, so
    /// the overflow is caught and reported here instead of travelling on as a value. An exact
    /// addition or subtraction whose result does not fit the 38-digit mantissa — which `+`
    /// would silently round — is the same refusal (R-172, ADR-0035).
    case decimalOverflow(operation: String)
}
