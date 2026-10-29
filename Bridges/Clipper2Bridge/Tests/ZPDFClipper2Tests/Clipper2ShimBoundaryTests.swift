import CClipper2
import XCTest

@testable import ZPDFClipper2

/// The test seam in the shim: after `successes` further allocations, the next one returns
/// NULL. Declared here rather than in `zpdf_clipper2.h` — it is not part of the ABI and it
/// is compiled out of a release build.
@_silgen_name("zpclipper2_testing_fail_allocation_after")
private func failAllocationAfter(_ successes: Int32)

/// CR-141 and CR-142 — the two ways the C boundary could be made to misbehave by a caller
/// that is not our own Swift wrapper. `zpdf_clipper2.h` is a public header; "our wrapper
/// happens to pass consistent arguments" is not a bound.
final class Clipper2ShimBoundaryTests: XCTestCase {

    /// CR-141. `path_lengths` is a claim about a buffer only the caller has measured, and
    /// nothing checked it: one oversized entry walked the reader off the end of `coords`.
    ///
    /// Old code (no `coord_count` parameter existed, so this test could not even be
    /// written against it): the same call read four million doubles past a two-double
    /// buffer and returned whatever the garbage happened to decode to —
    /// `[old-code CR-141] plain run status = 5 path_count = 0`, i.e.
    /// `ZPCLIPPER2_ERR_OVERFLOW`, produced by a non-finite value found somewhere out in
    /// the heap. A read that survives by accident is still an out-of-bounds read.
    func testReadPathsRefusesLengthsThatExceedTheCoordinateBuffer() {
        let coords: [Double] = [0, 0]              // one vertex
        let lengths: [Int32] = [10_000_000]        // a claim of ten million
        var out = ZPClipper2Paths()
        let status = coords.withUnsafeBufferPointer { c in
            lengths.withUnsafeBufferPointer { l in
                zpclipper2_boolean(ZPCLIPPER2_CLIP_UNION, ZPCLIPPER2_FILL_NON_ZERO,
                                   c.baseAddress, Int32(c.count), l.baseAddress, 1,
                                   nil, 0, nil, 0, 0, 1_000_000, &out)
            }
        }
        zpclipper2_paths_free(&out)
        XCTAssertEqual(status, ZPCLIPPER2_ERR_COORD_OVERRUN,
                       "an over-run must be refused by the bound, not survived by luck")
    }

    /// The bound is exact, not conservative: a buffer that holds precisely the claimed
    /// vertices is accepted, and one double short is refused.
    func testCoordinateBoundIsExact() {
        let square: [Double] = [0, 0, 10, 0, 10, 10, 0, 10]
        let lengths: [Int32] = [4]

        func run(coordCount: Int32) -> Int32 {
            var out = ZPClipper2Paths()
            let status = square.withUnsafeBufferPointer { c in
                lengths.withUnsafeBufferPointer { l in
                    zpclipper2_boolean(ZPCLIPPER2_CLIP_UNION, ZPCLIPPER2_FILL_NON_ZERO,
                                       c.baseAddress, coordCount, l.baseAddress, 1,
                                       nil, 0, nil, 0, 0, 1_000_000, &out)
                }
            }
            zpclipper2_paths_free(&out)
            return status
        }

        XCTAssertEqual(run(coordCount: 8), ZPCLIPPER2_OK, "exactly enough is enough")
        XCTAssertEqual(run(coordCount: 7), ZPCLIPPER2_ERR_COORD_OVERRUN, "one short is refused")
    }

    /// The bound is applied to the clip soup as well as the subject soup.
    func testClipSoupCarriesTheSameBound() {
        let coords: [Double] = [0, 0, 1, 0, 1, 1]
        let lengths: [Int32] = [64]

        let goodSquare: [Double] = [0, 0, 10, 0, 10, 10, 0, 10]
        let goodLengths: [Int32] = [4]
        var out = ZPClipper2Paths()
        let clipStatus = goodSquare.withUnsafeBufferPointer { sc in
            goodLengths.withUnsafeBufferPointer { sl in
                coords.withUnsafeBufferPointer { cc in
                    lengths.withUnsafeBufferPointer { cl in
                        zpclipper2_boolean(ZPCLIPPER2_CLIP_INTERSECTION, ZPCLIPPER2_FILL_NON_ZERO,
                                           sc.baseAddress, Int32(sc.count), sl.baseAddress, 1,
                                           cc.baseAddress, Int32(cc.count), cl.baseAddress, 1,
                                           0, 1_000_000, &out)
                    }
                }
            }
        }
        zpclipper2_paths_free(&out)
        XCTAssertEqual(clipStatus, ZPCLIPPER2_ERR_COORD_OVERRUN, "the clip soup is bounded too")
    }

