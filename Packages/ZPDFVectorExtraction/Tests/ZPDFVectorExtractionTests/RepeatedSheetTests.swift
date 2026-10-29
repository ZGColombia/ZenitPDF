import CoreGraphics
import Foundation
import Testing
@testable import ZPDFVectorExtraction

/// NL-AUTO-21: two storeys drawn alike are found as one group; a sheet with a moved wall is not.
/// Tolerance: 0.5 pt on any paper size (S-099; it was 0.5 % of the diagonal, 7.29 pt on this A3
/// sheet, which grouped a partition moved 3 pt — 150 mm at 1:50).
@Suite("Repeated sheets — NL-AUTO-21")
struct RepeatedSheetTests {

    static let size = CGSize(width: 1191, height: 842)

    static func floor(wallAt x: Double = 500, extra: [(CGPoint, CGPoint)] = []) -> RepeatedSheetDetector.Signature {
        var segments: [GeometryQuerySegment] = []
        var id: UInt64 = 0
        func line(_ a: CGPoint, _ b: CGPoint) {
            id += 1
            segments.append(GeometryQuerySegment(primitiveID: id, start: a, end: b))
        }
        line(CGPoint(x: 100, y: 100), CGPoint(x: 1000, y: 100))
        line(CGPoint(x: 1000, y: 100), CGPoint(x: 1000, y: 700))
        line(CGPoint(x: 1000, y: 700), CGPoint(x: 100, y: 700))
        line(CGPoint(x: 100, y: 700), CGPoint(x: 100, y: 100))
        line(CGPoint(x: x, y: 100), CGPoint(x: x, y: 700))
        for (a, b) in extra { line(a, b) }
        return RepeatedSheetDetector.signature(segments: segments, pageSize: size)
    }

    @Test("Two identical floors and a floor re-plotted 0.3 pt off group together; a partition 3 pt off does not")
    func sameStoreys() {
        let groups = RepeatedSheetDetector.groups([(0, Self.floor()), (1, Self.floor()), (2, Self.floor(wallAt: 500.3))])
        #expect(groups == [[0, 1, 2]])
        #expect(RepeatedSheetDetector.defaultTolerancePoints == 0.5)
        // S-099: 3 pt is 150 mm at 1:50. Before, the A3 default of 7.29 pt grouped it.
        #expect(RepeatedSheetDetector.groups([(0, Self.floor()), (1, Self.floor(wallAt: 503))]).isEmpty)
    }

    @Test("A floor whose partition moved 1 m (57 pt at 1:50) is a different sheet; so is one with an extra room")
    func differentStoreys() {
        let moved = Self.floor(wallAt: 557)
        let extra = Self.floor(extra: [(CGPoint(x: 100, y: 400), CGPoint(x: 500, y: 400))])
        #expect(RepeatedSheetDetector.groups([(0, Self.floor()), (1, moved)]).isEmpty)
        #expect(RepeatedSheetDetector.groups([(0, Self.floor()), (1, extra)]).isEmpty, "the extra line has no partner on the first sheet")
        // Different sheet sizes never match; an empty sheet never matches.
        let floor = Self.floor()
        let other = RepeatedSheetDetector.Signature(sampleCount: floor.sampleCount, segments: floor.segments, pageSize: CGSize(width: 842, height: 595))
        #expect(!RepeatedSheetDetector.matches(Self.floor(), other, tolerance: 10))
        #expect(!RepeatedSheetDetector.matches(.init(points: [], pageSize: Self.size), .init(points: [], pageSize: Self.size), tolerance: 10))
    }

    @Test("Three sheets in two storey types give two groups, each listed by its first sheet")
    func twoTypes() {
        let a = Self.floor(), b = Self.floor(wallAt: 700)
        let groups = RepeatedSheetDetector.groups([(3, b), (0, a), (1, b), (2, a)])
        #expect(groups == [[0, 2], [1, 3]])
    }
}
