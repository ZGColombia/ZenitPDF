import CoreGraphics
import Foundation
import Testing
import ZPDFContracts
@testable import ZPDFExport

/// BH-079, export side: a complete-appearance page source (the bridge's PDFPage drawing) is
/// preferred, with a per-page fallback.
@Suite("Fix2 E2 complete-appearance page source", .sharedHeap)
struct Fix2E2PageContentSourceTests {

    private final class RecordingSource: FlattenPageContentDrawing {
        var drawn: [Int] = []
        func drawPageContent(sourcePageIndex: Int, into context: CGContext, rect: CGRect) -> Bool {
            drawn.append(sourcePageIndex)
            return true
        }
    }

    private static func context() throws -> CGContext {
        try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    @Test("BH-079: the appearance drawer is preferred; a refused page falls back to the content stream")
    func preferredThenFallback() throws {
        let fallback = RecordingSource()
        var preferredCalls: [Int] = []
        let source = PreferredPageContentSource(
            preferred: { index, _, _, _ in preferredCalls.append(index); return index != 2 },
            fallback: fallback
        )
        let context = try Self.context()
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        for index in 0..<3 { #expect(source.drawPageContent(sourcePageIndex: index, into: context, rect: rect)) }
        #expect(preferredCalls == [0, 1, 2])
        // Only the page the drawer refused was replayed from the content stream.
        #expect(fallback.drawn == [2])
        #expect(source.fellBackPages == [2])
    }

    @Test("BH-079: a failing drawer cannot leave graphics state behind")
    func stateIsRestored() throws {
        let context = try Self.context()
        let before = context.ctm
        let source = PreferredPageContentSource(
            preferred: { _, ctx, _, _ in ctx.translateBy(x: 5, y: 5); return false },
            fallback: nil
        )
        #expect(!source.drawPageContent(sourcePageIndex: 0, into: context, rect: .zero))
        #expect(context.ctm == before)
    }
}
