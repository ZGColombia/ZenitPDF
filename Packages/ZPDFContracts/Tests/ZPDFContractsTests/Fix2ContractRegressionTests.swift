import CoreGraphics
import Foundation
import Testing
@testable import ZPDFContracts

// Bug hunt 2, engine fixes, package ZPDFContracts (ADR-0016, ADR-0017).
//
// Every test names the output the old code gave in a comment, so each one is a regression
// test that failed before the fix and not a description of the fix. Expected numbers are
// derived by hand in the comments, never copied from the new code's output.

private func uuid(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte, byte))
}

private let frozenAt = "2026-09-01T23:28:48Z"

private func document(_ name: String) throws -> ContractDocument {
    try #require(try ContractCatalog.allDocuments(frozenAt: frozenAt).first { $0.contract == name })
}

// MARK: - Ledger contract

@Suite("Fix 2 — ledger contract (ADR-0016, ADR-0017)")
struct Fix2LedgerContractTests {

    @Test("BH-017: Plan Area reads the net area, the number Volume and the Area variable use")
    func planAreaColumnReadsNet() throws {
        // Old output: `.planArea`. A 10 x 10 m slab with a 4 x 4 m cutout under the default
        // `.subtractFromArea` showed 100 m² in the Plan Area column while Volume was built
        // from 84 x depth and the formula variable Area evaluated to 84; under
        // `.subtractAndReportSeparately` the parent (100) and the cutout row (16) summed to
        // 116 m² for an 84 m² slab.
        #expect(StandardLedgerColumn.planArea.measurementField == .netArea)
        // The analogue that already existed, unchanged.
        #expect(StandardLedgerColumn.wallArea.measurementField == .netWallArea)
        // The gross outline is never what Plan Area reads. Since ADR-0018 exactly one column
        // reads it — Gross Area, reported beside Plan Area and never summed into it.
        #expect(StandardLedgerColumn.allCases.filter { $0.measurementField == .planArea } == [.grossArea])

        // A stored result carries both; the column reads 84 = 100 - 16, never 100.
        let result = MeasurementResult(values: [
            .planArea: .area(100), .netArea: .area(84), .cutoutArea: .area(16)
        ])
        let field = try #require(StandardLedgerColumn.planArea.measurementField)
        #expect(result[field]?.value == 84)
        #expect(result[.planArea]?.value == 100, "the gross outline is still stored")

        // The frozen document says so, and names the ADR.
        let ledger = try document("LEDGER_CONTRACT")
        let columns = try #require(ledger.types.first { $0.name == "StandardLedgerColumn" })
        #expect(columns.invariants.contains { $0.contains("planArea reads netArea") && $0.contains("ADR-0016") })
        let row = try #require(ledger.tables.first { $0.name == "standardColumns" }?
            .rows.first { $0.first == "planArea" })
        #expect(row.contains("netArea"))
        #expect(!row.contains("planArea") || row.first == "planArea")
    }

    @Test("BH-488: Depth and Height are read-only, like every column that reads a measurement field")
    func depthAndHeightAreReadOnly() {
        // Old output: `isUserEditable == true` for `.depth` and `.height`, forwarded to the UI
        // as an editable cell, while the store read the measurement first and returned
        // `.empty` rather than the customValues entry — a typed depth could never be read back.
        #expect(!StandardLedgerColumn.depth.isUserEditable)
        #expect(!StandardLedgerColumn.height.isUserEditable)
        for column in StandardLedgerColumn.allCases where column.measurementField != nil {
            #expect(!column.isUserEditable, "\(column) reads a measurement field")
        }
        // The columns a person types into are untouched.
        for column in [StandardLedgerColumn.subject, .label, .comment, .status, .costCode,
                       .trade, .phase, .material, .unitCost, .displayUnit] {
            #expect(column.isUserEditable, "\(column)")
        }
        // The definition validator refuses an editable Depth column (it accepted one before).
        let depth = LedgerColumnDefinition(
            id: ColumnID(uuid(1)), key: "depth", title: "Depth", kind: .number,
            standard: .depth, isEditable: true
        )
        #expect(throws: LedgerError.standardColumnNotEditable(.depth)) { try depth.validate() }
        let readOnly = LedgerColumnDefinition(
            id: ColumnID(uuid(1)), key: "depth", title: "Depth", kind: .number,
            standard: .depth, isEditable: false
        )
        #expect(throws: Never.self) { try readOnly.validate() }
    }

    @Test("BH-489: a formula column without an expression is missingFormula, not a choice problem")
    func formulaColumnWithoutExpression() {
        // Old output: `LedgerError.invalidChoiceConfiguration(id)`, documented as "a choice
        // column has no options, or a retired option is also the default".
        let id = ColumnID(uuid(2))
        let formula = LedgerColumnDefinition(id: id, key: "waste", title: "Waste", kind: .formula)
        #expect(throws: LedgerError.missingFormula(id)) { try formula.validate() }
        // A choice column with no options still gets the choice error.
        let choice = LedgerColumnDefinition(id: id, key: "phase", title: "Phase", kind: .choice)
        #expect(throws: LedgerError.invalidChoiceConfiguration(id)) { try choice.validate() }
        // A formula column with an expression validates as before.
        let valid = LedgerColumnDefinition(
            id: id, key: "waste", title: "Waste", kind: .formula,
            formula: FormulaExpression(source: "Area * 1.1")
        )
        #expect(throws: Never.self) { try valid.validate() }
    }

    @Test("BH-482/BH-483: the frozen ledger and formula documents list one kind set and one predicate set")
    func frozenTablesAgreeWithTheEnums() throws {
        // Old state: `customColumnKinds` was seven literal rows beside an `allCases` enumeration,
        // and `operatorNote` ended in `default: "predicate"` beside a table printing `isPredicate`.
        let ledger = try document("LEDGER_CONTRACT")
        let table = try #require(ledger.tables.first { $0.name == "customColumnKinds" })
        #expect(table.rows.map { $0[0] } == ColumnKind.allCases.map(\.rawValue))
        let kinds = try #require(ledger.types.first { $0.name == "ColumnKind" })
        #expect(kinds.cases.map(\.name) == table.rows.map { $0[0] })
        #expect(table.rows.allSatisfy { !$0[1].isEmpty })

        let formula = try document("FORMULA_CONTRACT")
        let operators = try #require(formula.types.first { $0.name == "FormulaOperator" })
        let operatorTable = try #require(formula.tables.first { $0.name == "operators" })
        let predicateColumn = try #require(operatorTable.columns.firstIndex(of: "predicate"))
        let notes = Dictionary(uniqueKeysWithValues: operators.cases.map { ($0.rawValue ?? $0.name, $0.note ?? "") })
        #expect(operatorTable.rows.count == FormulaOperator.allCases.count)
        for row in operatorTable.rows {
            let note = try #require(notes[row[0]], "operator \(row[0]) is in the table but not the enumeration")
            #expect((note == "predicate") == (row[predicateColumn] == "true"), "operator \(row[0])")
        }
    }
}

