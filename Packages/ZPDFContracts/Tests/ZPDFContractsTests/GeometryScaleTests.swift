import CoreGraphics
import Foundation
import Testing
@testable import ZPDFContracts

@Suite("Page geometry")
struct PageGeometryTests {

    @Test("Rotation normalises multiples of 90 and rejects everything else")
    func rotationNormalisation() throws {
        #expect(try PageRotation.normalizing(degrees: 450) == .degrees90)
        #expect(try PageRotation.normalizing(degrees: -90) == .degrees270)
        #expect(try PageRotation.normalizing(degrees: 720) == .degrees0)
        #expect(throws: PageGeometryError.unsupportedRotation(45)) {
            _ = try PageRotation.normalizing(degrees: 45)
        }
        #expect(PageRotation.degrees90.swapsAxes)
        #expect(PageRotation.degrees270.swapsAxes)
        #expect(!PageRotation.degrees180.swapsAxes)
        #expect(PageRotation.degrees90.inverse == .degrees270)
    }

    @Test("A rectangle stored with negative extents standardizes correctly")
    func negativeExtents() {
        let rect = PDFRect(x: 100, y: 100, width: -40, height: -20)
        #expect(rect.minX == 60)
        #expect(rect.minY == 80)
        #expect(rect.maxX == 100)
        #expect(rect.width == 40)
        #expect(rect.area == 800)
    }

    @Test("A crop box outside the media box is rejected")
    func cropBoxValidation() {
        let media = PDFRect(x: 0, y: 0, width: 595, height: 842)
        #expect(throws: Never.self) {
            try PageBoxes(media: media, crop: PDFRect(x: 10, y: 10, width: 100, height: 100)).validate()
        }
        #expect(throws: PageGeometryError.cropBoxOutsideMediaBox) {
            try PageBoxes(media: media, crop: PDFRect(x: -10, y: 0, width: 100, height: 100)).validate()
        }
        #expect(throws: PageGeometryError.degenerateBox(name: "crop")) {
            try PageBoxes(media: media, crop: PDFRect(x: 0, y: 0, width: 0, height: 100)).validate()
        }
    }

    @Test("A negative page-box origin is legal and preserved")
    func negativeOrigin() throws {
        let media = PDFRect(x: -100, y: -50, width: 800, height: 600)
        let boxes = PageBoxes(media: media, crop: PDFRect(x: -50, y: 0, width: 200, height: 200))
        try boxes.validate()
        #expect(boxes.crop.minX == -50)
    }

    @Test("A rotated page reports swapped visible extents")
    func rotatedVisibleSize() throws {
        let descriptor = PageDescriptor(
            id: PageID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))),
            documentID: DocumentID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))),
            index: 0,
            label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 595, height: 842)),
            rotation: .degrees90
        )
        try descriptor.validate()
        #expect(descriptor.rotatedVisibleSize == PDFSize(width: 842, height: 595))
    }

    @Test("A non-positive UserUnit is rejected")
    func userUnitValidation() {
        let descriptor = PageDescriptor(
            id: PageID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))),
            documentID: DocumentID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))),
            index: 0,
            label: "1",
            boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 595, height: 842)),
            userUnit: 0
        )
        #expect(throws: PageGeometryError.invalidUserUnit(0)) { try descriptor.validate() }
    }

    /// The documented rule is "honoured by every point-to-real conversion"; until code review
    /// CR-128 nothing read the field, so a /UserUnit 2 sheet measured at half size. Old output
    /// of the equivalent app-side preset: 0.0254 * 100 / 72 regardless of the user unit.
    @Test("A preset drawing ratio honours the page's /UserUnit (CR-128)")
    func presetHonoursUserUnit() throws {
        func page(userUnit: Double) -> PageDescriptor {
            PageDescriptor(
                id: PageID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))),
                documentID: DocumentID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))),
                index: 0,
                label: "1",
                boxes: PageBoxes(media: PDFRect(x: 0, y: 0, width: 595, height: 842)),
                userUnit: userUnit
            )
        }
        let scaleID = ScaleID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9)))
        let base = try ScaleTransform.preset(
            id: scaleID, page: page(userUnit: 1), ratioDenominator: 100, units: .metric
        )
        let doubled = try ScaleTransform.preset(
            id: scaleID, page: page(userUnit: 2), ratioDenominator: 100, units: .metric
        )
        let inch = Decimal(string: "0.0254")!
        let expected = inch * 100 / 72
        #expect(base.matrix.a == expected)
        #expect(base.matrix.d == expected)
        #expect(base.source == .preset)
        #expect(base.pageID == page(userUnit: 1).id)
        #expect(base.label == "1:100")
        #expect(doubled.matrix.a == inch * 100 * 2 / 72)
        #expect(doubled.matrix.a > expected)
        #expect(base.isUniform && doubled.isUniform)

        // The user unit multiplies the exact numerator; the single division comes last.
        let halfScale = try AffineScaleMatrix.metresPerPoint(ratioDenominator: 50, userUnit: 2.5)
        #expect(halfScale == inch * 50 * Decimal(string: "2.5")! / 72)
        #expect(try AffineScaleMatrix.metresPerPoint(ratioNumerator: 2, ratioDenominator: 100, userUnit: 1)
                == inch * 100 / (72 * 2))
        #expect(throws: PageGeometryError.invalidUserUnit(0)) {
            _ = try AffineScaleMatrix.metresPerPoint(ratioDenominator: 100, userUnit: 0)
        }
        #expect(throws: PageGeometryError.invalidUserUnit(.infinity)) {
            _ = try AffineScaleMatrix.metresPerPoint(ratioDenominator: 100, userUnit: .infinity)
        }
        #expect(throws: ScaleError.nonPositiveScale(0)) {
            _ = try AffineScaleMatrix.metresPerPoint(ratioDenominator: 0, userUnit: 1)
        }
    }

    /// The freeze half of CR-128: the field must have a reader in this package, not only a
    /// definition and a validation. This fails if the reader is ever removed again.
    @Test("Something in the contract reads /UserUnit (CR-128 freeze)")
    func userUnitHasAReader() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ZPDFContracts", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(atPath: sources.path))
        var readers: [String] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            // The definition and the documentation of the field do not count as honouring it.
            if relative.hasSuffix("PageGeometry.swift") || relative.hasPrefix("Freeze/") { continue }
            let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            if text.contains("userUnit") { readers.append(relative) }
        }
        #expect(!readers.isEmpty, "no file in ZPDFContracts reads PageDescriptor.userUnit")
        #expect(readers.contains { $0.hasSuffix("ScaleTransform.swift") })
    }

    /// `insetBy` grows a rectangle for a positive amount — the opposite of `CGRect.insetBy`
    /// (code review CR-92). The behaviour is kept under the honest name; the old name is
    /// deprecated with identical output. Old state: only the misleading name existed.
    @Test("outsetBy grows; the deprecated insetBy is the same function")
    func outsetByGrows() {
        let rect = PDFRect(x: 0, y: 0, width: 10, height: 10)
        #expect(rect.outsetBy(2) == PDFRect(x: -2, y: -2, width: 14, height: 14))
        #expect(rect.outsetBy(-4) == PDFRect(x: 4, y: 4, width: 2, height: 2))
        #expect(rect.outsetBy(-8).width == 0)
        #expect(rect.outsetBy(-8).minX == 5)
        @available(*, deprecated) func legacy(_ amount: Double) -> PDFRect { rect.insetBy(amount) }
        for amount in [2.0, -4.0, -5.0, -8.0, 0.0] {
            #expect(legacy(amount) == rect.outsetBy(amount))
        }
    }

    @Test("Bounding boxes and unions behave")
    func boundingBoxes() {
        let points = [PDFPoint(x: 3, y: -1), PDFPoint(x: -2, y: 8), PDFPoint(x: 5, y: 4)]
        let box = PDFRect.boundingBox(of: points)
        #expect(box?.minX == -2)
        #expect(box?.maxY == 8)
        #expect(PDFRect.boundingBox(of: []) == nil)
        let a = PDFRect(x: 0, y: 0, width: 10, height: 10)
        let b = PDFRect(x: 5, y: 5, width: 10, height: 10)
        #expect(a.intersects(b))
        #expect(a.union(b) == PDFRect(x: 0, y: 0, width: 15, height: 15))
        #expect(a.contains(PDFPoint(x: 10, y: 0)))
    }
}

