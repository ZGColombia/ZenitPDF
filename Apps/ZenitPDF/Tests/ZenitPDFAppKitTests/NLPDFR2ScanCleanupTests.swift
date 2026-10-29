import AppKit
import CoreGraphics
import Foundation
import Testing
import ZPDFAppCore
import ZPDFPDFKitBridge
@testable import ZenitPDFAppKit

/// NL-PDF-12 in the app: Clean Up Scanned Sheets… writes a new, straightened PDF at the same
/// paper size, opens it, leaves the original byte for byte, and says the new file is uncalibrated.
@MainActor
@Suite("Clean Up Scanned Sheets (NL-PDF-12)", .appTierSerialised)
struct NLPDFR2ScanCleanupTests {

    @Test("A 2.3°-skewed scan is written straight to a new file through the injected panel; the original is unchanged")
    func cleansIntoANewFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zpdf-scanapp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("Scanned Plan.pdf")
        // Reuse the bridge test's recipe: ruled lines turned 2.3° on a 612 × 432 pt page.
        let width = 1700, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 850, y: 600); context.rotate(by: 2.3 * .pi / 180)
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        for row in 0..<30 { context.fill(CGRect(x: -700, y: CGFloat(row * 32 - 480), width: 1400, height: 5)) }
        var box = CGRect(x: 0, y: 0, width: 612, height: 432)
        let pdf = try #require(CGContext(input as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil); pdf.draw(try #require(context.makeImage()), in: box); pdf.endPDFPage(); pdf.closePDF()
        let before = try Data(contentsOf: input)

        let document = try AppTestSupport.makeDocument(opening: input)
        defer { Task { await document.drawing?.rasterSource.close(); document.close() } }
        #expect(await AppTestSupport.wait { document.core != nil && document.drawing != nil })
        let output = folder.appendingPathComponent("Scanned Plan — Cleaned.pdf")

        ZenitModalPresenter.reset()
        let previous = ZenitModalPresenter.handler
        defer { ZenitModalPresenter.handler = previous; ScanCleanupCommand.opener = nil }
        ZenitModalPresenter.handler = { $0.identifier == ScanCleanupCommand.panelIdentifier ? .urls([output]) : .dismissed }
        var opened: URL?
        ScanCleanupCommand.opener = { opened = $0 }
        // Old behaviour: no clean-up command existed.
        ScanCleanupCommand.present(document: document, window: nil)
        #expect(await AppTestSupport.wait(upTo: 20) { opened != nil })
        #expect(opened == output)
        #expect(try Data(contentsOf: input) == before, "the drawing itself is never changed")
        let cleaned = try #require(CGPDFDocument(output as CFURL)?.page(at: 1))
        #expect(cleaned.getBoxRect(.mediaBox).size == CGSize(width: 612, height: 432))
        let core = try #require(document.core)
        let note = try #require(core.document.warnings.first { $0.id == ScanCleanupCommand.resultNoteID })
        let straightened = note.message.range(of: #"Straightened: .+ by 2[.,][234]°"#, options: .regularExpression) != nil
        #expect(straightened, Comment(rawValue: note.message))
        #expect(note.message.contains("calibrate the new file"))
    }
}