// MARK: - Measurement parameters

@Suite("Fix 2 — measurement parameters (ADR-0016)")
struct Fix2MeasurementParameterTests {

    @Test("BH-018: a negative depth or height is refused by validate(); a stored one still decodes")
    func negativeParameterIsRefused() throws {
        // Old output: validate() passed a depth of -0.2 m, VolumeCalculator multiplied
        // 10 m² x -0.2 m = -2 m³ and stored it as a value that subtracted from every total.
        let negativeDepth = MeasurementParameters(depth: .length(Decimal(string: "-0.2")!))
        #expect(throws: MeasurementError.negativeParameter(.depth)) { try negativeDepth.validate() }
        #expect(throws: MeasurementError.negativeParameter(.height)) {
            try MeasurementParameters(height: .length(-3)).validate()
        }
        #expect(throws: MeasurementError.negativeParameter(.heightAtEnd)) {
            try MeasurementParameters(height: .length(3), heightAtEnd: .length(-1)).validate()
        }
        #expect(throws: MeasurementError.negativeParameter(.depth)) {
            try MeasurementParameters(depth: .length(.nan)).validate()
        }
        // Zero is a legitimate zero; positive values pass as before.
        #expect(throws: Never.self) { try MeasurementParameters(depth: .length(0)).validate() }
        #expect(throws: Never.self) {
            try MeasurementParameters(
                depth: .length(Decimal(string: "0.2")!), height: .length(3), heightAtEnd: .length(2)
            ).validate()
        }
        // The dimension check comes first and is unchanged.
        #expect(throws: UnitConversionError.dimensionMismatch(expected: .length, actual: .area)) {
            try MeasurementParameters(depth: .area(-1)).validate()
        }
        // Decoding is not validation: a stored record with such a value still reads, and
        // fails only when it is recomputed.
        let data = try JSONEncoder().encode(negativeDepth)
        let decoded = try JSONDecoder().decode(MeasurementParameters.self, from: data)
        #expect(decoded == negativeDepth)
        #expect(decoded.depth?.value == Decimal(string: "-0.2"))

        // The frozen measurement document carries the rule.
        let measurement = try document("MEASUREMENT_CONTRACT")
        let parameters = try #require(measurement.types.first { $0.name == "MeasurementParameters" })
        #expect(parameters.invariants.contains { $0.contains("negativeParameter") && $0.contains("ADR-0016") })
    }
}