    /// CR-142. The header promises "*out is untouched otherwise", and `write_paths`
    /// zeroed it as its first act — so an allocation failure cleared the caller's struct.
    /// A caller holding a previous result there lost the pointers to it.
    ///
    /// Old code, measured:
    /// `XCTAssertEqual failed: ("0") is not equal to ("77") - path_count was touched on
    /// failure (successes: 0)`, and the same for `vertex_count`, `coords` and
    /// `path_lengths`, on both the lengths allocation and the coords allocation.
    func testWritePathsLeavesOutUntouchedWhenAllocationFails() {
        let square: [Double] = [0, 0, 10, 0, 10, 10, 0, 10]
        let lengths: [Int32] = [4]
        let sentinelCoords = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        let sentinelLengths = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        defer { sentinelCoords.deallocate(); sentinelLengths.deallocate() }

        for successes: Int32 in [0, 1] {   // fail the lengths allocation, then the coords one
            var out = ZPClipper2Paths(coords: sentinelCoords, path_lengths: sentinelLengths,
                                      path_count: 77, vertex_count: 99)
            failAllocationAfter(successes)
            let status = square.withUnsafeBufferPointer { c in
                lengths.withUnsafeBufferPointer { l in
                    zpclipper2_boolean(ZPCLIPPER2_CLIP_UNION, ZPCLIPPER2_FILL_NON_ZERO,
                                       c.baseAddress, Int32(c.count), l.baseAddress, 1,
                                       nil, 0, nil, 0, 0, 1_000_000, &out)
                }
            }
            failAllocationAfter(-1)
            XCTAssertEqual(status, ZPCLIPPER2_ERR_OUT_OF_MEMORY, "successes: \(successes)")
            XCTAssertEqual(out.path_count, 77, "path_count was touched on failure (successes: \(successes))")
            XCTAssertEqual(out.vertex_count, 99, "vertex_count was touched on failure (successes: \(successes))")
            XCTAssertEqual(out.coords, sentinelCoords, "coords was touched on failure (successes: \(successes))")
            XCTAssertEqual(out.path_lengths, sentinelLengths, "path_lengths was touched on failure (successes: \(successes))")
        }
    }

    /// A successful call still writes the result, and an empty result is still the zeroed
    /// struct the header documents — the CR-142 fix moved the write, it did not remove it.
    func testSuccessStillWritesAndEmptyResultIsZeroed() {
        let square: [Double] = [0, 0, 10, 0, 10, 10, 0, 10]
        let lengths: [Int32] = [4]
        var out = ZPClipper2Paths()
        var status = square.withUnsafeBufferPointer { c in
            lengths.withUnsafeBufferPointer { l in
                zpclipper2_boolean(ZPCLIPPER2_CLIP_UNION, ZPCLIPPER2_FILL_NON_ZERO,
                                   c.baseAddress, Int32(c.count), l.baseAddress, 1,
                                   nil, 0, nil, 0, 0, 1_000_000, &out)
            }
        }
        XCTAssertEqual(status, ZPCLIPPER2_OK)
        XCTAssertEqual(out.path_count, 1)
        XCTAssertEqual(out.vertex_count, 4)
        zpclipper2_paths_free(&out)

        // Two disjoint squares intersected: a legitimate empty result.
        let other: [Double] = [100, 100, 110, 100, 110, 110, 100, 110]
        var empty = ZPClipper2Paths(coords: nil, path_lengths: nil, path_count: 5, vertex_count: 5)
        status = square.withUnsafeBufferPointer { sc in
            lengths.withUnsafeBufferPointer { sl in
                other.withUnsafeBufferPointer { cc in
                    lengths.withUnsafeBufferPointer { cl in
                        zpclipper2_boolean(ZPCLIPPER2_CLIP_INTERSECTION, ZPCLIPPER2_FILL_NON_ZERO,
                                           sc.baseAddress, Int32(sc.count), sl.baseAddress, 1,
                                           cc.baseAddress, Int32(cc.count), cl.baseAddress, 1,
                                           0, 1_000_000, &empty)
                    }
                }
            }
        }
        XCTAssertEqual(status, ZPCLIPPER2_OK)
        XCTAssertEqual(empty.path_count, 0, "an empty success is the zeroed struct")
        XCTAssertEqual(empty.vertex_count, 0)
        XCTAssertNil(empty.coords)
        XCTAssertNil(empty.path_lengths)
    }
}
