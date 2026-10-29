import CoreGraphics
import Foundation
import Testing
import ZPDFTestingSupport
@testable import ZPDFVectorExtraction

/// The low-severity guards of bug hunt 2, grouped: a varint that silently truncated
/// (BH-859), an identifier step clamp with two side doors (BH-860), two option values
/// `validated()` never looked at (BH-861, BH-862), circle-query parameters that turned NaN
/// into an innocent empty answer (BH-863) and a flatness test blind to longitudinal
/// overshoot (BH-868). Every expected value is derived by hand beside it.
struct ValidationGuardTests {

    // MARK: - BH-859

    private static func decodeVarint(_ bytes: [UInt8]) throws -> UInt64 {
        var reader = BinaryReader(Data(bytes))
        return try reader.readVarint()
    }

    @Test("A ten-byte varint whose last group does not fit in 64 bits is refused, not truncated (BH-859)")
    func varintOverflowIsRefused() throws {
        // Nine continuation bytes carry 63 zero bits, so the tenth group lands at shift
        // 63, where only its bit 0 fits: 0x01 there is exactly 2^63 = 9 223 372 036 854 775 808.
        #expect(try Self.decodeVarint([UInt8](repeating: 0x80, count: 9) + [0x01]) == 9_223_372_036_854_775_808)
        // 0x7E sets bits 1–6 of that group, which cannot fit. Old output: the smart shift
        // discarded them and the varint decoded as 0, returned normally.
        #expect(throws: VectorExtractionError.self) {
            try Self.decodeVarint([UInt8](repeating: 0x80, count: 9) + [0x7E])
        }
        // An eleventh byte is too long whatever it holds.
        #expect(throws: VectorExtractionError.self) {
            try Self.decodeVarint([UInt8](repeating: 0x80, count: 10) + [0x01])
        }
        // Non-vacuity: ordinary values are unchanged. 300 = 0b1_0010_1100 → 0xAC 0x02.
        #expect(try Self.decodeVarint([0xAC, 0x02]) == 300)
    }

    // MARK: - BH-860

    @Test("The identifier step cannot be set or decoded to 0 (BH-860)")
    func identifierStepClampHolds() throws {
        var plan = VectorIdentifierPlan.standard
        plan.step = 0
        // Old output: 0 — the clamp lived in `init` only.
        #expect(plan.step == 1)
        plan.step = 5
        #expect(plan.step == 5)

        let decoded = try JSONDecoder().decode(
            VectorIdentifierPlan.self, from: Data(#"{"first":7,"step":0}"#.utf8)
        )
        #expect(decoded.first == 7)
        // Old output: 0 — the synthesised `init(from:)` never ran the clamp.
        #expect(decoded.step == 1)

        let again = try JSONDecoder().decode(
            VectorIdentifierPlan.self, from: try JSONEncoder().encode(decoded)
        )
        #expect(again == decoded)
    }

    // MARK: - BH-861, BH-862

    private static func invalidOptionName(_ options: VectorExtractionOptions) -> String? {
        do {
            _ = try options.validated()
            return nil
        } catch VectorExtractionError.invalidOption(let name, _) {
            return name
        } catch {
            return "unexpected error \(error)"
        }
    }

    @Test("A subpath point budget under 2 is the caller's error, not the file's (BH-861)")
    func pointsPerSubpathBudgetIsValidated() async throws {
        var options = VectorExtractionOptions.standard
        options.budget.maximumPointsPerSubpath = 1
        #expect(Self.invalidOptionName(options) == "budget.maximumPointsPerSubpath")
        options.budget.maximumPointsPerSubpath = 0
        #expect(Self.invalidOptionName(options) == "budget.maximumPointsPerSubpath")
        options.budget.maximumPointsPerSubpath = 2
        #expect(Self.invalidOptionName(options) == nil)

        // Through the extractor: old output was a *successful* extraction of the
        // rectangle fixture with zero primitives and
        // `.partial(malformedContentStream(operandFailures: 3))` — three `l` operators
        // refused by the budget and blamed on the PDF.
        options.budget.maximumPointsPerSubpath = 1
        let directory = try ExtractionTestSupport.makeTemporaryDirectory()
        defer { ExtractionTestSupport.remove(directory) }
        let handle = try ZPDFFixtures.make(.rectangle, in: directory)
        await #expect(throws: VectorExtractionError.self) {
            _ = try await VectorExtractor(options: options).extract(documentAt: handle.url, pageIndex: 0)
        }
    }

    @Test("A negative or NaN crop-box overshoot margin is refused by name (BH-862)")
    func cropBoxOvershootMarginIsValidated() {
        var options = VectorExtractionOptions.standard
        options.backgroundFilter.cropBoxOvershootMargin = -300
        // Old output: nil — accepted, and every outline containing the shrunken box was
        // filtered as `enclosesCropBox`.
        #expect(Self.invalidOptionName(options) == "backgroundFilter.cropBoxOvershootMargin")
        options.backgroundFilter.cropBoxOvershootMargin = .nan
        #expect(Self.invalidOptionName(options) == "backgroundFilter.cropBoxOvershootMargin")
        options.backgroundFilter.cropBoxOvershootMargin = .infinity
        #expect(Self.invalidOptionName(options) == "backgroundFilter.cropBoxOvershootMargin")
        options.backgroundFilter.cropBoxOvershootMargin = 0
        #expect(Self.invalidOptionName(options) == nil)
        options.backgroundFilter.cropBoxOvershootMargin = 0.5
        #expect(Self.invalidOptionName(options) == nil)
    }

    // MARK: - BH-863

    /// The standard four-cubic circle of radius `r` about `centre`, one subpath.
    static func circleCurves(firstID: UInt64, sourceObjectID: UInt64, centre: CGPoint, radius r: Double) -> [GeometryQueryCurve] {
        let k = 0.552_284_749_830_793_6 * r
        let c = centre
        let quadrants: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x + r, y: c.y + k), CGPoint(x: c.x + k, y: c.y + r), CGPoint(x: c.x, y: c.y + r)),
            (CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - k, y: c.y + r), CGPoint(x: c.x - r, y: c.y + k), CGPoint(x: c.x - r, y: c.y)),
            (CGPoint(x: c.x - r, y: c.y), CGPoint(x: c.x - r, y: c.y - k), CGPoint(x: c.x - k, y: c.y - r), CGPoint(x: c.x, y: c.y - r)),
            (CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + k, y: c.y - r), CGPoint(x: c.x + r, y: c.y - k), CGPoint(x: c.x + r, y: c.y))
        ]
        return quadrants.enumerated().map { index, q in
            GeometryQueryCurve(
                primitiveID: firstID + UInt64(index),
                parentID: nil,
                sourceObjectID: sourceObjectID,
                subpathIndex: 0,
                nestingDepth: 0,
                cubic: VectorCubic(p0: q.0, p1: q.1, p2: q.2, p3: q.3)
            )
        }
    }

    private static func rejectedParameter<Match>(_ result: GeometryQueryResult<Match>) -> String? {
        if case let .invalidParameter(name, _) = result.status { return name }
        return nil
    }

    @Test("circles() refuses NaN or negative sweep and fit parameters by name (BH-863)")
    func circleParametersAreValidated() throws {
        let engine = try GeometryQueryEngine(
            segments: [],
            curves: Self.circleCurves(firstID: 1, sourceObjectID: 1, centre: CGPoint(x: 300, y: 300), radius: 144)
        )
        // Non-vacuity: the circle is there for a sane query.
        #expect(engine.circles(radius: 144, tolerance: 0.5).count == 1)

        // Old output for every line below: 0 matches, status `.complete`, examinedCount 1.
        #expect(Self.rejectedParameter(engine.circles(radius: 144, tolerance: 0.5, minimumSweepRadians: .nan)) == "minimumSweepRadians")
        #expect(Self.rejectedParameter(engine.circles(radius: 144, tolerance: 0.5, minimumSweepRadians: -1)) == "minimumSweepRadians")
        #expect(Self.rejectedParameter(engine.circles(radius: 144, tolerance: 0.5, fitToleranceFraction: .nan)) == "fitToleranceFraction")
        #expect(Self.rejectedParameter(engine.circles(radius: 144, tolerance: 0.5, fitToleranceFraction: -0.1)) == "fitToleranceFraction")
        #expect(Self.rejectedParameter(engine.circles(radius: 144, tolerance: 0.5, minimumFitTolerance: .nan)) == "minimumFitTolerance")
        #expect(Self.rejectedParameter(engine.circles(radius: 144, tolerance: 0.5, minimumFitTolerance: -1)) == "minimumFitTolerance")
        for rejected in [engine.circles(radius: 144, tolerance: 0.5, minimumSweepRadians: .nan)] {
            #expect(rejected.wasRejected)
            #expect(rejected.examinedCount == 0)
        }
        // Zero is a legal value for all three. A zero sweep relaxes the bar; a zero
        // fraction leaves the 0.1 pt floor, which the circle's 2.7253e-4 × 144 = 0.039 pt
        // deviation passes; a zero floor leaves the 1 % fraction, 1.44 pt.
        #expect(engine.circles(radius: 144, tolerance: 0.5, minimumSweepRadians: 0).count == 1)
        #expect(engine.circles(radius: 144, tolerance: 0.5, fitToleranceFraction: 0).count == 1)
        #expect(engine.circles(radius: 144, tolerance: 0.5, minimumFitTolerance: 0).count == 1)
        // And both at zero demand an exact fit, which a Bézier circle is not: an honest
        // empty answer, examined, not a rejection.
        let exact = engine.circles(radius: 144, tolerance: 0.5, fitToleranceFraction: 0, minimumFitTolerance: 0)
        #expect(exact.count == 0 && exact.status == .complete && exact.examinedCount == 1)
    }

    // MARK: - BH-868

    @Test("A control point that overshoots the chord along its own direction is not flat (BH-868)")
    func longitudinalOvershootIsNotFlat() throws {
        let flattener = VectorFlattener.standard  // flatness 0.1
        let cubic = VectorCubic(
            p0: CGPoint(x: 0, y: 0), p1: CGPoint(x: 100, y: 0),
            p2: CGPoint(x: -100, y: 0), p3: CGPoint(x: 10, y: 0)
        )
        // x(t) = 300·t(1−t)(1−2t) + 10t³, so x'(t) = 300 − 1800t + 1830t², whose roots are
        // t = (1800 ± √1 044 000) / 3660 = 0.212634 and 0.770973; x there is 28.963 and
        // −24.125. The curve therefore runs 0 → 28.963 → −24.125 → 10, a path of
        // 28.963 + 53.088 + 34.125 = 116.176 along the axis.
        //
        // Old output: `flatten` returned the two endpoints (perpendicular deviation 0),
        // and `approximateLength` was 10.
        let points = flattener.flatten(cubic)
        #expect(points.count > 2)
        let maxX = try #require(points.map(\.x).max())
        let minX = try #require(points.map(\.x).min())
        #expect(maxX > 28.8)
        #expect(minX < -24.0)
        // The polyline under-reads only where a piece straddles an extremum, by at most
        // the flatness on either side of each: within 0.4 of the true 116.176.
        #expect(abs(flattener.approximateLength(of: cubic) - 116.176) < 0.5)

        // Non-regression: control points inside the chord's span are as flat as before.
        let straight = VectorCubic(
            p0: CGPoint(x: 0, y: 0), p1: CGPoint(x: 3, y: 0),
            p2: CGPoint(x: 7, y: 0), p3: CGPoint(x: 10, y: 0)
        )
        #expect(flattener.flatten(straight).count == 2)
    }
}