// MARK: - Dimensional algebra

@Suite("Fix 2 — dimensional algebra")
struct Fix2DimensionTests {

    @Test("BH-128: count and ratio order one way, so the comparator is a strict weak ordering")
    func countAndRatioAreComparable() {
        let count = DecimalQuantity.count(5)
        let ratio = DecimalQuantity.ratio(3)
        // Old output: `count < ratio` and `ratio < count` were both false while `count != ratio`,
        // so LedgerOrdering.compareQuantities answered .orderedDescending in both directions.
        #expect(count < ratio)
        #expect(!(ratio < count))
        #expect(count != ratio)
        // A mixed column sorts the same from any input order. Hand-derived: counts first (the
        // tag sorts after), each by value: [count 2, count 5, ratio 1, ratio 3].
        let shuffled: [DecimalQuantity] = [.ratio(3), .count(5), .ratio(1), .count(2)]
        let reversed: [DecimalQuantity] = [.count(2), .ratio(1), .count(5), .ratio(3)].reversed()
        let expected: [DecimalQuantity] = [.count(2), .count(5), .ratio(1), .ratio(3)]
        #expect(shuffled.sorted() == expected)
        #expect(reversed.sorted() == expected)
        // The earlier tie-breaks are unchanged: length power first, then angle, then currency.
        #expect(DecimalQuantity.count(9) < .length(1))
        #expect(DecimalQuantity.length(9) < .area(1))
        #expect(DecimalQuantity.ratio(9) < .length(1))
    }

    @Test("BH-493: an empty sum with no dimension is refused rather than minted as a count")
    func emptySumWithoutDimension() throws {
        // Old output: `DecimalQuantity(value: 0, dimension: .count)`, and the next `.adding(area)`
        // on that total threw incompatibleDimensions(count, area) for a group that was merely empty.
        #expect(throws: DimensionError.emptySumHasNoDimension) { _ = try DecimalQuantity.sum([]) }
        let zero = try DecimalQuantity.sum([], dimension: .area)
        #expect(zero == DecimalQuantity(value: 0, dimension: .area))
        #expect(try zero.adding(.area(5)).value == 5)
        // A non-empty sum is unchanged: 2 + 3 = 5 m².
        #expect(try DecimalQuantity.sum([.area(2), .area(3)]) == .area(5))
        #expect(throws: DimensionError.self) { _ = try DecimalQuantity.sum([.area(2)], dimension: .length) }
    }

    @Test("BH-494: money times a length power prints as a product, not as a rate with a negative exponent")
    func currencyTimesLengthSymbol() throws {
        // Old output: "SEK/m^-1" for SEK x m and "SEK/m^-2" for SEK x m², through
        // FormulaEngineError's "unit price (...)" text and the export unit column.
        let price = QuantityDimension.currency("SEK")
        #expect(try price.multiplied(by: .length).baseUnitSymbol == "SEK*m")
        #expect(try price.multiplied(by: .area).baseUnitSymbol == "SEK*m^2")
        // Rates are unchanged.
        #expect(try price.divided(by: .length).baseUnitSymbol == "SEK/m^1")
        #expect(try price.divided(by: .area).baseUnitSymbol == "SEK/m^2")
        #expect(price.baseUnitSymbol == "SEK")
    }
}

// MARK: - Units

@Suite("Fix 2 — units")
struct Fix2UnitTests {

    @Test("BH-500: every unit of every family has a conversion factor; none falls back to 1")
    func conversionTablesAreComplete() {
        // Old state: `factorToBase` returned 1 for a case missing from the dictionary, so a
        // new unit converted as if it were already the base unit, and nothing checked the table.
        #expect(LengthUnit.casesWithoutConversionFactor.isEmpty)
        #expect(AreaUnit.casesWithoutConversionFactor.isEmpty)
        #expect(VolumeUnit.casesWithoutConversionFactor.isEmpty)
        #expect(AngleUnit.casesWithoutConversionFactor.isEmpty)
        // And no listed factor is the silent fallback by accident, except the base unit itself.
        #expect(LengthUnit.metre.factorToBase == 1)
        #expect(LengthUnit.allCases.filter { $0.factorToBase == 1 } == [.metre])
    }
}

// MARK: - Slope expression

@Suite("Fix 2 — slope expression")
struct Fix2SlopeExpressionTests {