@Suite("Scale transform")
struct ScaleTransformTests {

    static let scaleID = ScaleID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6)))

    @Test("A uniform scale maps length and area by the documented rules")
    func uniformScale() throws {
        // 1:50 on a metric sheet: one PDF point is 50/72 * 0.0254 m.
        let metresPerPoint = Decimal(string: "0.0176388888888888888888888888888888") ?? 0
        let scale = try ScaleTransform.uniform(
            id: Self.scaleID,
            metresPerPoint: metresPerPoint,
            units: .metric,
            source: .preset,
            label: "1:50"
        )
        #expect(scale.isUniform)
        #expect(scale.determinant == metresPerPoint * metresPerPoint)
        #expect(scale.areaFactor == metresPerPoint * metresPerPoint)

        let length = scale.matrix.length(from: PDFPoint(x: 0, y: 0), to: PDFPoint(x: 300, y: 400))
        // 500 PDF points at 0.01763888... m per point.
        #expect(abs(length - 500 * NumericPolicy.double(from: metresPerPoint)) < 1e-9)
    }

    @Test("Separate X and Y scales are honoured independently")
    func separateAxes() throws {
        let scale = try ScaleTransform.separateXY(
            id: Self.scaleID,
            metresPerPointX: Decimal(string: "0.02") ?? 0,
            metresPerPointY: Decimal(string: "0.05") ?? 0,
            units: .metric,
            source: .calibrationXY
        )
        #expect(!scale.isUniform)
        #expect(abs(scale.matrix.metresPerPointX - 0.02) < 1e-12)
        #expect(abs(scale.matrix.metresPerPointY - 0.05) < 1e-12)
        #expect(scale.determinant == Decimal(string: "0.001"))
    }

    @Test("Non-positive and extreme scales are rejected")
    func scaleGuards() {
        #expect(throws: ScaleError.nonPositiveScale(0)) {
            _ = try ScaleTransform.uniform(id: Self.scaleID, metresPerPoint: 0,
                                           units: .metric, source: .preset)
        }
        #expect(throws: ScaleError.self) {
            _ = try ScaleTransform.uniform(id: Self.scaleID, metresPerPoint: Decimal(string: "-1") ?? 0,
                                           units: .metric, source: .preset)
        }
        #expect(throws: ScaleError.self) {
            _ = try ScaleTransform.uniform(id: Self.scaleID, metresPerPoint: 1_000_000,
                                           units: .metric, source: .preset)
        }
        #expect(throws: Never.self) {
            _ = try ScaleTransform.uniform(id: Self.scaleID, metresPerPoint: 1_000_000,
                                           units: .metric, source: .preset, allowExtreme: true)
        }
    }

    @Test("Two-point calibration derives the scale and rejects bad input")
    func twoPointCalibration() throws {
        let scale = try ScaleTransform.calibratedTwoPoint(
            id: Self.scaleID,
            first: PDFPoint(x: 0, y: 0),
            second: PDFPoint(x: 100, y: 0),
            knownLength: 5,
            knownLengthUnit: .metre,
            units: .metric
        )
        #expect(scale.source == .calibrationTwoPoint)
        #expect(scale.matrix.a == Decimal(string: "0.05"))

        #expect(throws: ScaleError.self) {
            _ = try ScaleTransform.calibratedTwoPoint(
                id: Self.scaleID,
                first: PDFPoint(x: 0, y: 0),
                second: PDFPoint(x: 1, y: 0),
                knownLength: 5,
                knownLengthUnit: .metre,
                units: .metric
            )
        }
        #expect(throws: ScaleError.nonPositiveKnownLength(0)) {
            _ = try ScaleTransform.calibratedTwoPoint(
                id: Self.scaleID,
                first: PDFPoint(x: 0, y: 0),
                second: PDFPoint(x: 100, y: 0),
                knownLength: 0,
                knownLengthUnit: .metre,
                units: .metric
            )
        }
    }

    @Test("The inverse undoes the forward map, and a singular matrix throws")
    func inversion() throws {
        let matrix = AffineScaleMatrix(
            a: Decimal(string: "0.02") ?? 0,
            b: Decimal(string: "0.004") ?? 0,
            c: Decimal(string: "-0.003") ?? 0,
            d: Decimal(string: "0.05") ?? 0,
            tx: Decimal(string: "1.25") ?? 0,
            ty: Decimal(string: "-3.5") ?? 0
        )
        let inverse = try matrix.inverted()
        let original = PDFPoint(x: 123.456, y: -78.9)
        let real = matrix.map(original)
        let back = inverse.map(PDFPoint(x: real.x, y: real.y))
        #expect(abs(back.x - original.x) < 1e-9)
        #expect(abs(back.y - original.y) < 1e-9)

        #expect(throws: ScaleError.singularMatrix) {
            _ = try AffineScaleMatrix(a: 1, b: 2, c: 2, d: 4).inverted()
        }
    }

    @Test("Translation does not leak into a length")
    func translationIgnoredForDeltas() {
        let withTranslation = AffineScaleMatrix(a: 2, b: 0, c: 0, d: 2, tx: 1000, ty: -500)
        let withoutTranslation = AffineScaleMatrix(a: 2, b: 0, c: 0, d: 2)
        let start = PDFPoint(x: 1, y: 1)
        let end = PDFPoint(x: 4, y: 5)
        #expect(withTranslation.length(from: start, to: end)
                == withoutTranslation.length(from: start, to: end))
    }

    @Test("A revision bumps the version and keeps the identity")
    func revision() throws {
        let scale = try ScaleTransform.uniform(
            id: Self.scaleID, metresPerPoint: Decimal(string: "0.01") ?? 0,
            units: .metric, source: .preset
        )
        let revised = scale.revised(
            matrix: AffineScaleMatrix(a: Decimal(string: "0.02") ?? 0, b: 0, c: 0,
                                      d: Decimal(string: "0.02") ?? 0),
            source: .calibrationTwoPoint
        )
        #expect(revised.id == scale.id)
        #expect(revised.version == scale.version + 1)
        #expect(revised.source == .calibrationTwoPoint)
    }

    @Test("Precision modes round at the boundary and validate their input")
    func precisionModes() throws {
        let value = Decimal(string: "12.3456789") ?? 0
        #expect(PrecisionMode.decimalPlaces(3).apply(to: value) == Decimal(string: "12.346"))
        #expect(PrecisionMode.imperialFraction(.eighth).apply(to: Decimal(string: "3.3") ?? 0)
                == Decimal(string: "3.25"))
        #expect(throws: ScaleError.unsupportedDecimalPlaces(13)) {
            try PrecisionMode.decimalPlaces(13).validate()
        }
        #expect(throws: Never.self) { try PrecisionMode.decimalPlaces(0).validate() }
    }
}

