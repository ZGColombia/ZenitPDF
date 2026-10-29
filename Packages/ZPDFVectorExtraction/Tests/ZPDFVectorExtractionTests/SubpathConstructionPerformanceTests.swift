import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// IM-037: `lineTo` / `curveTo` / `curveToFromCurrentPoint` copied the whole subpath on
/// every operator.
///
/// The handlers did `guard var builder = current`, appended, then wrote `current =
/// builder`. While `builder` was being appended to, `current` still held the same array
/// buffers, so every append was a non-unique copy-on-write copy of the entire
/// `segments` and `vertices` arrays: a subpath of `n` operators cost `O(n²)`. The fix
/// takes ownership of the buffers before appending, so a subpath costs `O(n)`.
///
/// This is a complexity test, not a wall-clock budget: the ratio between a 4× larger
/// subpath's time and the smaller one's is what distinguishes linear (≈4) from quadratic
/// (≈16), and it is far less sensitive to a loaded machine than an absolute number.
struct SubpathConstructionPerformanceTests {

    private func makeState() -> VectorScanState {
        let box = VectorBounds(minX: 0, minY: 0, maxX: 100_000, maxY: 100_000)
        return VectorScanState(
            options: .standard,
            pageTransform: VectorPageTransform(
                convention: .pdfUserSpace, mediaBox: box, cropBox: box, rotation: 0
            ),
            hiddenOptionalContentGroups: []
        )
    }

    /// Seconds to build one subpath of `count` `l` operators, then stroke it.
    private func secondsForSubpath(of count: Int) -> Double {
        let state = makeState()
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            state.moveTo(CGPoint(x: 0, y: 0))
            for index in 1...count {
                state.lineTo(CGPoint(x: Double(index), y: Double(index % 7)))
            }
            state.paintPath(stroke: true, fill: false, closesPath: false)
        }
        #expect(state.primitives.count == count)
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test("Building a 4x longer subpath costs about 4x, not 16x (IM-037)")
    func subpathConstructionIsLinear() {
        // Warm-up so the first measurement is not first-touch paging.
        _ = secondsForSubpath(of: 1_000)
        let small = secondsForSubpath(of: 5_000)
        let large = secondsForSubpath(of: 20_000)
        let ratio = large / Swift.max(small, 1e-9)
        print(
            "subpathConstructionIsLinear: 5000 l -> \(String(format: "%.4f", small)) s, "
                + "20000 l -> \(String(format: "%.4f", large)) s, ratio \(String(format: "%.1f", ratio))"
        )
        // Old output on the copy-on-write handlers (debug build, 2026-09-22):
        // "5000 l -> 0.0243 s, 20000 l -> 0.3070 s, ratio 12.7".
        // Linear is 4; 8 leaves room for a loaded machine while still refusing quadratic.
        #expect(ratio < 8, "ratio \(ratio)")
    }
}