    @Test("BH-495: degrees outside the open interval (-90, 90) are refused, not passed to tan()")
    func degreesRange() throws {
        // Old output: ratio() of .degrees(270) was tan(270°) in Double ≈ 5.4e15 (finite), of
        // 90.5 ≈ -114, and trueLengthFactor() stretched a 10 m plan length accordingly.
        for value in [270, 450, 90, -90, Decimal(string: "90.5")!, Decimal(string: "-90.5")!] as [Decimal] {
            #expect(throws: SlopeError.degreesOutOfRange(value)) {
                _ = try SlopeExpression.degrees(value).ratio()
            }
            #expect(throws: SlopeError.degreesOutOfRange(value)) {
                _ = try SlopeExpression.degrees(value).trueLengthFactor()
            }
        }
        // Inside the interval: tan(45°) = 1 and tan(-45°) = -1, to the numeric policy.
        let tolerance = Decimal(string: "1e-12")!
        #expect(abs(try SlopeExpression.degrees(45).ratio() - 1) < tolerance)
        #expect(abs(try SlopeExpression.degrees(-45).ratio() + 1) < tolerance)
        #expect(try SlopeExpression.degrees(0).ratio() == 0)
    }

    @Test("BH-496: a number in a unit the grammar does not know is refused, not read as a bare ratio")
    func unknownUnitIsRefused() throws {
        // Old output: .decimalRatio(45) for "45º" (U+00BA ordinal indicator), .decimalRatio(45)
        // for "45 grader", .decimalRatio(50) for "50 percent" — a 4500 % slope stored silently.
        for text in ["45\u{00BA}", "45 grader", "50 percent", "45 \u{00B0}c", "1.5 mm", "6:12 pitch"] {
            #expect(throws: SlopeError.unparsableSlopeText(text)) { _ = try SlopeExpression.parse(text) }
        }
        // Every documented form still reads (ADR-0004 §3).
        #expect(try SlopeExpression.parse("45\u{00B0}") == .degrees(45))
        #expect(try SlopeExpression.parse("26.57 deg") == .degrees(Decimal(string: "26.57")!))
        #expect(try SlopeExpression.parse("30 degrees") == .degrees(30))
        #expect(try SlopeExpression.parse("50%") == .percent(50))
        #expect(try SlopeExpression.parse("50 %") == .percent(50))
        #expect(try SlopeExpression.parse("6:12") == .riseOverRun(rise: 6, run: 12))
        #expect(try SlopeExpression.parse("1/2") == .riseOverRun(rise: 1, run: 2))
        #expect(try SlopeExpression.parse("Rise 1.5 m over run 3 m")
                == .riseOverRun(rise: Decimal(string: "1.5")!, run: 3))
        #expect(try SlopeExpression.parse("0.5") == .decimalRatio(Decimal(string: "0.5")!))
        #expect(try SlopeExpression.parse("6", pitchDefaultRun: 12) == .riseOverRun(rise: 6, run: 12))
    }

    @Test("BH-497: a malformed literal is refused, not prefix-parsed")
    func malformedLiteralIsRefused() throws {
        // Old output: parse("1.2.5") == .decimalRatio(1.2) and parse("6:12.5.5") == 6:12.5,
        // because Decimal(string:) reads the longest valid prefix and the rest was dropped.
        for text in ["1.2.5", "6:12.5.5", "1..5%", ".", "2\u{00B2}"] {
            #expect(throws: SlopeError.unparsableSlopeText(text)) { _ = try SlopeExpression.parse(text) }
        }
        #expect(SlopeExpression.decimalTokens(in: "1.2.5") == nil)
        #expect(SlopeExpression.decimalTokens(in: "1.25 and 3") == [Decimal(string: "1.25")!, 3])
        #expect(SlopeExpression.decimalTokens(in: ".5 : 1.") == [Decimal(string: "0.5")!, 1])
    }

    @Test("BH-498: a sign separated from its digits keeps its sign; the Unicode minus is a minus")
    func detachedSignIsKept() throws {
        // Old output: parse("- 5%") == .percent(5) — the space flushed a lone "-" which flush()
        // discarded — and parse("−6:12") == 6:12 because U+2212 was treated as a separator.
        #expect(try SlopeExpression.parse("- 5%") == .percent(-5))
        #expect(try SlopeExpression.parse("-5%") == .percent(-5))
        #expect(try SlopeExpression.parse("\u{2212}6:12") == .riseOverRun(rise: -6, run: 12))
        #expect(try SlopeExpression.parse("\u{2212} 6:12") == .riseOverRun(rise: -6, run: 12))
        #expect(try SlopeExpression.parse("6:-12") == .riseOverRun(rise: 6, run: -12))
        #expect(try SlopeExpression.parse("+5%") == .percent(5))
        // A sign with nothing after it, or with a unit between it and the digits, is malformed.
        for text in ["-", "- %", "-%5", "--5%", "5 -%"] {
            #expect(throws: SlopeError.unparsableSlopeText(text)) { _ = try SlopeExpression.parse(text) }
        }
    }

    @Test("BH-499: a stored azimuth decodes through normalisation, on the same wire format")
    func azimuthDecodeNormalises() throws {
        // Old output: `degrees == 450` after decoding (the synthesized init assigned it
        // directly), `direction` missed the exact axis case (cos 450° = 6e-17, not 0) and
        // `opposite` showed 270 while the value itself showed 450.
        let decoded = try JSONDecoder().decode(SlopeAzimuth.self, from: Data(#"{"degrees":450}"#.utf8))
        #expect(decoded.degrees == 90)
        #expect(decoded == SlopeAzimuth(degrees: 90))
        #expect(decoded.direction == PlanarDirection(x: 0, y: 1))
        let negative = try JSONDecoder().decode(SlopeAzimuth.self, from: Data(#"{"degrees":-90}"#.utf8))
        #expect(negative.degrees == 270)
        #expect(negative.opposite.degrees == 90)
        // The wire format is the synthesized one, byte for byte.
        let encoded = try JSONEncoder().encode(SlopeAzimuth(degrees: 90))
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"degrees":90}"#)
        #expect(try JSONDecoder().decode(SlopeAzimuth.self, from: encoded) == SlopeAzimuth(degrees: 90))
    }
}

// MARK: - Scale contract

@Suite("Fix 2 — scale contract (ADR-0017)")
struct Fix2ScaleContractTests {

    @Test("BH-491: a stored precision is validated when decoded; the wire format is unchanged")
    func precisionDecodeValidates() throws {
        // Old output: `decimalPlaces(-2)` decoded untouched — only tests called validate() —
        // and reached NSDecimalRound, showing 384.2 m² as "400"; 40 places passed the same way.
        let encoded = try JSONEncoder().encode(PrecisionMode.decimalPlaces(3))
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"decimalPlaces":{"_0":3}}"#)
        #expect(try JSONDecoder().decode(PrecisionMode.self, from: encoded) == .decimalPlaces(3))
        for places in [-2, 13, 40] {
            let stored = Data(#"{"decimalPlaces":{"_0":\#(places)}}"#.utf8)
            #expect(throws: DecodingError.self, "\(places) places") {
                _ = try JSONDecoder().decode(PrecisionMode.self, from: stored)
            }
        }
        let imperial = try JSONEncoder().encode(PrecisionMode.imperialFraction(.eighth))
        #expect(String(decoding: imperial, as: UTF8.self) == #"{"imperialFraction":{"_0":8}}"#)
        #expect(try JSONDecoder().decode(PrecisionMode.self, from: imperial) == .imperialFraction(.eighth))
        #expect(PrecisionMode.decimalPlacesRange == 0...12)
        let scale = try document("SCALE_CONTRACT")
        let precision = try #require(scale.types.first { $0.name == "PrecisionMode" })
        #expect(precision.invariants.contains { $0.contains("init(from:)") && $0.contains("ADR-0017") })
    }

    @Test("BH-484: the calibration floor the freeze prints is the one the code enforces")
    func calibrationFloorIsReadFromTheCode() throws {
        // Old state: the scaleGuards row hard-coded "4 PDF points" while the floor lived only
        // as a default parameter, so the two could drift with no test between them.
        let scale = try document("SCALE_CONTRACT")
        let guards = try #require(scale.tables.first { $0.name == "scaleGuards" })
        let row = try #require(guards.rows.first { $0[0] == "minimum two-point calibration distance" })
        #expect(row[1] == "\(ContractNumberText.text(ScaleTransform.minimumCalibrationPDFDistance)) PDF points")
        #expect(row[1] == "4 PDF points")

        // 3.9 points apart is under the floor; 4.0 is on it and accepted.
        let id = ScaleID(uuid(3))
        #expect(throws: ScaleError.calibrationPointsTooClose(pdfDistance: 3.9)) {
            _ = try ScaleTransform.calibratedTwoPoint(
                id: id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 3.9, y: 0),
                knownLength: 1, knownLengthUnit: .metre, units: .metric
            )
        }
        let accepted = try ScaleTransform.calibratedTwoPoint(
            id: id, first: PDFPoint(x: 0, y: 0), second: PDFPoint(x: 4, y: 0),
            knownLength: 1, knownLengthUnit: .metre, units: .metric
        )
        // 1 m over 4 points = 0.25 m per point.
        #expect(accepted.matrix.a == Decimal(string: "0.25"))
        #expect(accepted.matrix.metresPerPointX == 0.25)
    }
}

