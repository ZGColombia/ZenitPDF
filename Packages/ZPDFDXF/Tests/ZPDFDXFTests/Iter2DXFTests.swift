import Foundation
import Testing
@testable import ZPDFDXF

/// Iteration 2: the sheet writer formats numbers by hand and can be cancelled (S-119); a
/// spline's knot-span search is linear and can be cancelled (S-122).
@Suite("DXF — iteration 2", .serialized)
struct Iter2DXFTests {

    // MARK: - S-119

    @Test("S-119: numbers are six-decimal, trimmed, never -0 — hand-derived")
    func numberFormat() {
        let cases: [(Double, String)] = [
            (0, "0"), (1.5, "1.5"), (-2.25, "-2.25"), (100, "100"), (12.3456789, "12.345679"),
            (0.000001, "0.000001"), (0.0000004, "0"), (-0.0000004, "0"), (0.1, "0.1"),
            (1234.00005, "1234.00005"), (-0.05, "-0.05"), (595.275591, "595.275591"),
            (.nan, "0"), (.infinity, "0"), (1e13, "10000000000000")
        ]
        for (value, expected) in cases {
            #expect(DXFSheetWriter.number(value) == expected, "\(value)")
        }
    }

    /// The old formatter, kept here as the reference the hand-written one replaces.
    static func reference(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    @Test("S-119: the hand-written formatter agrees with %.6f on sheet-sized values")
    func agreesWithReference() {
        var state: UInt64 = 0x5EED_0119
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var exact = 0, worst = 0.0
        let count = 20_000
        for _ in 0..<count {
            let value = (next() - 0.2) * 5_000   // −1 000 … 4 000 pt: every sheet up to A0 at any scale
            let mine = DXFSheetWriter.number(value), theirs = Self.reference(value)
            if mine == theirs { exact += 1 }
            worst = max(worst, abs((Double(mine) ?? .nan) - (Double(theirs) ?? .nan)))
        }
        // An exact tie at the seventh decimal may round the other way: one millionth, at most.
        #expect(exact >= count - 2, "\(count - exact) of \(count) differ")
        #expect(worst <= 1.000_001e-6)
    }

    /// About 2 M points: 1 000 polylines of 2 000 vertices each.
    static func largeDrawing() -> DXFDrawing {
        let entities = (0..<1_000).map { row -> DXFEntity in
            let points = (0..<2_000).map { column in DXFPoint(x: Double(column) * 1.37, y: Double(row) * 2.11 + Double(column % 7) * 0.013) }
            return DXFEntity(layer: "0", shape: .polyline(points: points, bulges: [], closed: false))
        }
        return DXFDrawing(unit: .millimetres, unitDeclared: true, layers: ["0"], entities: entities, skipped: [:])
    }

    /// Old output: about 10 µs per coordinate — 4 M coordinates, some 40 s, past the 30 s
    /// geometry deadline before the sheet was even assembled.
    @Test("S-119: a sheet of about 2 M points is written well inside the geometry deadline")
    func twoMillionPointsInTime() throws {
        let drawing = Self.largeDrawing()
        var options = DXFSheetWriter.Options()
        options.compress = false
        let started = ContinuousClock.now
        let sheet = try DXFSheetWriter.write(drawing, title: "large", options: options)
        let elapsed = ContinuousClock.now - started
        print("S-119 write of 2,000,000 points: \(elapsed)")
        // Half the 30 s deadline, in a debug build; a release service is several times faster.
        #expect(elapsed < .seconds(15), "took \(elapsed)")
        // Every vertex was drawn: one "m" and 1 999 "l" per polyline.
        let text = String(decoding: sheet.pdf, as: UTF8.self)
        #expect(text.components(separatedBy: " l\n").count - 1 == 1_000 * 1_999)
    }

    /// Old output: `write` could not be cancelled; it ran to the end for a caller who had left.
    @Test("S-119: writing a sheet stops when its task is cancelled")
    func writeIsCancellable() async throws {
        let drawing = Self.largeDrawing()
        let task = Task { () throws -> DXFSheet in
            withUnsafeCurrentTask { $0?.cancel() }
            return try DXFSheetWriter.write(drawing, title: "cancelled")
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    // MARK: - S-122

    /// A degree-1 spline through (0, 0), (1, 0) … (n − 1, 0) with clamped knots
    /// [0, 0, 1, 2, …, n − 1, n − 1]: it is the polyline through its control points.
    static func straightSpline(controlPoints n: Int) -> DXFReader.RawEntity {
        var pairs: [DXFReader.Pair] = [.init(code: 71, value: "1")]
        let knots = [0.0] + (0..<n).map(Double.init) + [Double(n - 1)]
        pairs += knots.map { .init(code: 40, value: String($0)) }
        for index in 0..<n {
            pairs.append(.init(code: 10, value: String(index)))
            pairs.append(.init(code: 20, value: "0"))
        }
        return DXFReader.RawEntity(type: "SPLINE", pairs: pairs)
    }

    /// Old output: about Σ 10·i for i ≤ 2 000 ≈ 2.0 × 10^7 span steps (each sample searched from
    /// the start); linear now, at most n − 2 = 19 999.
    @Test("S-122: the knot-span search is linear in the control points, and the points are unchanged")
    func splineSpanSearchIsLinear() throws {
        let n = 20_001
        var steps = 0
        let points = try Expander.evaluateSpline(Self.straightSpline(controlPoints: n), spanSteps: &steps)
        #expect(steps <= n - 2, "\(steps) span steps")
        // 2 000 samples of t = 20 000·i / 2 000 = 10·i; on a straight degree-1 spline the point
        // is (t, 0). Hand-derived.
        #expect(points.count == 2_001)
        #expect(points.first == DXFPoint(x: 0, y: 0))
        #expect(points[1] == DXFPoint(x: 10, y: 0))
        #expect(points[1_000] == DXFPoint(x: 10_000, y: 0))
        #expect(points.last == DXFPoint(x: 20_000, y: 0))
    }

    /// Old output: the evaluation ran to the end with the task cancelled.
    @Test("S-122: evaluating a spline stops when its task is cancelled")
    func splineIsCancellable() async throws {
        let spline = Self.straightSpline(controlPoints: 20_001)
        let task = Task { () throws -> [DXFPoint] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try Expander.evaluateSpline(spline)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
