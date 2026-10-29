import CClipper2
import CoreGraphics
import XCTest

@testable import ZPDFClipper2

@_silgen_name("zpclipper2_testing_set_max_output_count")
private func setMaxOutputCount(_ limit: Int32)

/// Bug hunt 2 — the Clipper2 bridge.
final class Clipper2BugHunt2Tests: XCTestCase {

    /// BH-393. Old output: 0.09999999999999999 for a vertex at 0.1.
    func testLatticeValuesRoundTripExactly() throws {
        let square: ClipperPath = [
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.3, y: 0.1), CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.1, y: 0.7),
        ]
        let result = try Clipper2.union([square], [])
        let values = Set(result.flatMap { [$0.map(\.x), $0.map(\.y)].flatMap { $0 } }.map { Double($0) })
        XCTAssertEqual(values, [0.1, 0.3, 0.7])
    }

    /// BH-394. Old output: counts were `static_cast<int32_t>`'d without a check, so an output
    /// larger than the ceiling wrapped negative. Exercised with a lowered ceiling.
    func testOutputLargerThanTheABICountIsRefused() {
        setMaxOutputCount(3)
        defer { setMaxOutputCount(0) }
        let square: ClipperPath = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertThrowsError(try Clipper2.union([square], [])) { error in
            XCTAssertEqual(error as? ClipperError, .coordinateOverflow)
        }
    }

    /// BH-395. Old code: no buffer length existed, so a vertex count larger than the buffer
    /// read off its end.
    func testPointInPolygonRefusesAnOverclaimedVertexCount() {
        let coords: [Double] = [0, 0, 10, 0, 10, 10]
        var out: Int32 = -1
        let status = coords.withUnsafeBufferPointer { buffer in
            zpclipper2_point_in_polygon(1, 1, buffer.baseAddress, Int32(buffer.count), 1_000_000,
                                        ZPCLIPPER2_FILL_NON_ZERO, 1_000_000, &out)
        }
        XCTAssertEqual(status, ZPCLIPPER2_ERR_COORD_OVERRUN)
    }

    /// BH-397. Old output: `.outside` for the doubly wound overlap, which a non-zero union
    /// counts as inside.
    func testContainmentHonoursTheFillRule() throws {
        // A ring that goes round the square twice: every interior point winds twice.
        let square: ClipperPath = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let twice = square + square
        let point = CGPoint(x: 5, y: 5)
        XCTAssertEqual(try Clipper2.containment(of: point, in: twice), .inside)
        XCTAssertEqual(try Clipper2.containment(of: point, in: twice, fillRule: .evenOdd), .outside)
        XCTAssertEqual(try Clipper2.containment(of: point, in: square.reversed(), fillRule: .negative), .inside)
        XCTAssertEqual(try Clipper2.containment(of: point, in: square.reversed(), fillRule: .positive), .outside)
        // Agrees with the boolean at its default fill rule.
        XCTAssertGreaterThan(Clipper2.area(of: try Clipper2.union([twice], [])), 0)
    }

    /// BH-399. Old documentation promised ±2.3e12 pt at the default scale; 2e12 is refused.
    func testDocumentedRangeMatchesTheShim() throws {
        let inside: ClipperPath = [CGPoint(x: 0, y: 0), CGPoint(x: 1.1e12, y: 0), CGPoint(x: 1.1e12, y: 1)]
        XCTAssertNoThrow(try Clipper2.union([inside], []))
        let outside: ClipperPath = [CGPoint(x: 0, y: 0), CGPoint(x: 1.2e12, y: 0), CGPoint(x: 1.2e12, y: 1)]
        XCTAssertThrowsError(try Clipper2.union([outside], []))
    }
}