// MARK: - Markup contract

@Suite("Fix 2 — markup contract")
struct Fix2MarkupContractTests {

    @Test("BH-490: a measurement taken under another scale is stale")
    func staleUnderAnotherScale() throws {
        let scaleR = ScaleID(uuid(4))
        let scaleP = ScaleID(uuid(5))
        let current = try ScaleTransform.uniform(
            id: scaleP, metresPerPoint: Decimal(string: "0.01")!, units: .metric, source: .preset
        )
        let rVersion2 = try ScaleTransform.uniform(
            id: scaleR, version: 2, metresPerPoint: Decimal(string: "0.01")!, units: .metric, source: .preset
        )
        func record(scaleID: ScaleID?, version: Int?, measured: Bool) -> MarkupRecord {
            MarkupRecord(
                id: MarkupID(uuid(6)), documentID: DocumentID(uuid(7)), pageID: PageID(uuid(8)),
                kind: .measurement, tool: .area,
                scaleID: scaleID, scaleVersion: version,
                measurement: measured ? MeasurementResult(values: [.netArea: .area(50)]) : nil,
                createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0)
            )
        }
        // Old output: `false` — the id mismatch returned "not stale" and the one caller was
        // safe only because it compared the ids itself first.
        #expect(record(scaleID: scaleR, version: 1, measured: true).isMeasurementStale(against: current))
        // Unchanged: a record with no scale id claims no scale and cannot be stale against one.
        #expect(!record(scaleID: nil, version: nil, measured: true).isMeasurementStale(against: current))
        // Unchanged version path: same id, version 1 against version 2 is stale; 2 against 2 is not.
        #expect(record(scaleID: scaleR, version: 1, measured: true).isMeasurementStale(against: rVersion2))
        #expect(!record(scaleID: scaleR, version: 2, measured: true).isMeasurementStale(against: rVersion2))
        // Same id, no version: stale only when a measurement is present.
        #expect(record(scaleID: scaleR, version: nil, measured: true).isMeasurementStale(against: rVersion2))
        #expect(!record(scaleID: scaleR, version: nil, measured: false).isMeasurementStale(against: rVersion2))
    }
}

