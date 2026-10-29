import CoreGraphics
import Foundation
import Testing
import ZPDFVectorExtraction

@testable import ZPDFCompare

/// R-151: the identical and reshaped passes look up a 0.1 pt neighbourhood, and used to do it
/// through the moved pass's 144 pt grid — every 3 × 3 block of 144 pt cells, sorted — so on a
/// dense sheet each revised shape was checked against thousands of candidates.
@Suite("Vector diff on a dense sheet (R-151)", .serialized)
struct VectorDiffDensityTests {

    /// A page whose `columns × rows` short horizontal lines sit on a 2 pt grid inside one
    /// 144 pt square — the density of hatching or a dense CAD detail.
    private static func densePDF(columns: Int, rows: Int, shiftFirst: CGFloat = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-dense-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(0.25)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = 100 + CGFloat(column) * 2 + (row == 0 && column == 0 ? shiftFirst : 0)
                let y = 100 + CGFloat(row) * 2
                context.move(to: CGPoint(x: x, y: y))
                context.addLine(to: CGPoint(x: x + 1.5, y: y))
                context.strokePath()
            }
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @Test("R-151: a 0.1 pt lookup visits only the shapes in its own 1 pt neighbourhood")
    func nearLookupIsLocal() async throws {
        let url = try Self.densePDF(columns: 72, rows: 72)
        defer { try? FileManager.default.removeItem(at: url) }
        let extraction = try await VectorExtractor().extract(documentAt: url, pageIndex: 0)
        let shapes = VectorDiffEngine.shapes(from: extraction.primitives, alignment: .identity, minimumConfidence: 0)
        #expect(shapes.count == 72 * 72)
        let options = VectorDiffOptions.standard
        let grids = VectorDiffEngine.grids(for: shapes, options: options)
        let probe = shapes[shapes.count / 2]
        let near = grids.near.candidates(near: probe.anchor, radius: options.positionTolerancePoints)
        let wide = grids.moved.candidates(near: probe.anchor, radius: options.positionTolerancePoints)
        // By hand: anchors sit 2 pt apart, so a 3 × 3 block of 1 pt cells holds the probe and
        // at most its immediate neighbours; the 144 pt block holds the whole field. Old
        // output: passes 1 and 3 read the wide list, 5 184 candidates for every shape.
        #expect(near.contains(shapes.firstIndex { $0.id == probe.id }!))
        #expect(near.count <= 4, "\(near.count)")
        #expect(wide.count == shapes.count)
    }

    @Test("R-151: a dense self-compare matches every shape and one moved shape is still found")
    func denseCompareIsCorrectAndFast() async throws {
        let baselineURL = try Self.densePDF(columns: 72, rows: 72)
        let revisedURL = try Self.densePDF(columns: 72, rows: 72, shiftFirst: 0.7)
        defer {
            try? FileManager.default.removeItem(at: baselineURL)
            try? FileManager.default.removeItem(at: revisedURL)
        }
        let baseline = try await VectorExtractor().extract(documentAt: baselineURL, pageIndex: 0)
        let revised = try await VectorExtractor().extract(documentAt: revisedURL, pageIndex: 0)

        let clock = ContinuousClock()
        var outcome: VectorDiffOutcome?
        let elapsed = try clock.measure {
            outcome = try VectorDiffEngine.diff(baseline: baseline, revised: revised, alignment: .identity)
        }
        let result = try #require(outcome)
        print("R-151 dense diff, \(72 * 72) shapes: \(elapsed)")
        // Measured on the reference machine, debug build: 15.34 s before (every shape read the
        // 432 pt block, sorted), 0.03 s after. The bound leaves two orders of magnitude.
        #expect(elapsed < .seconds(3), "\(elapsed)")
        #expect(result.unchangedCount == 72 * 72 - 1)
        #expect(result.differences.count == 1)
        #expect(result.differences.first?.kind == .moved)
        if let translation = result.differences.first?.detail.translation {
            #expect(abs(Double(translation.x) - 0.7) < 1e-3 && abs(Double(translation.y)) < 1e-3)
        }
    }
}

/// R-158: what "reshaped" means, as the engine header now states it — same kind, same vertex
/// centroid within `positionTolerancePoints`. A change that moves the centroid is a removal and
/// an addition.
@Suite("Vector diff: the reshaped rule (R-158)", .serialized)
struct VectorDiffReshapeRuleTests {

    private static func pdf(_ draw: (CGContext) -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zpdf-reshape-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(gray: 0, alpha: 1)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func line(_ context: CGContext, _ from: CGPoint, _ to: CGPoint, width: CGFloat = 1) {
        context.setLineWidth(width)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
    }

    private static func diff(_ baseline: URL, _ revised: URL) async throws -> VectorDiffOutcome {
        try VectorDiffEngine.diff(
            baseline: try await VectorExtractor().extract(documentAt: baseline, pageIndex: 0),
            revised: try await VectorExtractor().extract(documentAt: revised, pageIndex: 0),
            alignment: .identity
        )
    }

    @Test("R-158: a heavier stroke on the same line is one reshape; a lengthened line is a removal and an addition")
    func reshapeMeansSameCentroid() async throws {
        let base = try Self.pdf { Self.line($0, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)) }
        let heavier = try Self.pdf { Self.line($0, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), width: 3) }
        // The far end moves 60 pt: the centroid moves 30 pt, far past 0.1 pt.
        let longer = try Self.pdf { Self.line($0, CGPoint(x: 100, y: 100), CGPoint(x: 360, y: 100)) }
        defer { for url in [base, heavier, longer] { try? FileManager.default.removeItem(at: url) } }

        let reweighted = try await Self.diff(base, heavier)
        #expect(reweighted.differences.map(\.kind) == [.reshaped])

        let lengthened = try await Self.diff(base, longer)
        #expect(lengthened.addedCount == 1)
        #expect(lengthened.removedCount == 1)
        #expect(!lengthened.differences.contains { $0.kind == .reshaped })
    }
}
