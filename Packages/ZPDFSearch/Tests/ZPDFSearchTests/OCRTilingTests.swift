import CoreGraphics
import CoreText
import Foundation
import GRDB
import Testing
import ZPDFPDFKitBridge
import ZPDFPersistence

@testable import ZPDFSearch

/// NL-PDF-13: a sheet too large for the pixel budget is read in tiles at the full resolution,
/// and a quarter-turned string — a vertical dimension — is read by a rotated pass.
@Suite("OCR v2: tiles and rotated text", .serialized)
struct OCRTilingTests {

    // MARK: - The geometry, without a recogniser

    @Test("Tiles cover the whole box, fit the budget, and overlap")
    func tilesCoverTheBox() {
        let box = CGRect(x: 10, y: 20, width: 1190, height: 842)
        let scale = 300.0 / 72
        let regions = OCRService.tileRegions(box: box, scale: scale, tilePixels: 1400, overlapFraction: 0.1)
        let side = 1400 / scale
        #expect(regions.allSatisfy { $0.width <= side + 0.001 && $0.height <= side + 0.001 })
        let union = regions.reduce(CGRect.null) { $0.union($1) }
        #expect(abs(union.minX - box.minX) < 0.001 && abs(union.minY - box.minY) < 0.001)
        #expect(abs(union.maxX - box.maxX) < 0.001 && abs(union.maxY - box.maxY) < 0.001)
        // 1190 wide in 336 pt tiles stepping 302.4: starts 10, 312.4, 614.8, 917.2 (+ one flush
        // to the far edge at 864) -> 4 columns; 842 tall -> 3 rows.
        #expect(regions.count == 12)
        #expect(OCRService.overlapRatio(regions[0], regions[1]) > 0)
    }

    @Test("A box found in a turned image maps back onto the original image")
    func unrotationInvertsTheTurn() throws {
        // A black block at a known place in a 400 x 300 image.
        let width = 400, height = 300
        let block = CGRect(x: 40, y: 200, width: 120, height: 30)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(block)
        let image = try #require(context.makeImage())
        let expected = CGRect(
            x: block.minX / CGFloat(width), y: block.minY / CGFloat(height),
            width: block.width / CGFloat(width), height: block.height / CGFloat(height)
        )
        for turn in OCRService.QuarterTurn.allCases {
            let turned = try #require(OCRService.rotated(image, turn))
            #expect(turned.width == height && turned.height == width)
            let found = try #require(Self.darkBox(in: turned))
            let back = OCRService.unrotated(found, turn)
            #expect(abs(back.minX - expected.minX) < 0.01, "\(turn): \(back) vs \(expected)")
            #expect(abs(back.minY - expected.minY) < 0.01, "\(turn): \(back) vs \(expected)")
            #expect(abs(back.width - expected.width) < 0.01)
            #expect(abs(back.height - expected.height) < 0.01)
        }
    }