// MARK: - Artwork contract

@Suite("Fix 2 — artwork contract")
struct Fix2ArtworkContractTests {

    private func artwork(width: Double) -> ArtworkGeometry {
        ArtworkGeometry(
            kind: .vector,
            strokes: [ArtworkContour(
                points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 1)], widthFraction: width
            )]
        )
    }

    @Test("BH-127: a stroke width that is not a bounded fraction is refused on the way in and out")
    func strokeWidthIsBounded() throws {
        // Old output: limitViolation() == nil for widthFraction 1e12, +inf, NaN and -0.1; the two
        // AppKit painters then multiplied the number straight into setLineWidth.
        let limit = ArtworkLimits.maximumStrokeWidthFraction
        #expect(limit == 1)
        #expect(artwork(width: 1e12).limitViolation() == .invalidStrokeWidth(found: 1e12, limit: limit))
        #expect(artwork(width: .infinity).limitViolation() == .invalidStrokeWidth(found: .infinity, limit: limit))
        #expect(artwork(width: -0.1).limitViolation() == .invalidStrokeWidth(found: -0.1, limit: limit))
        #expect(artwork(width: 1.0001).limitViolation() == .invalidStrokeWidth(found: 1.0001, limit: limit))
        guard case .invalidStrokeWidth? = artwork(width: .nan).limitViolation() else {
            Issue.record("a NaN stroke width must be refused as a stroke width")
            return
        }
        // Everything a compiler produces passes: 0 (renderer default), the importer's 0.5
        // clamp, and the limit itself.
        for width in [0, 0.01, 0.5, 1] as [Double] {
            #expect(artwork(width: width).limitViolation() == nil, "width \(width)")
        }
        // What is read back is checked by the same function.
        let decoded = try JSONDecoder().decode(
            ArtworkGeometry.self, from: JSONEncoder().encode(artwork(width: 1e12))
        )
        #expect(decoded.limitViolation() == .invalidStrokeWidth(found: 1e12, limit: limit))
        #expect(!decoded.isWellFormed)
        #expect(ArtworkImportRefusal.invalidStrokeWidth(found: 1e12, limit: limit).reason.contains("limit is 1"))
    }

    @Test("BH-479: each thing wrong with the geometry is named as itself")
    func wellFormednessViolationsAreNamed() {
        // Old output: `.nonFiniteGeometry` for all three — an out-of-box coordinate, a bad
        // aspect ratio and a real NaN — and its sentence was shown verbatim to the person.
        let outside = ArtworkGeometry(
            kind: .vector,
            strokes: [ArtworkContour(points: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1.5, y: 1)])]
        )
        #expect(outside.wellFormednessViolation == .coordinateOutsideUnitBox)
        #expect(outside.limitViolation() == .coordinateOutsideUnitBox)
        let noArea = ArtworkGeometry(kind: .vector, sourceAspectRatio: 0)
        #expect(noArea.wellFormednessViolation == .degenerateBounds)
        let infiniteAspect = ArtworkGeometry(kind: .vector, sourceAspectRatio: .infinity)
        #expect(infiniteAspect.wellFormednessViolation == .degenerateBounds)
        let notANumber = ArtworkGeometry(
            kind: .vector,
            regions: [ArtworkRegion(outer: [PDFPoint(x: 0, y: .nan), PDFPoint(x: 1, y: 1)])]
        )
        #expect(notANumber.wellFormednessViolation == .nonFiniteGeometry)
        // A hole is checked like an outer ring.
        let holeOutside = ArtworkGeometry(
            kind: .vector,
            regions: [ArtworkRegion(
                outer: [PDFPoint(x: 0, y: 0), PDFPoint(x: 1, y: 0), PDFPoint(x: 1, y: 1)],
                holes: [[PDFPoint(x: 0.2, y: 0.2), PDFPoint(x: -3, y: 0.2)]]
            )]
        )
        #expect(holeOutside.wellFormednessViolation == .coordinateOutsideUnitBox)
        // The compiler's rounding slack is kept: 1.0001 is inside, 1.001 is not.
        let slack = ArtworkGeometry(
            kind: .vector,
            strokes: [ArtworkContour(points: [PDFPoint(x: -0.0001, y: 0), PDFPoint(x: 1.0001, y: 1)])]
        )
        #expect(slack.wellFormednessViolation == nil)
        #expect(slack.isWellFormed)
        // Each refusal has its own sentence, and the two new ones do not mention a non-finite number.
        #expect(ArtworkImportRefusal.coordinateOutsideUnitBox.reason.contains("outside"))
        #expect(!ArtworkImportRefusal.coordinateOutsideUnitBox.reason.contains("finite"))
    }

    @Test("BH-480: artwork with a digest but an unknown kind is not promised to stay sharp")
    func unknownKindIsNotSharp() {
        // Old output: `true` — staysSharpWhenMagnified read `kind` (`.none` answers true) while
        // usesImportedArtwork read the digest, so a raster mosaic whose artwork_kind failed to
        // parse was reported crisp by the legend.
        let unknown = MarkupSymbol(artworkDigest: "sha256:abc", kind: .none)
        #expect(unknown.usesImportedArtwork)
        #expect(!unknown.staysSharpWhenMagnified)
        #expect(MarkupSymbol(artworkDigest: "sha256:abc", kind: .vector).staysSharpWhenMagnified)
        #expect(!MarkupSymbol(artworkDigest: "sha256:abc", kind: .raster).staysSharpWhenMagnified)
        // A built-in glyph is vector and always crisp.
        #expect(MarkupSymbol.builtIn("circle").staysSharpWhenMagnified)
        #expect(!MarkupSymbol.builtIn("circle").usesImportedArtwork)
    }
}