@Suite("Slope")
struct SlopeTests {

    @Test("Every form reduces to the same ratio")
    func equivalentForms() throws {
        let expected = Decimal(string: "0.25") ?? 0
        #expect(try SlopeExpression.ratioOneToN(4).ratio() == expected)
        #expect(try SlopeExpression.ratioNToOne(expected).ratio() == expected)
        #expect(try SlopeExpression.decimalRatio(expected).ratio() == expected)
        #expect(try SlopeExpression.percent(25).ratio() == expected)
        #expect(try SlopeExpression.riseOverRun(rise: 1, run: 4).ratio() == expected)
    }

    @Test("A vertical slope throws instead of returning infinity")
    func verticalSlope() {
        #expect(SlopeExpression.riseOverRun(rise: 1, run: 0).isVertical)
        #expect(throws: SlopeError.verticalSlopeUndefined) {
            _ = try SlopeExpression.riseOverRun(rise: 1, run: 0).ratio()
        }
        // `1:0` is vertical, and `isVertical` says so; `ratio()` used to contradict it with
        // `zeroRatioTerm` (code review CR-145). Old output: SlopeError.zeroRatioTerm.
        #expect(SlopeExpression.ratioOneToN(0).isVertical)
        #expect(throws: SlopeError.verticalSlopeUndefined) {
            _ = try SlopeExpression.ratioOneToN(0).ratio()
        }
        #expect(throws: SlopeError.verticalSlopeUndefined) {
            _ = try SlopeExpression.ratioOneToN(0).trueLengthFactor()
        }
        // A flat slope asked for as 1:n is the one place zeroRatioTerm still belongs.
        #expect(throws: SlopeError.zeroRatioTerm) {
            _ = try SlopeExpression.decimalRatio(0).expressed(as: .ratioOneToN)
        }
        #expect(throws: SlopeError.degreesOutOfRange(90)) {
            _ = try SlopeExpression.degrees(90).ratio()
        }
    }

    @Test("A vertical slope still has an angle")
    func verticalAngle() throws {
        let angle = try SlopeExpression.riseOverRun(rise: 1, run: 0).angleRadians()
        #expect(abs(angle - Double.pi / 2) < 1e-12)
    }

    @Test("The true-length factor is sqrt(1 + ratio squared)")
    func trueLengthFactor() throws {
        let factor = try SlopeExpression.decimalRatio(Decimal(string: "0.75") ?? 0).trueLengthFactor()
        #expect(abs(factor - 1.25) < 1e-12)
        #expect(try SlopeExpression.decimalRatio(0).trueLengthFactor() == 1.0)
    }

    @Test("Re-expressing a slope preserves its value")
    func reexpression() throws {
        let source = SlopeExpression.percent(25)
        let asRatio = try source.expressed(as: .ratioOneToN)
        #expect(try asRatio.ratio() == Decimal(string: "0.25"))
        let asDegrees = try source.expressed(as: .degrees)
        let backToRatio = try asDegrees.ratio()
        #expect(abs(NumericPolicy.double(from: backToRatio) - 0.25) < 1e-12)
    }
}

