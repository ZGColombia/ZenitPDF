import Foundation

extension ContractCatalog {

    // MARK: - Unit tables

    /// The exact conversion factors, printed from the live `conversionFactors` dictionaries so
    /// the JSON can never disagree with the code.
    static func unitTable<Unit: DisplayUnit>(
        _ type: Unit.Type,
        name: String,
        baseSymbol: String
    ) -> ContractTable {
        let rows = Unit.allCases
            .map { unit -> [String] in
                [
                    unit.rawValue,
                    unit.symbol,
                    unit.factorToBase.description,
                    unit.isExactByDefinition ? "exact" : "approximate"
                ]
            }
            .sorted { $0[0] < $1[0] }
        return ContractTable(
            name: name,
            columns: ["case", "symbol", "factorTo_\(baseSymbol)", "exactness"],
            rows: rows
        )
    }

    // MARK: - ARCHITECTURE_FREEZE

    static func architectureFreeze(frozenAt: String) throws -> ContractDocument {
        var types: [ContractTypeDescription] = []

        types.append(ContractTypeDescription(
            name: "ContractIdentifier",
            kind: "protocol",
            summary: """
                UUID-backed identity for every persisted entity. Conformers encode as a single \
                JSON string and can be used directly as Codable dictionary keys.
                """,
            cases: [
                "DocumentID", "PageID", "MarkupID", "LayerID", "ZoneID", "ScaleID",
                "ScaleRegionID", "ColumnID", "RowID", "ChoiceOptionID", "CountGroupID",
                "CountPointID", "SymbolID"
            ].map { ContractCaseDescription(name: $0, rawValue: "UUID", note: "conforming type") },
            invariants: [
                "An identifier is minted by an injected IdentifierGenerating, never by UUID() inside a calculation.",
                "Encoded form is the uppercase UUID string, single-value encoded.",
                "Identifiers are never reused after a delete."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.point,
            name: "PDFPoint",
            summary: "A point in canonical PDF page space.",
            annotations: [
                "x": .init("PDF point (1/72 in)", "finite; measured from the page box left edge"),
                "y": .init("PDF point (1/72 in)", "finite; measured upwards from the page box bottom edge")
            ],
            invariants: [
                "Origin is bottom-left; y increases upwards.",
                "Never carries zoom, scroll offset or screen backing scale."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.size,
            name: "PDFSize",
            summary: "A size in PDF points.",
            annotations: [
                "width": .init("PDF point", "finite"),
                "height": .init("PDF point", "finite")
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.rect,
            name: "PDFRect",
            summary: "An axis-aligned rectangle in PDF page space, bottom-left origin.",
            annotations: [
                "origin": .init("PDF point", "finite"),
                "size": .init("PDF point", "may be negative as stored; `standardized` is the canonical form")
            ],
            invariants: [
                "Comparisons and containment always use the standardized form.",
                "PDFRect is used wherever the spec sketches CGRect for page-space geometry; CGRect is a view-space type."
            ]
        ))

        types.append(.enumeration(
            PageRotation.self,
            name: "PageRotation",
            summary: "The PDF /Rotate entry.",
            invariants: [
                "Only 0, 90, 180 and 270 exist. normalizing(degrees:) folds any multiple of 90 into them (-90 is 270, 450 is 90, as PDF readers treat /Rotate) and refuses a value that is not a multiple of 90 with a typed error; nothing else is ever normalised.",
                "90 and 270 swap the displayed width and height (`swapsAxes`)."
            ],
            note: { $0.swapsAxes ? "swaps axes" : "keeps axes" }
        ))

        types.append(try .reflecting(
            ContractSamples.boxes,
            name: "PageBoxes",
            summary: "The media and crop boxes of one page.",
            annotations: [
                "media": .init("PDF point", "positive extents; finite"),
                "crop": .init("PDF point", "positive extents; must be contained by media")
            ],
            invariants: [
                "crop is contained by media, or validate() throws cropBoxOutsideMediaBox.",
                "A file without /CropBox has crop == media, substituted by the importer."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.pageDescriptor,
            name: "PageDescriptor",
            summary: "Everything the engine needs to know about one page's geometry.",
            annotations: [
                "id": .init("-", "stable across sessions"),
                "documentID": .init("-", "owning document"),
                "index": .init("-", "zero-based index of the page in its own PDF (its /Pages order), fixed at import; the page's place in a set is the set order, persisted as page_set_entry.position (ADR-0022)"),
                "label": .init("-", "the PDF /PageLabels value, which is frequently not String(index + 1)"),
                "boxes": .init("PDF point", "validated by PageBoxes.validate()"),
                "rotation": .init("degrees", "multiple of 90"),
                "userUnit": .init("multiplier on 1/72 in", "finite and strictly positive; a preset drawing ratio multiplies its metres-per-point by it (ScaleTransform.preset), and a calibration carries it implicitly because the calibration points live in the same user space as the content")
            ],
            invariants: [
                "Page geometry never leaks a PDFKit or PDFium type.",
                "The ledger shows `label`, never the raw index, unless explicitly asked.",
                "Reordering pages never rewrites `index`: rendering, text, OCR, vector extraction and stored page identity all key on it (ADR-0022)."
            ]
        ))

        types.append(ContractTypeDescription(
            name: "PageCoordinateConverting",
            kind: "protocol",
            summary: "The only bridge between view coordinates and page space (spec 9.2).",
            cases: [
                ContractCaseDescription(
                    name: "viewToPage(_:pageID:)",
                    rawValue: "(CGPoint, PageID) throws -> PDFPoint"
                ),
                ContractCaseDescription(
                    name: "pageToView(_:pageID:)",
                    rawValue: "(PDFPoint, PageID) throws -> CGPoint"
                ),
                ContractCaseDescription(
                    name: "screenToleranceToPage(pixels:pageID:)",
                    rawValue: "(CGFloat, PageID) throws -> CGFloat"
                )
            ],
            invariants: [
                "The measurement engine never sees a screen pixel or a zoom value.",
                "An unknown page is CoordinateError.unknownPage, never a guess.",
                "Screen tolerances are re-converted on every event, because zoom can change between events."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.dimension,
            name: "QuantityDimension",
            summary: "The dimension of a quantity: a length power, an angle flag, an optional currency, and a ratio tag for the dimensionless case (ADR-0014).",
            annotations: [
                "lengthPower": .init("-", "\(ContractNumberText.range(QuantityDimension.supportedLengthPowers)); 0 count, 1 length, 2 area, 3 volume"),
                "angle": .init("-", "true means the value is in radians"),
                "currencyCode": .init("ISO 4217", "nil, or exactly three uppercase A-Z letters"),
                "ratio": .init("-", "true marks a dimensionless factor (slope ratio, percentage, waste factor) as distinct from a count; valid only when lengthPower == 0, angle == false and currencyCode == nil; encoded only when true, so a payload without the key is a count")
            ],
            invariants: [
                "Addition and subtraction require identical dimensions (spec 11.4).",
                "count and ratio are both dimensionless and never additive with each other: a slope ratio or a waste factor cannot sum into a count total (ADR-0014).",
                "A ratio is absorbed by any product (area x ratio = area, count x ratio = count); only ratio x ratio stays a ratio. A like-for-like quotient (m / m, SEK / SEK, count / count, ratio / ratio) is a ratio; count / ratio and ratio / count are counts (ADR-0014).",
                "angle x angle is rejected.",
                "money x money is rejected; money / same money cancels to a ratio.",
                "Dividing a non-money quantity by money is rejected."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.quantity,
            name: "DecimalQuantity",
            summary: "A dimensioned Decimal, always stored in the SI base unit of its dimension.",
            annotations: [
                "value": .init("SI base unit (m, m^2, m^3, rad, 1, currency major unit)", "never rounded in storage"),
                "dimension": .init("-", "names the SI base unit the value is in")
            ],
            invariants: [
                "Stored values carry no display rounding; PrecisionMode is applied at the view and export boundary only.",
                "+ and - throw DimensionError.incompatibleDimensions on a mismatch.",
                "* and / apply the QuantityDimension product and quotient rules.",
                "Division by a zero quantity throws DimensionError.divisionByZero."
            ]
        ))

        types.append(try .reflecting(
            ContractSamples.color,
            name: "RGBAColor",
            summary: "Device-independent sRGB colour with straight alpha. The contracts package owns its own colour type because it may not import AppKit or any ZPDFUI package.",
            annotations: [
                "red": .init("0...1", "finite"),
                "green": .init("0...1", "finite"),
                "blue": .init("0...1", "finite"),
                "alpha": .init("0...1", "finite; 0 is fully transparent")
            ]
        ))

        types.append(.enumeration(
            LengthUnit.self,
            name: "LengthUnit",
            summary: "Display units for length. SI base unit: metre.",
            invariants: [
                "1 in = 0.0254 m, 1 ft = 0.3048 m, 1 yd = 0.9144 m, 1 mi = 1609.344 m, exactly.",
                "Every factor is built from an integer significand and a power of ten; no factor is born from a binary floating-point literal."
            ],
            note: { "\($0.factorToBase.description) m" }
        ))

        types.append(.enumeration(
            AreaUnit.self,
            name: "AreaUnit",
            summary: "Display units for area. SI base unit: square metre.",
            invariants: [
                "1 acre = 4046.8564224 m^2 and 1 mi^2 = 2589988.110336 m^2, exactly.",
                "The squared imperial factors agree with LengthUnit squared: 1 ft^2 = 0.3048^2 m^2."
            ],
            note: { "\($0.factorToBase.description) m2" }
        ))

        types.append(.enumeration(
            VolumeUnit.self,
            name: "VolumeUnit",
            summary: "Display units for volume. SI base unit: cubic metre.",
            invariants: [
                "1 litre = 0.001 m^3 exactly.",
                "The cubed imperial factors agree with LengthUnit cubed: 1 ft^3 = 0.3048^3 m^3."
            ],
            note: { "\($0.factorToBase.description) m3" }
        ))

        types.append(.enumeration(
            AngleUnit.self,
            name: "AngleUnit",
            summary: "Display units for angle. SI base unit: radian.",
            invariants: [
                "Only the radian is exact. Degree, gradian and turn depend on pi and are recorded as approximate.",
                "The Decimal pi constant is a 37-decimal truncation assembled from two exact 19-digit chunks."
            ],
            note: { $0.isExactByDefinition ? "exact" : "approximate (pi)" }
        ))

        types.append(ContractTypeDescription(
            name: "SlopeExpression",
            kind: "enum",
            summary: "The six ways a slope is written down (spec 11.3, 12.8). All reduce to a dimensionless rise/run.",
            cases: [
                ContractCaseDescription(name: "ratioOneToN", rawValue: "Decimal", note: "1:n"),
                ContractCaseDescription(name: "ratioNToOne", rawValue: "Decimal", note: "n:1"),
                ContractCaseDescription(name: "decimalRatio", rawValue: "Decimal", note: "rise/run"),
                ContractCaseDescription(name: "percent", rawValue: "Decimal", note: "100 * rise/run"),
                ContractCaseDescription(name: "degrees", rawValue: "Decimal", note: "from horizontal"),
                ContractCaseDescription(name: "riseOverRun", rawValue: "(rise: Decimal, run: Decimal)", note: "same length unit on both terms")
            ],
            invariants: [
                "run == 0 is vertical and throws SlopeError.verticalSlopeUndefined; it never yields an infinity (spec 12.8).",
                "angleRadians() still answers for a vertical slope, because the angle is defined even when the ratio is not.",
                "trueLengthFactor() is sqrt(1 + ratio^2)."
            ]
        ))

        types.append(ContractTypeDescription(
            name: "NumericPolicy",
            kind: "enum",
            summary: "The single implementation of the spec 11.4 numeric policy.",
            cases: [
                ContractCaseDescription(name: "kahanSum(_:)", rawValue: "[Double] -> Double", note: "Kahan-Babuska-Neumaier"),
                ContractCaseDescription(name: "pairwiseSum(_:)", rawValue: "[Double] -> Double", note: "cascade, block size 8"),
                ContractCaseDescription(name: "sum(_:)", rawValue: "[Double] -> Double", note: "compensated at or above 64 terms"),
                ContractCaseDescription(name: "decimal(from:significantDigits:)", rawValue: "(Double, Int) throws -> Decimal", note: "default 15 significant digits"),
                ContractCaseDescription(name: "double(from:)", rawValue: "Decimal -> Double", note: "explicitly lossy"),
                ContractCaseDescription(name: "exact(_:_:)", rawValue: "(UInt64, Int) -> Decimal", note: "integer significand x power of ten"),
                ContractCaseDescription(name: "rounded(_:decimalPlaces:)", rawValue: "(Decimal, Int) -> Decimal", note: "view/export boundary only"),
                ContractCaseDescription(name: "roundedToFraction(_:denominator:)", rawValue: "(Decimal, Int) -> Decimal", note: "view/export boundary only")
            ],
            invariants: [
                "Geometry is Double; aggregates and money are Decimal.",
                "The Double -> Decimal crossing happens at a defined significance, never implicitly.",
                "NaN and infinity throw NumericError.nonFiniteValue rather than producing Decimal.nan.",
                "Sums of 64 or more Doubles use compensated summation before Decimal normalisation.",
                "There is no internal display rounding anywhere in the core packages."
            ]
        ))

        return ContractDocument(
            contract: "ARCHITECTURE_FREEZE",
            contractVersion: ContractVersion.architecture,
            frozenAt: frozenAt,
            generator: generatorName,
            specSections: ["9.1", "9.2", "9.3", "11.1", "11.2", "11.3", "11.4", "11.5"],
            summary: """
                The frozen vocabulary of Zenit PDF: identity, page geometry, the coordinate \
                boundary, dimensional algebra, units and the numeric policy. Every later package \
                compiles against these types.
                """,
            types: types,
            tables: [
                unitTable(LengthUnit.self, name: "lengthConversionFactors", baseSymbol: "m"),
                unitTable(AreaUnit.self, name: "areaConversionFactors", baseSymbol: "m2"),
                unitTable(VolumeUnit.self, name: "volumeConversionFactors", baseSymbol: "m3"),
                unitTable(AngleUnit.self, name: "angleConversionFactors", baseSymbol: "rad")
            ],
            invariants: [
                "ZPDFContracts has zero dependencies: no remote SwiftPM package, and no ZPDFUI* package. Dependency direction is UI -> core, never core -> UI.",
                "swift-tools-version:6.0, platforms [.macOS(.v14)], every target in Swift language mode 6.",
                "Everything crossing an API boundary is Sendable. There is no @unchecked Sendable in this package.",
                "Geometry is Double; aggregates and money are Decimal (spec 11.4).",
                "No internal display rounding. Rounding happens at the view and export boundary only.",
                "Incompatible dimensions are never added; the attempt is a typed DimensionError.",
                "Decimal overflow is a typed NumericError, never a NaN Decimal travelling on as a value.",
                "A dimension that decodes from persisted data is validated; the length power and any currency code must be in range.",
                "Large Double sums use Kahan-Babuska-Neumaier or pairwise summation before Decimal normalisation.",
                "No fatalError, no force-unwrap and no precondition on user data: every failure is a typed Swift error.",
                "Pure calculations are deterministic: no Date() and no UUID() inside them; clocks and id generators are injected via TimestampProviding and IdentifierGenerating.",
                "PDF page space is 72 dpi with a bottom-left origin, crop box by default, rotation explicit."
            ]
        )
    }
}