// MARK: - Snap contract

@Suite("Fix 2 — snap contract")
struct Fix2SnapContractTests {

    @Test("BH-492: every snap kind states whether a scanned sheet can offer it")
    func requiresVectorContentIsExhaustive() {
        // Old state: `default: true`, so a new kind was vector-only without a compile error and
        // the target generator dropped it on every scanned page.
        let scannedSheetKinds: Set<SnapKind> = [
            .grid, .angleIncrement, .markupVertex, .markupEdge, .markupCenter,
            .zoneBoundary, .calibrationPoint, .parallelGuide
        ]
        let vectorKinds: Set<SnapKind> = [
            .endpoint, .midpoint, .intersection, .nearestPointOnSegment,
            .perpendicularProjection, .center, .quadrant, .tangent, .pdfVectorContent
        ]
        #expect(scannedSheetKinds.union(vectorKinds) == Set(SnapKind.allCases))
        #expect(scannedSheetKinds.isDisjoint(with: vectorKinds))
        for kind in SnapKind.allCases {
            #expect(kind.requiresVectorContent == vectorKinds.contains(kind), "\(kind)")
        }
    }

    @Test("BH-485/BH-486: the frozen snap document names the extractor and prints the radii in full")
    func snapDocumentIsAboutThisProgram() throws {
        let snap = try document("SNAP_CONTRACT")
        // BH-485 old state: sourceObjectID was "the PDFium page-object id", a producer this
        // program does not contain.
        let field = try #require(snap.types.flatMap(\.fields).first { $0.name == "sourceObjectID" })
        #expect(field.invariant?.contains("CGPDFScanner") == true)
        // No field of any frozen document binds its meaning to that library (the architecture
        // freeze may still say that page geometry never leaks such a type).
        let bindings = try ContractCatalog.allDocuments(frozenAt: frozenAt)
            .flatMap(\.types).flatMap(\.fields)
            .compactMap { field in field.invariant.map { "\(field.name): \($0)" } }
        #expect(bindings.allSatisfy { !$0.contains("PDFium") }, "\(bindings.filter { $0.contains("PDFium") })")
        // BH-486 old state: String(Int(value)) — 4.5 would have frozen as "4".
        let radii = try #require(snap.tables.first { $0.name == "snapRadiusDefaults" })
        let rows = Dictionary(uniqueKeysWithValues: radii.rows.map { ($0[0], $0[1]) })
        #expect(rows["defaultPixels"] == ContractNumberText.text(SnapSettings.specDefaultPixels))
        #expect(rows["hysteresisPixels"] == ContractNumberText.text(SnapSettings.specHysteresisPixels))
        #expect(rows["defaultPixels"] == "10")
    }
}