@Suite("Numeric policy")
struct NumericPolicyTests {

    @Test("Compensated summation beats naive summation on a pathological array")
    func compensatedSummation() {
        // 1 followed by 100 000 copies of 1e-10. Naive summation loses most of the tail.
        var values: [Double] = [1.0]
        values.append(contentsOf: Array(repeating: 1e-10, count: 100_000))
        let expected = 1.0 + 100_000 * 1e-10
        let naive = values.reduce(0, +)
        let kahan = NumericPolicy.kahanSum(values)
        let pairwise = NumericPolicy.pairwiseSum(values)
        #expect(abs(kahan - expected) <= abs(naive - expected))
        #expect(abs(pairwise - expected) <= abs(naive - expected))
        #expect(abs(kahan - expected) < 1e-15)
    }

    @Test("Neumaier compensation survives a large term arriving late")
    func neumaierOrdering() {
        let values: [Double] = [1.0, 1e100, 1.0, -1e100]
        #expect(NumericPolicy.kahanSum(values) == 2.0)
    }

    @Test("Double to Decimal is explicit, bounded and rejects non-finite input")
    func decimalConversion() throws {
        #expect(try NumericPolicy.decimal(from: 0.1) == Decimal(string: "0.1"))
        #expect(try NumericPolicy.decimal(from: 0) == Decimal.zero)
        #expect(try NumericPolicy.decimal(from: 1.0 / 3.0, significantDigits: 6)
                == Decimal(string: "0.333333"))
        #expect(throws: NumericError.nonFiniteValue(Double.infinity)) {
            _ = try NumericPolicy.decimal(from: .infinity)
        }
        #expect(throws: NumericError.self) {
            _ = try NumericPolicy.decimal(from: .nan)
        }
        #expect(throws: NumericError.unsupportedSignificantDigits(0)) {
            _ = try NumericPolicy.decimal(from: 1.0, significantDigits: 0)
        }
    }

    @Test("exact() builds factors without touching a binary float")
    func exactFactors() throws {
        #expect(NumericPolicy.exact(254, -4) == Decimal(string: "0.0254"))
        #expect(NumericPolicy.exact(40_468_564_224, -7) == Decimal(string: "4046.8564224"))
        // Decimal(_: Double) goes through the shortest round-trippable decimal on this
        // Foundation, so it happens to land on 0.0254 here. It is still not a contract we may
        // rely on: the moment the Double itself is inexact, the Decimal inherits the error.
        #expect(Decimal(0.1 + 0.2) != Decimal(string: "0.3"))
        #expect(try NumericPolicy.decimal(from: 0.1 + 0.2, significantDigits: 15)
                == Decimal(string: "0.3"))
    }

    @Test("Rounding helpers are display-only and behave")
    func rounding() {
        #expect(NumericPolicy.rounded(Decimal(string: "2.5") ?? 0, decimalPlaces: 0) == 3)
        #expect(NumericPolicy.rounded(Decimal(string: "-2.5") ?? 0, decimalPlaces: 0) == -3)
        #expect(NumericPolicy.roundedToFraction(Decimal(string: "3.3") ?? 0, denominator: 16)
                == Decimal(string: "3.3125"))
        #expect(NumericPolicy.roundedToFraction(Decimal(string: "3.3") ?? 0, denominator: 0)
                == Decimal(string: "3.3"))
    }
}