    /// The normalised, bottom-left-origin box of the dark pixels of an image.
    static func darkBox(in image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var minX = width, maxX = -1, minRow = height, maxRow = -1
        for row in 0..<height {
            for column in 0..<width where bytes[(row * width + column) * 4] < 128 {
                minX = min(minX, column); maxX = max(maxX, column)
                minRow = min(minRow, row); maxRow = max(maxRow, row)
            }
        }
        guard maxX >= 0 else { return nil }
        // Memory rows run top to bottom; Vision's normalised space is bottom-up.
        let minY = height - 1 - maxRow
        return CGRect(
            x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width), height: CGFloat(maxRow - minRow + 1) / CGFloat(height)
        )
    }

    // MARK: - Through the service

    /// Small title-block type the downscaled single pass cannot read.
    static let smallWords = ["A-101", "B-202", "C-303", "D-404", "E-505", "F-606", "G-707", "H-808"]
    /// What the index stores of them: `unicode61` splits at the hyphen, and the numbers are the
    /// part a misread changes ("505" read as "50S").
    static let smallNumbers = ["101", "202", "303", "404", "505", "606", "707", "808"]
    /// A vertical dimension string.
    static let verticalWord = "4500"

    /// An A3-landscape sheet: eight 5-point labels scattered in the title block area, and a
    /// 14-point "4500" turned a quarter turn, alone in an empty band.
    static func sheet(into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tiling-sheet-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 1190.55, height: 841.89)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ScannedSheetFixture.FixtureFailure.noBitmapContext }
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(box)
        func draw(_ text: String, size: CGFloat, at point: CGPoint, angle: CGFloat = 0) {
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.saveGState()
            context.translateBy(x: point.x, y: point.y)
            context.rotate(by: angle)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        for (index, word) in smallWords.enumerated() {
            let column = index % 4, row = index / 4
            draw(word, size: 5, at: CGPoint(x: 720 + Double(column) * 110, y: 80 + Double(row) * 40))
        }
        draw(verticalWord, size: 14, at: CGPoint(x: 300, y: 450), angle: .pi / 2)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func settings(tiles: Bool, rotated: Bool) -> OCRSettings {
        OCRSettings(
            recognitionLanguages: ["en-US"],
            usesLanguageCorrection: false,
            usesAccurateRecognition: true,
            renderDPI: 300,
            maximumConcurrentPages: 1,
            maximumRenderPixels: 2_000_000,
            skipsPagesWithTextLayer: false,
            tilesLargePages: tiles,
            recognisesRotatedText: rotated
        )
    }

    static func tokens(_ bed: SearchTestBed, pageId: String) async throws -> [String] {
        try await bed.database.read { db in
            try String.fetchAll(db, sql: "SELECT token FROM ocr_token WHERE page_id = ?", arguments: [pageId])
        }
    }

    @Test("Tiles at 300 dpi read small type the downscaled single pass misses, and the vertical string is stored once")
    func tilesAndRotationFindWhatOnePassMisses() async throws {
        try await withSearchTestBed { bed in
            let url = try Self.sheet(into: SearchTestBed.fixtureDirectory)
            defer { try? FileManager.default.removeItem(at: url) }
            let (documentId, handle) = try await bed.addDocument(at: url)
            let pageId = bed.pageId(documentId: documentId, pageIndex: 0)

            // The old behaviour: one image fitted into 2 megapixels — about 102 dpi — upright only.
            let single = OCRService(database: bed.database, provider: bed.provider, settings: Self.settings(tiles: false, rotated: false))
            let before = try await single.recognize(documentId: documentId, handle: handle)
            let singleTokens = try await Self.tokens(bed, pageId: pageId)
            let singleSmall = Self.smallNumbers.filter { singleTokens.contains($0) }.count
            #expect(before.pages.first.map { $0.effectiveDPI < 110 } == true)

            let tiled = OCRService(database: bed.database, provider: bed.provider, settings: Self.settings(tiles: true, rotated: true))
            let after = try await tiled.recognize(documentId: documentId, handle: handle)
            let tiledTokens = try await Self.tokens(bed, pageId: pageId)
            let tiledSmall = Self.smallNumbers.filter { tiledTokens.contains($0) }.count
            #expect(after.pages.first?.effectiveDPI == 300)

            #expect(tiledSmall >= 6, "tiles read \(tiledSmall) of 8 small labels: \(tiledTokens)")
            #expect(tiledSmall > singleSmall, "one downscaled pass read \(singleSmall), tiles \(tiledSmall)")
            // Measured on macOS 26: Vision's upright pass already reads this quarter-turned string,
            // so the rotated passes are a second reading on sparse tiles, and the merge must keep
            // one token for it, not three.
            #expect(tiledTokens.filter { $0 == Self.verticalWord }.count == 1, "the vertical \(Self.verticalWord) must be read exactly once")
            // No word twice for being in two tiles' overlap.
            for word in Self.smallNumbers where tiledTokens.contains(word) {
                #expect(tiledTokens.filter { $0 == word }.count == 1, "\(word) was stored more than once")
            }
        }
    }
}