// MARK: - Freeze generator

@Suite("Fix 2 — freeze generator")
struct Fix2FreezeGeneratorTests {

    @Test("BH-486: frozen numbers are printed as the code holds them")
    func numbersPrintInFull() {
        // Old output: String(Int(4.5)) == "4"; Int(.infinity) traps.
        #expect(ContractNumberText.text(4.5) == "4.5")
        #expect(ContractNumberText.text(10) == "10")
        #expect(ContractNumberText.text(0) == "0")
        #expect(ContractNumberText.text(-0.25) == "-0.25")
        #expect(ContractNumberText.text(20_000) == "20000")
        #expect(ContractNumberText.text(.infinity) == "inf")
        #expect(ContractNumberText.text(.nan) == "nan")
        #expect(ContractNumberText.range(0...12) == "0...12")
        #expect(ContractNumberText.range(-3...3) == "-3...3")
        #expect(ContractNumberText.range(1, 20_000) == "1...20000")
    }

    @Test("BH-487: module qualifiers are stripped at identifier boundaries")
    func moduleStrippingRespectsIdentifierBoundaries() {
        // Old output: "CoreCGFloat" — a substring replace of "Foundation." ate the tail of
        // "CoreFoundation.CGFloat", the spelling String(reflecting:) gives CGFloat on Darwin.
        #expect(ContractTypeNaming.sugaredName(ofReflected: "CoreFoundation.CGFloat") == "CGFloat")
        #expect(ContractTypeNaming.sugaredName(ofReflected: "Swift.Optional<CoreFoundation.CGFloat>") == "CGFloat?")
        #expect(ContractTypeNaming.sugaredName(ofReflected: "Swift.Array<ZPDFContracts.PDFPoint>") == "[PDFPoint]")
        #expect(ContractTypeNaming.sugaredName(ofReflected: "Swift.Dictionary<Swift.String, Foundation.NSDecimal>")
                == "[String: Decimal]")
        // A module that merely ends in a stripped name is not touched.
        #expect(ContractTypeNaming.sugaredName(ofReflected: "MySwift.Thing") == "MySwift.Thing")
        // And the live value, whichever module Darwin reports it under.
        #expect(ContractTypeNaming.sugaredName(of: CGFloat(1)) == "CGFloat")
    }

    @Test("BH-481: the frozen PageRotation invariant states what normalizing(degrees:) does")
    func pageRotationInvariantMatchesTheCode() throws {
        // Old state: "any other value is a typed error, never a silent normalisation", while
        // normalizing(degrees: 450) returned .degrees90 and -90 returned .degrees270.
        let architecture = try document("ARCHITECTURE_FREEZE")
        let rotation = try #require(architecture.types.first { $0.name == "PageRotation" })
        #expect(rotation.invariants.contains { $0.contains("-90 is 270, 450 is 90") })
        #expect(!rotation.invariants.contains { $0.contains("never a silent normalisation") })
        #expect(try PageRotation.normalizing(degrees: -90) == .degrees270)
        #expect(try PageRotation.normalizing(degrees: 450) == .degrees90)
        #expect(throws: PageGeometryError.unsupportedRotation(45)) {
            _ = try PageRotation.normalizing(degrees: 45)
        }
    }
}
